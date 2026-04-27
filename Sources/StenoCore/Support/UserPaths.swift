import Foundation
import Darwin

public enum UserPaths {
    public static var homeDirectory: URL {
        if let passwd = getpwuid(getuid()),
           let rawHome = passwd.pointee.pw_dir {
            let path = String(cString: rawHome)
            if !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }

        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
        }

        return FileManager.default.homeDirectoryForCurrentUser
    }

    public static var stenoDirectory: URL {
        homeDirectory.appending(path: ".steno", directoryHint: .isDirectory)
    }

    public static var defaultSaveDirectory: URL {
        homeDirectory
            .appending(path: "Movies", directoryHint: .isDirectory)
            .appending(path: "ScreenRecordings", directoryHint: .isDirectory)
    }
}
