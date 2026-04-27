import AVFoundation
import Foundation
import CoreGraphics
import AppKit

public struct PermissionState: Hashable, Sendable {
    public var hasScreenCapture: Bool
    public var hasMicrophone: Bool

    public init(hasScreenCapture: Bool, hasMicrophone: Bool) {
        self.hasScreenCapture = hasScreenCapture
        self.hasMicrophone = hasMicrophone
    }
}

public struct PermissionsService: Sendable {
    public init() {}

    public func currentState() -> PermissionState {
        let state = PermissionState(
            hasScreenCapture: CGPreflightScreenCaptureAccess(),
            hasMicrophone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        )
        AppLog.debug("Permission state screen=\(state.hasScreenCapture) microphone=\(state.hasMicrophone)", category: .permissions)
        return state
    }

    public func requestScreenCaptureAccess() {
        AppLog.info("Requesting screen capture access", category: .permissions)
        _ = CGRequestScreenCaptureAccess()
    }

    public func requestMicrophoneAccess() async -> Bool {
        AppLog.info("Requesting microphone access", category: .permissions)
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        AppLog.info("Microphone access result granted=\(granted)", category: .permissions)
        return granted
    }

    public func openScreenCaptureSettings() {
        AppLog.info("Opening screen capture settings", category: .permissions)
        openSettings(urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    public func openMicrophoneSettings() {
        AppLog.info("Opening microphone settings", category: .permissions)
        openSettings(urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    private func openSettings(urlString: String) {
        guard let url = URL(string: urlString) else {
            return
        }
        Task { @MainActor in
            NSWorkspace.shared.open(url)
        }
    }
}
