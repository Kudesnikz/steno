import Foundation
import OSLog

public enum AppLogCategory: String, Sendable {
    case app = "App"
    case ai = "AI"
    case config = "Config"
    case permissions = "Permissions"
    case recording = "Recording"
    case sessions = "Sessions"
    case ui = "UI"
}

public enum AppLog {
    public static let subsystem = Bundle.main.bundleIdentifier ?? "com.sergeygalay.steno"
    public static let logFileURL = UserPaths.stenoDirectory.appending(path: "steno.log")

    private static let fileWriter = FileLogWriter(logURL: logFileURL)

    public static func debug(
        _ message: @autoclosure () -> String,
        category: AppLogCategory = .app,
        fileID: StaticString = #fileID,
        line: UInt = #line
    ) {
        let text = message()
        logger(category).debug("\(text, privacy: .public)")
        fileWriter.append(level: "DEBUG", category: category, message: text, fileID: fileID, line: line)
    }

    public static func info(
        _ message: @autoclosure () -> String,
        category: AppLogCategory = .app,
        fileID: StaticString = #fileID,
        line: UInt = #line
    ) {
        let text = message()
        logger(category).info("\(text, privacy: .public)")
        fileWriter.append(level: "INFO", category: category, message: text, fileID: fileID, line: line)
    }

    public static func warning(
        _ message: @autoclosure () -> String,
        category: AppLogCategory = .app,
        fileID: StaticString = #fileID,
        line: UInt = #line
    ) {
        let text = message()
        logger(category).warning("\(text, privacy: .public)")
        fileWriter.append(level: "WARN", category: category, message: text, fileID: fileID, line: line)
    }

    public static func error(
        _ message: @autoclosure () -> String,
        category: AppLogCategory = .app,
        fileID: StaticString = #fileID,
        line: UInt = #line
    ) {
        let text = message()
        logger(category).error("\(text, privacy: .public)")
        fileWriter.append(level: "ERROR", category: category, message: text, fileID: fileID, line: line)
    }

    private static func logger(_ category: AppLogCategory) -> Logger {
        Logger(subsystem: subsystem, category: category.rawValue)
    }
}

private final class FileLogWriter: @unchecked Sendable {
    private let logURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private let maxBytes = 5 * 1024 * 1024

    init(logURL: URL, fileManager: FileManager = .default) {
        self.logURL = logURL
        self.fileManager = fileManager
    }

    func append(level: String, category: AppLogCategory, message: String, fileID: StaticString, line: UInt) {
        lock.lock()
        defer { lock.unlock() }

        do {
            try fileManager.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try rotateIfNeeded()

            if !fileManager.fileExists(atPath: logURL.path) {
                fileManager.createFile(atPath: logURL.path, contents: nil)
            }

            let fileHandle = try FileHandle(forWritingTo: logURL)
            defer { try? fileHandle.close() }

            try fileHandle.seekToEnd()
            let line = format(level: level, category: category, message: message, fileID: fileID, line: line)
            if let data = line.data(using: .utf8) {
                try fileHandle.write(contentsOf: data)
            }
        } catch {
            let fallback = Logger(subsystem: AppLog.subsystem, category: AppLogCategory.app.rawValue)
            fallback.error("Failed to write file log: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func rotateIfNeeded() throws {
        guard let size = try? logURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size >= maxBytes else {
            return
        }

        let backupURL = logURL.deletingLastPathComponent().appending(path: "steno.log.1")
        try? fileManager.removeItem(at: backupURL)
        try fileManager.moveItem(at: logURL, to: backupURL)
    }

    private func format(level: String, category: AppLogCategory, message: String, fileID: StaticString, line: UInt) -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let compactMessage = message
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return "\(timestamp) [\(level)] [\(category.rawValue)] \(compactMessage) (\(fileID):\(line))\n"
    }
}
