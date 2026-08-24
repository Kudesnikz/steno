import AVFoundation
import Foundation

public struct ImportedRecording: Hashable, Sendable {
    public var baseName: String
    public var displayName: String
    public var videoURL: URL
    public var durationSeconds: Int

    public init(baseName: String, displayName: String, videoURL: URL, durationSeconds: Int) {
        self.baseName = baseName
        self.displayName = displayName
        self.videoURL = videoURL
        self.durationSeconds = durationSeconds
    }
}

public struct RecordingImportService: @unchecked Sendable {
    private let postProcessor: AudioPostProcessor
    private let fileManager: FileManager

    public init(postProcessor: AudioPostProcessor = AudioPostProcessor(), fileManager: FileManager = .default) {
        self.postProcessor = postProcessor
        self.fileManager = fileManager
    }

    public func importVideo(from sourceURL: URL, saveDirectory: URL) async throws -> ImportedRecording {
        let didAccessSecurityScopedResource = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScopedResource {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        let asset = AVURLAsset(url: sourceURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else {
            throw AIClientError.apiError(
                provider: "Import",
                status: 0,
                message: "The selected file does not contain a video track.",
                context: sourceURL.lastPathComponent
            )
        }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite && duration > 0 else {
            throw AIClientError.apiError(
                provider: "Import",
                status: 0,
                message: "The selected video has an invalid duration.",
                context: sourceURL.lastPathComponent
            )
        }

        try fileManager.createDirectory(at: saveDirectory, withIntermediateDirectories: true)
        let baseName = uniqueBaseName(in: saveDirectory)
        let finalURL = saveDirectory.appending(path: "\(baseName).mp4")
        let temporaryURL = saveDirectory.appending(path: ".importing_\(UUID().uuidString).mp4")
        let isCompatible = try await isMP4Compatible(videoTracks: videoTracks, asset: asset)
        do {
            if sourceURL.pathExtension.lowercased() == "mp4", isCompatible {
                try fileManager.copyItem(at: sourceURL, to: temporaryURL)
            } else if isCompatible {
                try await runFFmpeg([
                    "-y", "-i", sourceURL.path,
                    "-map", "0:v:0", "-map", "0:a?",
                    "-c", "copy", "-movflags", "+faststart",
                    temporaryURL.path
                ])
            } else {
                try await runFFmpeg([
                    "-y", "-i", sourceURL.path,
                    "-map", "0:v:0", "-map", "0:a?",
                    "-c:v", "libx264", "-preset", "veryfast", "-crf", "23",
                    "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "160k",
                    "-movflags", "+faststart", temporaryURL.path
                ])
            }
            try fileManager.moveItem(at: temporaryURL, to: finalURL)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
        return ImportedRecording(
            baseName: baseName,
            displayName: sourceURL.deletingPathExtension().lastPathComponent,
            videoURL: finalURL,
            durationSeconds: Int(duration.rounded())
        )
    }

    private func uniqueBaseName(in directory: URL) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy_HH:mm:ss"
        var date = Date()
        var candidate = "Meet_\(formatter.string(from: date))"
        while fileManager.fileExists(atPath: directory.appending(path: "\(candidate).mp4").path) {
            date.addTimeInterval(1)
            candidate = "Meet_\(formatter.string(from: date))"
        }
        return candidate
    }

    private func isMP4Compatible(videoTracks: [AVAssetTrack], asset: AVAsset) async throws -> Bool {
        for track in videoTracks {
            let descriptions = try await track.load(.formatDescriptions)
            guard descriptions.contains(where: { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264 }) else {
                return false
            }
        }
        for track in try await asset.loadTracks(withMediaType: .audio) {
            let descriptions = try await track.load(.formatDescriptions)
            guard descriptions.contains(where: { CMFormatDescriptionGetMediaSubType($0) == kAudioFormatMPEG4AAC }) else {
                return false
            }
        }
        return true
    }

    private func runFFmpeg(_ baseArguments: [String]) async throws {
        let executable = postProcessor.ffmpegURL()
        let arguments = executable.lastPathComponent == "env" ? ["ffmpeg"] + baseArguments : baseArguments
        _ = try await postProcessor.processRunner.runChecked(executableURL: executable, arguments: arguments)
    }
}
