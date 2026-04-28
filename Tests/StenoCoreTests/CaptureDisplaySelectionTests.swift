@testable import StenoCore
import XCTest

final class CaptureDisplaySelectionTests: XCTestCase {
    func testSelectsPersistedDisplayWhenAvailable() {
        let displays = [
            CaptureDisplay(displayID: "111", name: "Built-in", width: 1512, height: 982, isMain: true),
            CaptureDisplay(displayID: "222", name: "Studio Display", width: 5120, height: 2880, isMain: false)
        ]

        let selected = CaptureDisplaySelection.selectedDisplay(configuredID: "222", displays: displays)

        XCTAssertEqual(selected?.id, "222")
    }

    func testLegacyDefaultFallsBackToMainDisplay() {
        let displays = [
            CaptureDisplay(displayID: "111", name: "External", width: 3840, height: 2160, isMain: false),
            CaptureDisplay(displayID: "222", name: "Built-in", width: 1512, height: 982, isMain: true)
        ]

        let selected = CaptureDisplaySelection.selectedDisplay(
            configuredID: CaptureDisplaySelection.legacyDefaultDisplayID,
            displays: displays
        )

        XCTAssertEqual(selected?.id, "222")
    }

    func testMissingPersistedDisplayFallsBackToMainDisplay() {
        let displays = [
            CaptureDisplay(displayID: "111", name: "External", width: 3840, height: 2160, isMain: false),
            CaptureDisplay(displayID: "222", name: "Built-in", width: 1512, height: 982, isMain: true)
        ]

        let selected = CaptureDisplaySelection.selectedDisplay(configuredID: "333", displays: displays)

        XCTAssertEqual(selected?.id, "222")
    }
}
