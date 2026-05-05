import Foundation
@testable import StenoCore
import XCTest

final class NativeSpeechAvailabilityTests: XCTestCase {
    func testBuildsSystemOptionFromResolvedRecognizerLocale() async {
        let service = NativeSpeechAvailabilityService(provider: FakeSpeechStatusProvider(
            supported: ["ru-RU", "en-US"],
            systemRecognizer: NativeSpeechRecognizerInfo(localeIdentifier: "ru-RU", isAvailable: true, supportsOnDeviceRecognition: true),
            recognizers: [
                "ru-RU": NativeSpeechRecognizerInfo(localeIdentifier: "ru-RU", isAvailable: true, supportsOnDeviceRecognition: true),
                "en-US": NativeSpeechRecognizerInfo(localeIdentifier: "en-US", isAvailable: true, supportsOnDeviceRecognition: false)
            ]
        ))

        let option = await service.option(forLanguageCode: "system")

        XCTAssertEqual(option.id, "system")
        XCTAssertEqual(option.resolvedLocaleIdentifier, "ru-RU")
        XCTAssertTrue(option.isOfflineAvailable)
    }

    func testReportsOfflineMissingLanguage() async {
        let service = NativeSpeechAvailabilityService(provider: FakeSpeechStatusProvider(
            supported: ["en-US"],
            systemRecognizer: NativeSpeechRecognizerInfo(localeIdentifier: "en-US", isAvailable: true, supportsOnDeviceRecognition: false),
            recognizers: [
                "en-US": NativeSpeechRecognizerInfo(localeIdentifier: "en-US", isAvailable: true, supportsOnDeviceRecognition: false)
            ]
        ))

        let option = await service.option(forLanguageCode: "en")

        XCTAssertEqual(option.localeIdentifier, "en-US")
        XCTAssertTrue(option.isSupported)
        XCTAssertFalse(option.isOfflineAvailable)
        XCTAssertEqual(option.statusText, "Requires dictation download")
    }

    func testReportsUnsupportedLocale() async {
        let service = NativeSpeechAvailabilityService(provider: FakeSpeechStatusProvider(
            supported: ["ru-RU"],
            systemRecognizer: nil,
            recognizers: [:]
        ))

        let option = await service.option(forLanguageCode: "fr-FR")

        XCTAssertEqual(option.localeIdentifier, "fr-FR")
        XCTAssertFalse(option.isSupported)
        XCTAssertFalse(option.isOfflineAvailable)
    }

    func testClassifiesDictationDisabledRecognitionError() {
        let error = NSError(
            domain: "kAFAssistantErrorDomain",
            code: 1101,
            userInfo: [NSLocalizedDescriptionKey: "Siri and Dictation are disabled"]
        )

        let mapped = NativeSpeechTranscriptionError.recognitionFailure(for: error)

        guard case .dictationDisabled = mapped else {
            XCTFail("Expected dictationDisabled, got \(mapped)")
            return
        }
        XCTAssertTrue(mapped.requiresDictationSettings)
    }

    func testTreatsNoSpeechAsSuccessfulEmptyAudioPreflight() {
        let error = NSError(
            domain: "kAFAssistantErrorDomain",
            code: 1110,
            userInfo: [NSLocalizedDescriptionKey: "No speech detected"]
        )

        XCTAssertTrue(NativeSpeechTranscriptionError.isExpectedEmptyAudioPreflightError(error))
        XCTAssertFalse(NativeSpeechTranscriptionError.isDictationDisabled(error))
    }
}

private struct FakeSpeechStatusProvider: NativeSpeechRecognizerStatusProviding {
    var supported: [String]
    var systemRecognizer: NativeSpeechRecognizerInfo?
    var recognizers: [String: NativeSpeechRecognizerInfo]

    func supportedLocaleIdentifiers() -> [String] {
        supported
    }

    func recognizerInfo(localeIdentifier: String?) -> NativeSpeechRecognizerInfo? {
        guard let localeIdentifier else {
            return systemRecognizer
        }
        return recognizers[localeIdentifier]
    }
}
