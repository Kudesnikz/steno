@testable import StenoCore
import XCTest

final class StatusBarSnapshotTests: XCTestCase {
    func testRecordingTitleNormallyShowsOnlyElapsedTime() {
        let snapshot = makeSnapshot(recordingDuration: 3_661, remainingDuration: 301)

        XCTAssertEqual(snapshot.title, "01:01:01")
        XCTAssertFalse(snapshot.usesRemainingTimeWarning)
    }

    func testFiveMinutesRemainingStillShowsElapsedTime() {
        let snapshot = makeSnapshot(recordingDuration: 8_100, remainingDuration: 300)

        XCTAssertEqual(snapshot.title, "02:15:00")
        XCTAssertFalse(snapshot.usesRemainingTimeWarning)
    }

    func testLessThanFiveMinutesShowsHighlightedRemainingTime() {
        let snapshot = makeSnapshot(recordingDuration: 8_101, remainingDuration: 299)

        XCTAssertEqual(snapshot.title, "Rem. 04:59")
        XCTAssertTrue(snapshot.usesRemainingTimeWarning)
    }

    func testHiddenRecordingTimeSuppressesBothTitleAndWarning() {
        var snapshot = makeSnapshot(recordingDuration: 8_399, remainingDuration: 1)
        snapshot.showRecordingTime = false

        XCTAssertEqual(snapshot.title, "")
        XCTAssertFalse(snapshot.usesRemainingTimeWarning)
    }

    private func makeSnapshot(recordingDuration: Int, remainingDuration: Int?) -> StatusBarSnapshot {
        StatusBarSnapshot(
            isRecording: true,
            isFinalizingRecording: false,
            isProcessing: false,
            showRecordingTime: true,
            recordingDuration: recordingDuration,
            recordingRemainingDuration: remainingDuration,
            microphoneEnabled: true,
            systemAudioEnabled: true
        )
    }
}
