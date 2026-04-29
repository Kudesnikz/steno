@testable import StenoCore
import XCTest

final class WhisperAccelerationPolicyTests: XCTestCase {
    func testGPUAccelerationSupportFollowsNativeArchitecture() {
        #if arch(arm64)
        XCTAssertTrue(HardwareCapabilities.isNativeAppleSilicon)
        XCTAssertTrue(WhisperAccelerationPolicy.supportsGPUAcceleration)
        #else
        XCTAssertFalse(HardwareCapabilities.isNativeAppleSilicon)
        XCTAssertFalse(WhisperAccelerationPolicy.supportsGPUAcceleration)
        #endif
    }

    func testEffectiveGPUUseRequiresUserRequestAndSupportedHardware() {
        XCTAssertFalse(WhisperAccelerationPolicy.effectiveUseGPU(requested: false))

        #if arch(arm64)
        XCTAssertTrue(WhisperAccelerationPolicy.effectiveUseGPU(requested: true))
        #else
        XCTAssertFalse(WhisperAccelerationPolicy.effectiveUseGPU(requested: true))
        #endif
    }
}
