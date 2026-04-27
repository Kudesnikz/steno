import Foundation

public enum StenoFormatters {
    public static func duration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }

    public static func shortDuration(_ seconds: Int) -> String {
        if seconds <= 0 {
            return "—"
        }
        return "\(seconds / 60)м \(seconds % 60)с"
    }

    public static func megabytes(_ value: Double) -> String {
        String(format: "%.1f MB", value)
    }

    public static func approximateFileSize(megabytes: Double) -> String {
        if megabytes >= 1_000 {
            return String(format: "%.1f GB", megabytes / 1_000)
        }
        if megabytes >= 10 {
            return String(format: "%.0f MB", megabytes)
        }
        return String(format: "%.1f MB", megabytes)
    }

    public static func tokens(_ value: Int) -> String {
        value.formatted(.number)
    }
}

public extension URL {
    var deletingPathExtensionIfPresent: URL {
        deletingPathExtension()
    }
}
