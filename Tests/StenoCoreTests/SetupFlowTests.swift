import Foundation
@testable import StenoCore
import XCTest

@MainActor
final class SetupFlowTests: XCTestCase {
    func testRequiresSetupWhenConfigIsMissing() {
        var config = AppConfig.default
        config.apiKey = "AIza-test-key"

        XCTAssertTrue(AppViewModel.requiresSetup(
            config: config,
            didFindExistingConfig: false,
            permissionState: PermissionState(hasScreenCapture: true, hasMicrophone: true)
        ))
    }

    func testRequiresSetupWhenAnyPermissionIsMissing() {
        var config = AppConfig.default
        config.apiKey = "AIza-test-key"

        XCTAssertTrue(AppViewModel.requiresSetup(
            config: config,
            didFindExistingConfig: true,
            permissionState: PermissionState(hasScreenCapture: false, hasMicrophone: true)
        ))
        XCTAssertTrue(AppViewModel.requiresSetup(
            config: config,
            didFindExistingConfig: true,
            permissionState: PermissionState(hasScreenCapture: true, hasMicrophone: false)
        ))
        XCTAssertTrue(AppViewModel.requiresSetup(
            config: config,
            didFindExistingConfig: true,
            permissionState: PermissionState(hasScreenCapture: true, hasMicrophone: true, hasSpeechRecognition: false)
        ))
    }

    func testRequiresSetupWhenSelectedProviderCredentialsAreMissing() {
        var config = AppConfig.default
        config.apiKey = ""

        XCTAssertTrue(AppViewModel.requiresSetup(
            config: config,
            didFindExistingConfig: true,
            permissionState: PermissionState(hasScreenCapture: true, hasMicrophone: true)
        ))
    }

    func testDoesNotRequireSetupWhenConfigCredentialsAndPermissionsAreReady() {
        var config = AppConfig.default
        config.apiKey = "AIza-test-key"

        XCTAssertFalse(AppViewModel.requiresSetup(
            config: config,
            didFindExistingConfig: true,
            permissionState: PermissionState(hasScreenCapture: true, hasMicrophone: true)
        ))
    }
}
