import Foundation

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

    private var nativeArchitectureName: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
}
