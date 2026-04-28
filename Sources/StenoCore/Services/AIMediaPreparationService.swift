import Foundation

public struct PreparedAIMedia: Sendable {
    public var videoURL: URL
    public var temporaryURL: URL?

    public init(videoURL: URL, temporaryURL: URL? = nil) {
        self.videoURL = videoURL
        self.temporaryURL = temporaryURL
    }
}

public struct AIMediaPreparationService: Sendable {
    public let postProcessor: AudioPostProcessor

    public init(postProcessor: AudioPostProcessor = AudioPostProcessor()) {
        self.postProcessor = postProcessor
    }

    public func prepareVideoIfNeeded(
        videoURL: URL,
        providerID: AIProviderID,
        progress: AIProgressHandler?
    ) async throws -> PreparedAIMedia {
        guard let limit = singleRequestLimit(for: providerID) else {
            return PreparedAIMedia(videoURL: videoURL)
        }

        let originalSize = try videoURL.fileSizeBytes()
        guard originalSize > limit else {
            return PreparedAIMedia(videoURL: videoURL)
        }

        await progress?(.optimizingMedia(provider: providerID.displayName, fileName: videoURL.lastPathComponent))
        let outputURL = FileManager.default.temporaryDirectory.appending(
            path: "\(videoURL.deletingPathExtension().lastPathComponent)_ai_\(UUID().uuidString).mp4"
        )

        do {
            try await transcodeForAI(inputURL: videoURL, outputURL: outputURL)
            let optimizedSize = try outputURL.fileSizeBytes()
            guard optimizedSize < originalSize else {
                try? FileManager.default.removeItem(at: outputURL)
                return PreparedAIMedia(videoURL: videoURL)
            }
            AppLog.info(
                "Prepared AI media \(videoURL.lastPathComponent): \(originalSize) -> \(optimizedSize) bytes",
                category: .ai
            )
            return PreparedAIMedia(videoURL: outputURL, temporaryURL: outputURL)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            AppLog.warning("AI media optimization failed: \(error.localizedDescription)", category: .ai)
            return PreparedAIMedia(videoURL: videoURL)
        }
    }

    public func cleanup(_ preparedMedia: PreparedAIMedia) {
        guard let temporaryURL = preparedMedia.temporaryURL else {
            return
        }
        try? FileManager.default.removeItem(at: temporaryURL)
    }

    private func singleRequestLimit(for providerID: AIProviderID) -> Int64? {
        switch providerID {
        case .gemini:
            nil
        case .kimi, .qwen, .openRouter:
            AIMediaLimits.openAICompatibleSingleRequestVideoBytes
        case .amazonBedrock:
            AIMediaLimits.bedrockSingleRequestVideoBytes
        }
    }

    private func transcodeForAI(inputURL: URL, outputURL: URL) async throws {
        let ffmpeg = postProcessor.ffmpegURL()
        let baseArgs = [
            "-y",
            "-i", inputURL.path,
            "-vf", "scale=1280:-2:force_original_aspect_ratio=decrease,fps=5",
            "-c:v", "libx264",
            "-preset", "veryfast",
            "-crf", "30",
            "-pix_fmt", "yuv420p",
            "-c:a", "aac",
            "-ac", "1",
            "-b:a", "96k",
            "-movflags", "+faststart",
            outputURL.path
        ]
        let args = ffmpeg.lastPathComponent == "env" ? ["ffmpeg"] + baseArgs : baseArgs
        _ = try await postProcessor.processRunner.runChecked(executableURL: ffmpeg, arguments: args)
    }
}
