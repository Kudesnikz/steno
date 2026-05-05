import Foundation

/// Configuration constants for Apple's on-device Speech framework integration.
public enum NativeSpeechDefaults {
    public static let engineID = "apple-speech-on-device"
    public static let engineDisplayName = "Apple Speech On-Device"
    public static let systemLanguageCode = "system"
    public static let defaultLanguageCode = systemLanguageCode
    public static let currentDefaultsRevision = 4

    public static func normalizedLanguageCode(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return systemLanguageCode
        }

        switch trimmed.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "auto", "system":
            return systemLanguageCode
        case "ru":
            return "ru-RU"
        case "en":
            return "en-US"
        default:
            return trimmed.replacingOccurrences(of: "_", with: "-")
        }
    }
}

public struct NativeSpeechLanguageOption: Identifiable, Hashable, Sendable {
    public var id: String
    public var localeIdentifier: String
    public var resolvedLocaleIdentifier: String
    public var displayName: String
    public var isSystemSelection: Bool
    public var isSupported: Bool
    public var isRecognizerAvailable: Bool
    public var isOfflineAvailable: Bool

    public init(
        id: String,
        localeIdentifier: String,
        resolvedLocaleIdentifier: String,
        displayName: String,
        isSystemSelection: Bool,
        isSupported: Bool,
        isRecognizerAvailable: Bool,
        isOfflineAvailable: Bool
    ) {
        self.id = id
        self.localeIdentifier = localeIdentifier
        self.resolvedLocaleIdentifier = resolvedLocaleIdentifier
        self.displayName = displayName
        self.isSystemSelection = isSystemSelection
        self.isSupported = isSupported
        self.isRecognizerAvailable = isRecognizerAvailable
        self.isOfflineAvailable = isOfflineAvailable
    }

    public var statusText: String {
        if !isSupported {
            return "Unsupported"
        }
        if isOfflineAvailable {
            return "Offline ready"
        }
        if isRecognizerAvailable {
            return "Requires dictation download"
        }
        return "Unavailable"
    }
}

public struct NativeSpeechRecognizerInfo: Hashable, Sendable {
    public var localeIdentifier: String
    public var isAvailable: Bool
    public var supportsOnDeviceRecognition: Bool

    public init(localeIdentifier: String, isAvailable: Bool, supportsOnDeviceRecognition: Bool) {
        self.localeIdentifier = localeIdentifier
        self.isAvailable = isAvailable
        self.supportsOnDeviceRecognition = supportsOnDeviceRecognition
    }
}

public protocol NativeSpeechRecognizerStatusProviding: Sendable {
    func supportedLocaleIdentifiers() -> [String]
    func recognizerInfo(localeIdentifier: String?) -> NativeSpeechRecognizerInfo?
}
