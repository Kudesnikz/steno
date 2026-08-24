import AVFoundation
import Foundation

public struct PreparedAIMedia: Sendable {
    public var videoURL: URL
    public var temporaryURL: URL?

    public init(videoURL: URL, temporaryURL: URL? = nil) {
        self.videoURL = videoURL
        self.temporaryURL = temporaryURL
    }
}

public struct PreparedMediaPart: Sendable {
    public var url: URL
    public var index: Int
    public var startSeconds: Double
    public var durationSeconds: Double

    public init(url: URL, index: Int, startSeconds: Double, durationSeconds: Double) {
        self.url = url
        self.index = index
        self.startSeconds = startSeconds
        self.durationSeconds = durationSeconds
    }
}

public struct PreparedMediaSet: Sendable {
    public var parts: [PreparedMediaPart]
    public var temporaryDirectory: URL?

    public init(parts: [PreparedMediaPart], temporaryDirectory: URL? = nil) {
        self.parts = parts
        self.temporaryDirectory = temporaryDirectory
    }
}

public struct AIMediaPreparationService: Sendable {
    public static let splitTriggerBytes: Int64 = 400 * 1_048_576
    public static let splitTriggerSeconds: Double = 40 * 60
    public static let targetPartBytes: Int64 = 380 * 1_048_576
    public static let targetPartSeconds: Double = 38 * 60

    public static func requiresGeminiSplitting(sizeBytes: Int64, durationSeconds: Double) -> Bool {
        sizeBytes > splitTriggerBytes || durationSeconds > splitTriggerSeconds
    }

    public static func shouldSplitGeminiMedia(
        sizeBytes: Int64,
        durationSeconds: Double,
        isEnabled: Bool
    ) -> Bool {
        isEnabled && requiresGeminiSplitting(sizeBytes: sizeBytes, durationSeconds: durationSeconds)
    }

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

    public func prepareGeminiUploadParts(
        videoURL: URL,
        splitLargeMediaEnabled: Bool = false,
        progress: AIProgressHandler?
    ) async throws -> PreparedMediaSet {
        let size = try videoURL.fileSizeBytes()
        let duration = try await mediaDuration(url: videoURL)
        guard Self.shouldSplitGeminiMedia(
            sizeBytes: size,
            durationSeconds: duration,
            isEnabled: splitLargeMediaEnabled
        ) else {
            return PreparedMediaSet(parts: [
                PreparedMediaPart(url: videoURL, index: 0, startSeconds: 0, durationSeconds: duration)
            ])
        }

        await progress?(.optimizingMedia(provider: AIProviderID.gemini.displayName, fileName: videoURL.lastPathComponent))
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "StenoAI_\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        do {
            let averageBytesPerSecond = duration > 0 ? Double(size) / duration : Double(Self.targetPartBytes)
            let sizeBoundSeconds = floor(Double(Self.targetPartBytes) / max(averageBytesPerSecond, 1))
            let segmentSeconds = max(5, min(Self.targetPartSeconds, sizeBoundSeconds))
            var urls = try await segment(
                inputURL: videoURL,
                directory: directory,
                segmentSeconds: segmentSeconds,
                transcode: false
            )
            if try await partsExceedHardLimits(urls) {
                for url in urls {
                    try? FileManager.default.removeItem(at: url)
                }
                urls = try await segment(
                    inputURL: videoURL,
                    directory: directory,
                    segmentSeconds: Self.targetPartSeconds,
                    transcode: true
                )
            }
            guard !urls.isEmpty, try await !partsExceedHardLimits(urls) else {
                throw AIClientError.apiError(
                    provider: AIProviderID.gemini.displayName,
                    status: 0,
                    message: "Could not split recording below 400 MiB and 40 minutes per part.",
                    context: "local media preparation"
                )
            }

            var offset = 0.0
            var parts: [PreparedMediaPart] = []
            for (index, url) in urls.enumerated() {
                let partDuration = try await mediaDuration(url: url)
                parts.append(PreparedMediaPart(url: url, index: index, startSeconds: offset, durationSeconds: partDuration))
                offset += partDuration
            }
            return PreparedMediaSet(parts: parts, temporaryDirectory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    public func cleanup(_ mediaSet: PreparedMediaSet) {
        guard let directory = mediaSet.temporaryDirectory else {
            return
        }
        try? FileManager.default.removeItem(at: directory)
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

    private func segment(
        inputURL: URL,
        directory: URL,
        segmentSeconds: Double,
        transcode: Bool
    ) async throws -> [URL] {
        let outputPattern = directory.appending(path: transcode ? "part_transcoded_%03d.mp4" : "part_%03d.mp4")
        let ffmpeg = postProcessor.ffmpegURL()
        var baseArgs = ["-y", "-i", inputURL.path, "-map", "0:v:0", "-map", "0:a?"]
        if transcode {
            baseArgs += [
                "-vf", "scale=1280:-2:force_original_aspect_ratio=decrease,fps=5",
                "-c:v", "libx264",
                "-preset", "veryfast",
                "-crf", "30",
                "-pix_fmt", "yuv420p",
                "-force_key_frames", "expr:gte(t,n_forced*\(Int(segmentSeconds)))",
                "-c:a", "aac",
                "-ac", "1",
                "-b:a", "96k"
            ]
        } else {
            baseArgs += ["-c", "copy"]
        }
        baseArgs += [
            "-f", "segment",
            "-segment_time", String(format: "%.3f", segmentSeconds),
            "-reset_timestamps", "1",
            "-segment_format", "mp4",
            outputPattern.path
        ]
        let args = ffmpeg.lastPathComponent == "env" ? ["ffmpeg"] + baseArgs : baseArgs
        _ = try await postProcessor.processRunner.runChecked(executableURL: ffmpeg, arguments: args)
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(transcode ? "part_transcoded_" : "part_") && $0.pathExtension == "mp4" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func partsExceedHardLimits(_ urls: [URL]) async throws -> Bool {
        for url in urls {
            let size = try url.fileSizeBytes()
            let duration = try await mediaDuration(url: url)
            if size > Self.splitTriggerBytes || duration > Self.splitTriggerSeconds {
                return true
            }
        }
        return false
    }

    private func mediaDuration(url: URL) async throws -> Double {
        let duration = try await AVURLAsset(url: url).load(.duration)
        let seconds = duration.seconds
        guard seconds.isFinite && seconds >= 0 else {
            throw AIClientError.apiError(
                provider: AIProviderID.gemini.displayName,
                status: 0,
                message: "Could not determine media duration.",
                context: url.lastPathComponent
            )
        }
        return seconds
    }
}
