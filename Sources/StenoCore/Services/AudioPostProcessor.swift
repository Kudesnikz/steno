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

    private var nativeArchitectureName: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
}
