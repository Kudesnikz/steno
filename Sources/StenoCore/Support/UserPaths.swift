import Foundation
import Darwin

public enum UserPaths {
    public static var homeDirectory: URL {
        let userName = NSUserName()
        if let passwd = getpwnam(userName),
           let rawHome = passwd.pointee.pw_dir {
            let path = String(cString: rawHome)
            if !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }

        // Fallback for sandboxed app paths
        let sandboxHome = FileManager.default.homeDirectoryForCurrentUser
        if sandboxHome.path.contains("/Library/Containers/") {
            let components = sandboxHome.pathComponents
            if let usersIndex = components.firstIndex(of: "Users"), usersIndex + 1 < components.count {
                let realUserHome = "/" + components[1...usersIndex+1].joined(separator: "/")
                return URL(fileURLWithPath: realUserHome, isDirectory: true)
            }
        }

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
