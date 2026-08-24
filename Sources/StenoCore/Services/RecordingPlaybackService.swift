import AVFoundation
import Foundation

public enum RecordingPlaybackError: LocalizedError {
    case missingVideo(String)
    case invalidVideo(String)

    public var errorDescription: String? {
        switch self {
        case let .missingVideo(name): "Video part is missing: \(name)"
        case let .invalidVideo(name): "Video part has no playable video track: \(name)"
        }
    }
}

@MainActor
public enum RecordingPlaybackService {
    public static func makePlayerItem(for session: MeetingSession) async throws -> AVPlayerItem {
        guard session.isSegmentedRecording else {
            return AVPlayerItem(url: session.videoURL)
        }

        let composition = AVMutableComposition()
        guard let compositionVideo = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ), let compositionSystemAudio = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ), let compositionMicrophone = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw RecordingPlaybackError.invalidVideo(session.baseName)
        }

        let directory = session.baseURL.deletingLastPathComponent()
        var cursor = CMTime.zero
        var didSetTransform = false
        for segment in session.recordingSegments.sorted(by: { $0.index < $1.index }) {
            let videoURL = directory.appending(path: segment.videoPath)
            guard FileManager.default.fileExists(atPath: videoURL.path) else {
                throw RecordingPlaybackError.missingVideo(videoURL.lastPathComponent)
            }
            let videoAsset = AVURLAsset(url: videoURL)
            guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first else {
                throw RecordingPlaybackError.invalidVideo(videoURL.lastPathComponent)
            }
            let videoRange = try await videoTrack.load(.timeRange)
            let duration = videoRange.duration
            guard duration.isValid, duration.seconds > 0 else {
                throw RecordingPlaybackError.invalidVideo(videoURL.lastPathComponent)
            }
            try compositionVideo.insertTimeRange(videoRange, of: videoTrack, at: cursor)
            if !didSetTransform {
                compositionVideo.preferredTransform = try await videoTrack.load(.preferredTransform)
                didSetTransform = true
            }
            if let systemAudio = try await videoAsset.loadTracks(withMediaType: .audio).first {
                let systemRange = try await systemAudio.load(.timeRange)
                let safeDuration = CMTimeMinimum(duration, systemRange.duration)
                if safeDuration.isValid, safeDuration.seconds > 0 {
                    try compositionSystemAudio.insertTimeRange(
                        CMTimeRange(start: systemRange.start, duration: safeDuration),
                        of: systemAudio,
                        at: cursor
                    )
                }
            }

            if let microphonePath = segment.microphoneAudioPath {
                let microphoneURL = directory.appending(path: microphonePath)
                if FileManager.default.fileExists(atPath: microphoneURL.path) {
                    let microphoneAsset = AVURLAsset(url: microphoneURL)
                    if let microphoneTrack = try await microphoneAsset.loadTracks(withMediaType: .audio).first {
                        let microphoneRange = try await microphoneTrack.load(.timeRange)
                        let safeDuration = CMTimeMinimum(duration, microphoneRange.duration)
                        if safeDuration.isValid, safeDuration.seconds > 0 {
                            try compositionMicrophone.insertTimeRange(
                                CMTimeRange(start: microphoneRange.start, duration: safeDuration),
                                of: microphoneTrack,
                                at: cursor
                            )
                        }
                    }
                }
            }
            cursor = CMTimeAdd(cursor, duration)
        }
        return AVPlayerItem(asset: composition)
    }
}
