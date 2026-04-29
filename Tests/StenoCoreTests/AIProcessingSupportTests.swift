import Foundation
@testable import StenoCore
import XCTest

final class AIProcessingSupportTests: XCTestCase {
    func testTimeoutFailureMentionsPhaseAndTimeout() {
        let error = AIProcessingFailure.requestTimedOut(
            phase: .generatingReport(provider: "Gemini API"),
            timeoutSeconds: 1_200
        )

        XCTAssertTrue(error.localizedDescription.contains("Generating report with Gemini API"))
        XCTAssertTrue(error.localizedDescription.contains("1200s"))
    }

    func testSingleRequestVideoLimitRejectsOversizedFile() throws {
        let directory = try supportTemporaryDirectory()
        let url = directory.appending(path: "large.mp4")
        try Data(repeating: 0, count: 2_048).write(to: url)

        XCTAssertThrowsError(
            try AIMediaLimits.validateSingleRequestVideo(url: url, provider: .openRouter, limitBytes: 1_024)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("large.mp4"))
            XCTAssertTrue(error.localizedDescription.contains("OpenRouter"))
        }
    }

    func testConnectionCheckStatusMatchesConfigAndIncludesResponseInTooltip() {
        var config = AppConfig.default
        config.aiProvider = .gemini
        config.modelName = "gemini-2.5-flash"
        config.baseURL = "https://generativelanguage.googleapis.com"

        let status = AIConnectionCheckStatus(
            outcome: .success,
            providerName: AIProviderID.gemini.displayName,
            providerID: .gemini,
            baseURL: config.baseURL,
            modelName: config.modelName,
            responseText: "ok",
            message: "Gemini API connection OK: gemini-2.5-flash",
            checkedAt: Date(timeIntervalSince1970: 0),
            durationSeconds: 0.42
        )

        XCTAssertTrue(status.matches(config: config))
        XCTAssertTrue(status.tooltip.contains("Response: ok"))

        config.modelName = "gemini-2.5-pro"
        XCTAssertFalse(status.matches(config: config))
    }

    func testConnectionCheckFailureTooltipIncludesErrorDetails() {
        let config = AppConfig.default
        let status = AIConnectionCheckStatus(
            outcome: .failure,
            providerName: config.aiProvider.displayName,
            providerID: config.aiProvider,
            baseURL: config.baseURL(for: config.aiProvider),
            modelName: config.modelName,
            responseText: nil,
            message: "API key rejected",
            checkedAt: Date(timeIntervalSince1970: 0),
            durationSeconds: 0.1
        )

        XCTAssertTrue(status.tooltip.contains("Connection failed"))
        XCTAssertTrue(status.tooltip.contains("Details: API key rejected"))
    }
}

private func supportTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
