import Foundation

public enum AudioPostProcessorError: LocalizedError, Sendable {
    case missingSidecarAudio

    public var errorDescription: String? {
        switch self {
        case .missingSidecarAudio:
            "No normalized audio sidecars are available."
        }
    }
}

public struct AudioPostProcessor: Sendable {
    public let processRunner: ProcessRunner

    public init(processRunner: ProcessRunner = ProcessRunner()) {
        self.processRunner = processRunner
    }

    public func ffmpegURL() -> URL {
        let resourceURL = Bundle.main.resourceURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let archSpecificName = nativeArchitectureName == "arm64" ? "ffmpeg_arm64" : "ffmpeg_x86_64"
        let bundled = resourceURL.appending(path: "bin/\(archSpecificName)")
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        return URL(fileURLWithPath: "/usr/bin/env")
    }

    public func muxVideoCopy(videoURL: URL, audioURL: URL, outputURL: URL, systemVolume: Double, microphoneVolume: Double) async throws {
        let ffmpeg = ffmpegURL()
        AppLog.info("Starting ffmpeg audio mux", category: .recording)
        let args: [String]
        if ffmpeg.lastPathComponent == "env" {
            args = [
                "ffmpeg", "-y",
                "-i", videoURL.path,
                "-i", audioURL.path,
                "-filter_complex", "[0:a]volume=\(systemVolume)[sys];[1:a]volume=\(microphoneVolume)[mic];[sys][mic]amix=inputs=2:duration=first[a]",
                "-map", "0:v",
                "-map", "[a]",
                "-c:v", "copy",
                "-c:a", "aac",
                "-b:a", "192k",
                outputURL.path
            ]
        } else {
            args = [
                "-y",
                "-i", videoURL.path,
                "-i", audioURL.path,
                "-filter_complex", "[0:a]volume=\(systemVolume)[sys];[1:a]volume=\(microphoneVolume)[mic];[sys][mic]amix=inputs=2:duration=first[a]",
                "-map", "0:v",
                "-map", "[a]",
                "-c:v", "copy",
                "-c:a", "aac",
                "-b:a", "192k",
                outputURL.path
            ]
        }
        do {
            _ = try await processRunner.runChecked(executableURL: ffmpeg, arguments: args)
            AppLog.info("Finished ffmpeg audio mux", category: .recording)
        } catch {
            AppLog.error("ffmpeg audio mux failed: \(error.localizedDescription)", category: .recording)
            throw error
        }
    }

    public func replaceAudioWithSidecars(
        videoURL: URL,
        sidecars: RecordingAudioSidecars,
        outputURL: URL
    ) async throws {
        guard sidecars.hasAudio else {
            throw AudioPostProcessorError.missingSidecarAudio
        }

        let ffmpeg = ffmpegURL()
        let baseArgs = replaceAudioArguments(videoURL: videoURL, sidecars: sidecars, outputURL: outputURL)
        let args = ffmpeg.lastPathComponent == "env" ? ["ffmpeg"] + baseArgs : baseArgs
        AppLog.info(
            "Starting ffmpeg audio replacement system=\(sidecars.system != nil) microphone=\(sidecars.microphone != nil)",
            category: .recording
        )
        do {
            _ = try await processRunner.runChecked(executableURL: ffmpeg, arguments: args)
            AppLog.info("Finished ffmpeg audio replacement", category: .recording)
        } catch {
            AppLog.error("ffmpeg audio replacement failed: \(error.localizedDescription)", category: .recording)
            throw error
        }
    }

    public func replaceAudioArguments(videoURL: URL, sidecars: RecordingAudioSidecars, outputURL: URL) -> [String] {
        var args = [
            "-y",
            "-i", videoURL.path
        ]
        var inputIndex = 1
        var filterParts: [String] = []
        var labels: [String] = []

        if let system = sidecars.system {
            args += ["-i", system.url.path]
            let label = "sys"
            filterParts.append("[\(inputIndex):a]\(delayFilter(for: system.startOffsetSeconds))[\(label)]")
            labels.append("[\(label)]")
            inputIndex += 1
        }

        if let microphone = sidecars.microphone {
            args += ["-i", microphone.url.path]
            let label = "mic"
            filterParts.append("[\(inputIndex):a]\(delayFilter(for: microphone.startOffsetSeconds))[\(label)]")
            labels.append("[\(label)]")
            inputIndex += 1
        }

        if labels.count == 1 {
            filterParts.insert("[0:a]anull[orig]", at: 0)
            filterParts.append("[orig]\(labels[0])amix=inputs=2:duration=longest:dropout_transition=0,alimiter=limit=0.95[a]")
        } else {
            filterParts.append("\(labels.joined())amix=inputs=\(labels.count):duration=longest:dropout_transition=0,alimiter=limit=0.95[a]")
        }

        args += [
            "-filter_complex", filterParts.joined(separator: ";"),
            "-map", "0:v:0",
            "-map", "[a]",
            "-c:v", "copy",
            "-c:a", "aac",
            "-b:a", "192k",
            "-movflags", "+faststart",
            outputURL.path
        ]
        return args
    }

    private var nativeArchitectureName: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    private func delayFilter(for offsetSeconds: Double) -> String {
        let milliseconds = max(0, Int((offsetSeconds * 1_000).rounded()))
        guard milliseconds > 0 else {
            return "anull"
        }
        return "adelay=\(milliseconds):all=1"
    }
}
