import Foundation
@testable import StenoCore
import XCTest

final class SessionStoreTests: XCTestCase {
    func testScansVideoMetadataProtocolAndAudioFiles() throws {
        let directory = try temporaryDirectory()
        let baseName = "Meet_24.06.2024_15:30:00"
        try Data("video".utf8).write(to: directory.appending(path: "\(baseName).mp4"))
        try Data("audio".utf8).write(to: directory.appending(path: "\(baseName)_tmp_mic.m4a"))
        try Data(#"{"segments":[]}"#.utf8).write(to: directory.appending(path: "\(baseName)_transcript.json"))
        try Data("# Transcript".utf8).write(to: directory.appending(path: "\(baseName)_transcript.md"))
        try Data("# Report".utf8).write(to: directory.appending(path: "\(baseName)_protocol_default.txt"))
        try Data(#"{"name":"Custom name"}"#.utf8).write(to: directory.appending(path: "\(baseName).json"))

        let store = SessionStore(saveDirectory: directory)
        let sessions = store.scanSessions()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].baseName, baseName)
        XCTAssertEqual(sessions[0].displayName, "Custom name")
        XCTAssertEqual(sessions[0].audioURLs.count, 1)
        XCTAssertEqual(sessions[0].transcriptURL?.lastPathComponent, "\(baseName)_transcript.json")
        XCTAssertEqual(sessions[0].transcriptMarkdownURL?.lastPathComponent, "\(baseName)_transcript.md")
        XCTAssertEqual(sessions[0].reportURLsByAgentID["default"]?.lastPathComponent, "\(baseName)_protocol_default.txt")
    }

    func testSavesTranscriptAndUpdatesMetadata() throws {
        let directory = try temporaryDirectory()
        let baseName = "Meet_24.06.2024_15:30:00"
        try Data("video".utf8).write(to: directory.appending(path: "\(baseName).mp4"))

        let store = SessionStore(saveDirectory: directory)
        let document = TranscriptDocument(
            baseName: baseName,
            modelName: NativeSpeechDefaults.engineDisplayName,
            language: "ru",
            segments: [TranscriptSegment(source: .system, startTimeSeconds: 0, endTimeSeconds: 2, text: "Текст")]
        )

        let urls = try store.saveTranscript(document, baseName: baseName)
        try store.updateTranscriptionMetadata(
            baseName: baseName,
            status: .completed,
            modelName: document.modelName,
            language: document.language,
            segmentCount: document.segments.count
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: urls.jsonURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: urls.markdownURL.path))
        let session = try XCTUnwrap(store.scanSessions().first)
        XCTAssertEqual(session.metadata.transcription?.status, .completed)
        XCTAssertEqual(session.metadata.transcription?.segmentCount, 1)
    }

    func testRenamesByUpdatingMetadataJSON() throws {
        let directory = try temporaryDirectory()
        let baseName = "Meet_24.06.2024_15:30:00"
        try Data("video".utf8).write(to: directory.appending(path: "\(baseName).mp4"))

        let store = SessionStore(saveDirectory: directory)
        let session = try XCTUnwrap(store.scanSessions().first)

        try store.rename(session: session, to: "Renamed")
        let rescanned = store.scanSessions()
        XCTAssertEqual(rescanned.first?.displayName, "Renamed")
    }

    func testUpsertReportMetadataReplacesMatchingAgentAndCreatedAt() throws {
        let directory = try temporaryDirectory()
        let baseName = "Meet_24.06.2024_15:30:00"
        try Data("video".utf8).write(to: directory.appending(path: "\(baseName).mp4"))

        let store = SessionStore(saveDirectory: directory)
        let started = "2026-04-28T13:00:00Z"
        let inProgress = ReportInfo(
            agentID: "default",
            agentName: "Стандартный протокол",
            model: "gemini-3-flash-preview",
            createdAt: started,
            processingDurationSeconds: 10,
            tokens: ReportTokens(input: 0, output: 0, total: 0),
            outputPath: "",
            status: "uploading_media"
        )
        let success = ReportInfo(
            agentID: "default",
            agentName: "Стандартный протокол",
            model: "gemini-3-flash-preview",
            createdAt: started,
            processingDurationSeconds: 120,
            tokens: ReportTokens(input: 10, output: 20, total: 30),
            outputPath: "\(baseName)_protocol_default.txt",
            status: "success"
        )

        try store.upsertReportMetadata(baseName: baseName, report: inProgress)
        try store.upsertReportMetadata(baseName: baseName, report: success)

        let session = try XCTUnwrap(store.scanSessions().first)
        let reports = try XCTUnwrap(session.metadata.reports)
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0].status, "success")
        XCTAssertEqual(reports[0].tokens.total, 30)
        XCTAssertEqual(reports[0].outputPath, "\(baseName)_protocol_default.txt")
    }

    func testDeleteArtifactsRemovesOnlyMatchingBaseName() throws {
        let directory = try temporaryDirectory()
        let baseName = "Meet_24.06.2024_15:30:00"
        let otherBaseName = "Meet_24.06.2024_16:00:00"
        try Data("video".utf8).write(to: directory.appending(path: "\(baseName).mp4"))
        try Data("metadata".utf8).write(to: directory.appending(path: "\(baseName).json"))
        try Data("transcript".utf8).write(to: directory.appending(path: "\(baseName)_transcript.md"))
        try Data("report".utf8).write(to: directory.appending(path: "\(baseName)_protocol_default.txt"))
        try Data("other".utf8).write(to: directory.appending(path: "\(otherBaseName).mp4"))

        let store = SessionStore(saveDirectory: directory)
        try store.deleteArtifacts(baseName: baseName)

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "\(baseName).mp4").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "\(baseName).json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "\(baseName)_transcript.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "\(baseName)_protocol_default.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appending(path: "\(otherBaseName).mp4").path))
    }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
