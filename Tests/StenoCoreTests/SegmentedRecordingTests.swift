import AVFoundation
import Foundation
@testable import StenoCore
import XCTest

final class SegmentedRecordingTests: XCTestCase {
    func testExperimentalRecordingDefaultsToStandardProfile() throws {
        XCTAssertTrue(AppConfig.default.experimentalSegmentedRecordingEnabled)
        XCTAssertEqual(AppConfig.default.segmentedRecordingLimitProfile, .standard)
        XCTAssertEqual(SegmentedRecordingLimitProfile.standard.maximumDurationSeconds, 140 * 60)
        XCTAssertEqual(SegmentedRecordingLimitProfile.standard.maximumPayloadBytes, 3_600_000_000)
        XCTAssertEqual(SegmentedRecordingLimitProfile.standard.maximumVideoParts, 3)

        let legacyPayload = #"{"used_tokens":0,"last_request_tokens":0}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppConfig.self, from: legacyPayload)
        XCTAssertTrue(decoded.experimentalSegmentedRecordingEnabled)
        XCTAssertEqual(decoded.segmentedRecordingLimitProfile, .standard)
    }

    func testLimitProfilesExposeRequestedLongOptions() {
        XCTAssertEqual(SegmentedRecordingLimitProfile.allCases.map(\.maximumDurationSeconds), [
            50 * 60, 140 * 60, 280 * 60, 500 * 60
        ])
        XCTAssertEqual(SegmentedRecordingLimitProfile.allCases.map(\.maximumPayloadBytes), [
            1_800_000_000, 3_600_000_000, 7_200_000_000, 18_000_000_000
        ])
        XCTAssertFalse(SegmentedRecordingLimitProfile.short.usesLowAIMediaResolution)
        XCTAssertTrue(SegmentedRecordingLimitProfile.standard.usesLowAIMediaResolution)
    }

    func testRecordingPolicyRotatesAndStopsAtFirstReachedLimit() {
        let policy = SegmentedRecordingPolicy(profile: .standard)
        XCTAssertFalse(policy.shouldRotateSegment(durationSeconds: 3_299, bytes: 100))
        XCTAssertTrue(policy.shouldRotateSegment(durationSeconds: 3_300, bytes: 100))
        XCTAssertTrue(policy.shouldRotateSegment(
            durationSeconds: 1,
            bytes: SegmentedRecordingPolicy.maximumSegmentBytes - SegmentedRecordingPolicy.sizeSafetyMarginBytes
        ))
        XCTAssertNil(policy.stopReason(elapsedSeconds: 8_399, payloadBytes: 100, partCount: 3))
        XCTAssertEqual(policy.stopReason(elapsedSeconds: 8_400, payloadBytes: 100, partCount: 3), .durationLimit)
        XCTAssertEqual(
            policy.stopReason(
                elapsedSeconds: 1,
                payloadBytes: SegmentedRecordingLimitProfile.standard.maximumPayloadBytes -
                    SegmentedRecordingPolicy.sizeSafetyMarginBytes,
                partCount: 1
            ),
            .sizeLimit
        )
    }

    func testSegmentVideoWriterDisablesInternalMP4Fragmentation() throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
            .appendingPathExtension("mp4")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        SegmentedScreenRecordingService.configureVideoWriter(writer)

        XCTAssertTrue(writer.shouldOptimizeForNetworkUse)
        XCTAssertFalse(writer.movieFragmentInterval.isValid)
    }

    func testWriterDiagnosticIncludesUnderlyingNSErrorChain() {
        let underlying = NSError(
            domain: NSOSStatusErrorDomain,
            code: -16_341,
            userInfo: [NSLocalizedDescriptionKey: "Movie header failed"]
        )
        let outer = NSError(
            domain: AVFoundationErrorDomain,
            code: -11_800,
            userInfo: [NSUnderlyingErrorKey: underlying]
        )

        let diagnostic = SegmentedScreenRecordingService.diagnosticDescription(for: outer)

        XCTAssertTrue(diagnostic.contains("domain=AVFoundationErrorDomain"))
        XCTAssertTrue(diagnostic.contains("code=-11800"))
        XCTAssertTrue(diagnostic.contains("domain=NSOSStatusErrorDomain"))
        XCTAssertTrue(diagnostic.contains("code=-16341"))
    }

    func testLegacyRecordingMetadataDecodesWithoutSegments() throws {
        let payload = #"{"duration_seconds":60,"video_quality":"Medium","video_path":"old.mp4","mic_audio_path":"","video_size_mb":12,"mic_size_mb":0}"#.data(using: .utf8)!
        let recording = try JSONDecoder().decode(RecordingInfo.self, from: payload)
        XCTAssertFalse(recording.segmented)
        XCTAssertTrue(recording.segments.isEmpty)
        XCTAssertNil(recording.limitProfileID)
    }

    func testSessionStoreScansSegmentedSessionWithoutLegacyMP4() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let baseName = "Meet_24.08.2026_12:00:00"
        let firstVideo = directory.appending(path: "\(baseName)_part_000.mp4")
        let firstMic = directory.appending(path: "\(baseName)_part_000_mic.m4a")
        let secondVideo = directory.appending(path: "\(baseName)_part_001.mp4")
        let secondMic = directory.appending(path: "\(baseName)_part_001_mic.m4a")
        try Data(repeating: 1, count: 10).write(to: firstVideo)
        try Data(repeating: 2, count: 3).write(to: firstMic)
        try Data(repeating: 3, count: 20).write(to: secondVideo)
        try Data(repeating: 4, count: 4).write(to: secondMic)

        let segments = [
            RecordingSegment(
                index: 0, startSeconds: 0, durationSeconds: 3_300,
                videoPath: firstVideo.lastPathComponent, microphoneAudioPath: firstMic.lastPathComponent,
                videoSizeBytes: 10, microphoneSizeBytes: 3
            ),
            RecordingSegment(
                index: 1, startSeconds: 3_300, durationSeconds: 60,
                videoPath: secondVideo.lastPathComponent, microphoneAudioPath: secondMic.lastPathComponent,
                videoSizeBytes: 20, microphoneSizeBytes: 4
            )
        ]
        let store = SessionStore(saveDirectory: directory)
        try store.createInitialMetadata(baseName: baseName, displayName: "Segmented", createdAt: "2026-08-24T12:00:00Z")
        try store.updateSegmentedRecordingMetadata(
            baseName: baseName,
            update: SegmentedRecordingMetadataUpdate(
                duration: 3_360,
                quality: "Medium",
                profile: .standard,
                stopReason: .user,
                segments: segments
            )
        )

        let session = try XCTUnwrap(store.scanSessions().first)
        XCTAssertEqual(session.videoURL, firstVideo)
        XCTAssertTrue(session.isSegmentedRecording)
        XCTAssertEqual(session.recordingSegments.map(\.index), [0, 1])
        XCTAssertEqual(session.segmentVideoURLs, [firstVideo, secondVideo])
        XCTAssertEqual(session.segmentMicrophoneURLs, [firstMic, secondMic])
        XCTAssertEqual(session.metadata.schemaVersion, 3)
        XCTAssertEqual(session.metadata.recording?.stopReason, .user)
    }
}
