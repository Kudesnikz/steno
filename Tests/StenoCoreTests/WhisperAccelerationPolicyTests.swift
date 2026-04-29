import Foundation
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

    func testDefaultConfigEnablesGPUOnlyWhenSupported() {
        XCTAssertEqual(AppConfig.default.localTranscriptionUseGPU, WhisperAccelerationPolicy.supportsGPUAcceleration)
    }

    func testDecodedConfigWithoutGPUFieldUsesHardwareDefault() throws {
        let config = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))

        XCTAssertEqual(config.localTranscriptionUseGPU, WhisperAccelerationPolicy.supportsGPUAcceleration)
    }
}
