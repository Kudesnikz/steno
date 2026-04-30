import Foundation
@testable import StenoCore
import XCTest

final class ConfigStoreTests: XCTestCase {
    func testMigratesLegacyPromptIntoDefaultAgent() throws {
        let root = try temporaryDirectory()
        let legacyURL = root.appending(path: ".recorder_app_config.json")
        let escapedPath = root.path.replacingOccurrences(of: "\\", with: "\\\\")
        let payload = """
        {
          "api_key": "abc",
          "prompt": "legacy prompt",
          "save_dir": "\(escapedPath)"
        }
        """
        try XCTUnwrap(payload.data(using: .utf8)).write(to: legacyURL)

        let store = ConfigStore(homeDirectory: root)
        let result = try store.load()

        XCTAssertTrue(result.didMigrateLegacyConfig)
        XCTAssertEqual(result.config.apiKey, "abc")
        XCTAssertEqual(result.config.agents.count, 1)
        XCTAssertEqual(result.config.agents[0].prompt, "legacy prompt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.configURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    func testLoadsDefaultsWhenConfigDoesNotExist() throws {
        let root = try temporaryDirectory()
        let store = ConfigStore(homeDirectory: root)
        let result = try store.load()

        XCTAssertFalse(result.didFindExistingConfig)
        XCTAssertEqual(result.config.modelName, AppConfig.default.modelName)
        XCTAssertEqual(result.config.localTranscriptionModel, NativeSpeechDefaults.engineID)
        XCTAssertEqual(result.config.localTranscriptionLanguage, NativeSpeechDefaults.defaultLanguageCode)
        XCTAssertEqual(result.config.localTranscriptionDefaultsRevision, NativeSpeechDefaults.currentDefaultsRevision)
        XCTAssertEqual(result.config.agents.count, AppConfig.defaultAgents.count)
    }

    func testDecodesLegacyTranscriptionSettingsIntoNativeSpeechDefaults() throws {
        let payload = """
        {
          "local_transcription_model": "ggml-small-q5_1",
          "local_transcription_language": "ru",
          "local_transcription_thread_count": 4,
          "local_transcription_use_gpu": true
        }
        """

        let config = try JSONDecoder().decode(AppConfig.self, from: try XCTUnwrap(payload.data(using: .utf8)))

        XCTAssertEqual(config.localTranscriptionModel, NativeSpeechDefaults.engineID)
        XCTAssertEqual(config.localTranscriptionLanguage, "ru-RU")
        XCTAssertEqual(config.localTranscriptionThreadCount, 4)
        XCTAssertTrue(config.localTranscriptionUseGPU)
    }

    func testNormalizesLegacyLanguageCodes() {
        XCTAssertEqual(NativeSpeechDefaults.normalizedLanguageCode(""), "system")
        XCTAssertEqual(NativeSpeechDefaults.normalizedLanguageCode("auto"), "system")
        XCTAssertEqual(NativeSpeechDefaults.normalizedLanguageCode("ru"), "ru-RU")
        XCTAssertEqual(NativeSpeechDefaults.normalizedLanguageCode("en"), "en-US")
        XCTAssertEqual(NativeSpeechDefaults.normalizedLanguageCode("de_DE"), "de-DE")
    }

    func testVideoQualityEstimateUsesConfiguredBitrate() {
        let preset = VideoQualityPreset(width: 1280, height: 720, fps: 10, bitrate: 3_000_000)

        XCTAssertEqual(preset.resolutionDescription, "1280x720")
        XCTAssertEqual(preset.bitrateDescription, "3 Mbps")
        XCTAssertEqual(preset.estimatedMegabytes(durationSeconds: 60), 22.5, accuracy: 0.001)
    }

    func testVideoQualityPresetFrameRatesMatchRecordingPolicy() throws {
        XCTAssertEqual(try XCTUnwrap(AppConfig.qualityPresets["Low"]).fps, 1)
        XCTAssertEqual(try XCTUnwrap(AppConfig.qualityPresets["Medium"]).fps, 5)
        XCTAssertEqual(try XCTUnwrap(AppConfig.qualityPresets["High"]).fps, 15)
        XCTAssertEqual(try XCTUnwrap(AppConfig.qualityPresets["Ultra"]).fps, 30)
    }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
