import Foundation
@preconcurrency import Speech

public struct SystemSpeechStatusProvider: NativeSpeechRecognizerStatusProviding {
    public init() {}

    public func supportedLocaleIdentifiers() -> [String] {
        SFSpeechRecognizer.supportedLocales().map(\.identifier).sorted()
    }

    public func recognizerInfo(localeIdentifier: String?) -> NativeSpeechRecognizerInfo? {
        let recognizer: SFSpeechRecognizer?
        if let localeIdentifier {
            recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
        } else {
            recognizer = SFSpeechRecognizer()
        }

        guard let recognizer else {
            return nil
        }
        return NativeSpeechRecognizerInfo(
            localeIdentifier: recognizer.locale.identifier,
            isAvailable: recognizer.isAvailable,
            supportsOnDeviceRecognition: recognizer.supportsOnDeviceRecognition
        )
    }
}

public actor NativeSpeechAvailabilityService {
    private let provider: any NativeSpeechRecognizerStatusProviding

    public init(provider: any NativeSpeechRecognizerStatusProviding = SystemSpeechStatusProvider()) {
        self.provider = provider
    }

    public func options() -> [NativeSpeechLanguageOption] {
        var values = [systemOption()]
        let supported = provider.supportedLocaleIdentifiers()
        values += supported.map { option(localeIdentifier: $0) }
        return values
    }

    public func option(for config: AppConfig) -> NativeSpeechLanguageOption {
        option(forLanguageCode: config.localTranscriptionLanguage)
    }

    public func option(forLanguageCode value: String) -> NativeSpeechLanguageOption {
        let normalized = NativeSpeechDefaults.normalizedLanguageCode(value)
        if normalized == NativeSpeechDefaults.systemLanguageCode {
            return systemOption()
        }
        return option(localeIdentifier: normalized)
    }

    public func refreshStatus(for config: AppConfig) -> NativeSpeechLanguageOption {
        option(for: config)
    }

    private func systemOption() -> NativeSpeechLanguageOption {
        let info = provider.recognizerInfo(localeIdentifier: nil)
        let resolved = info?.localeIdentifier ?? Locale.current.identifier
        return NativeSpeechLanguageOption(
            id: NativeSpeechDefaults.systemLanguageCode,
            localeIdentifier: NativeSpeechDefaults.systemLanguageCode,
            resolvedLocaleIdentifier: resolved,
            displayName: "System Language (\(displayName(for: resolved)))",
            isSystemSelection: true,
            isSupported: info != nil,
            isRecognizerAvailable: info?.isAvailable ?? false,
            isOfflineAvailable: info?.supportsOnDeviceRecognition ?? false
        )
    }

    private func option(localeIdentifier: String) -> NativeSpeechLanguageOption {
        let info = provider.recognizerInfo(localeIdentifier: localeIdentifier)
        let resolved = info?.localeIdentifier ?? localeIdentifier
        return NativeSpeechLanguageOption(
            id: localeIdentifier,
            localeIdentifier: localeIdentifier,
            resolvedLocaleIdentifier: resolved,
            displayName: displayName(for: resolved),
            isSystemSelection: false,
            isSupported: info != nil,
            isRecognizerAvailable: info?.isAvailable ?? false,
            isOfflineAvailable: info?.supportsOnDeviceRecognition ?? false
        )
    }

    private func displayName(for localeIdentifier: String) -> String {
        let locale = Locale(identifier: localeIdentifier)
        if let localized = Locale.current.localizedString(forIdentifier: localeIdentifier), !localized.isEmpty {
            return "\(localized) (\(localeIdentifier))"
        }
        if let languageCode = locale.language.languageCode?.identifier,
           let localized = Locale.current.localizedString(forLanguageCode: languageCode) {
            return "\(localized) (\(localeIdentifier))"
        }
        return localeIdentifier
    }
}
