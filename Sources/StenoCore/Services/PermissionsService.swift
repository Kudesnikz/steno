import AVFoundation
import Foundation
import CoreGraphics
import AppKit
@preconcurrency import Speech

public struct PermissionState: Hashable, Sendable {
    public var hasScreenCapture: Bool
    public var hasMicrophone: Bool
    public var hasSpeechRecognition: Bool

    public init(hasScreenCapture: Bool, hasMicrophone: Bool, hasSpeechRecognition: Bool = true) {
        self.hasScreenCapture = hasScreenCapture
        self.hasMicrophone = hasMicrophone
        self.hasSpeechRecognition = hasSpeechRecognition
    }

    public var isFullyGranted: Bool {
        hasScreenCapture && hasMicrophone && hasSpeechRecognition
    }
}

public struct PermissionsService: Sendable {
    public init() {}

    public func currentState() -> PermissionState {
        let state = PermissionState(
            hasScreenCapture: CGPreflightScreenCaptureAccess(),
            hasMicrophone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            hasSpeechRecognition: SFSpeechRecognizer.authorizationStatus() == .authorized
        )
        AppLog.debug(
            "Permission state screen=\(state.hasScreenCapture) microphone=\(state.hasMicrophone) speech=\(state.hasSpeechRecognition)",
            category: .permissions
        )
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

    public func requestSpeechRecognitionAccess() async -> Bool {
        AppLog.info("Requesting speech recognition access", category: .permissions)
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        let granted = status == .authorized
        AppLog.info("Speech recognition access result granted=\(granted)", category: .permissions)
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

    public func openSpeechRecognitionSettings() {
        AppLog.info("Opening speech recognition privacy settings", category: .permissions)
        openSettings(urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
    }

    public func openDictationSettings() {
        AppLog.info("Opening dictation language settings", category: .permissions)
        openSettings(
            urlString: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Dictation",
            fallbackURLString: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
        )
    }

    private func openSettings(urlString: String, fallbackURLString: String? = nil) {
        guard let url = URL(string: urlString) else {
            return
        }
        Task { @MainActor in
            let didOpen = NSWorkspace.shared.open(url)
            if !didOpen,
               let fallbackURLString,
               let fallbackURL = URL(string: fallbackURLString) {
                NSWorkspace.shared.open(fallbackURL)
            }
        }
    }
}
