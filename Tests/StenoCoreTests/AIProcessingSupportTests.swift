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
}

private func supportTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
