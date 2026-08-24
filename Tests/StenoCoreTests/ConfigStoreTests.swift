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
        XCTAssertEqual(result.config.agents.count, AppConfig.defaultAgents.count)
        XCTAssertFalse(result.config.splitLargeMediaEnabled)
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
