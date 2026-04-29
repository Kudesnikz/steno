import AppKit
import Foundation

/// Handles app-level quit and relaunch operations that SwiftUI scenes cannot
/// express directly.
@MainActor
public enum ApplicationLifecycleService {
    /// Asks AppKit to quit immediately without changing SwiftUI sheet state.
    public static func quit() {
        NSApp.terminate(nil)
    }

    /// Schedules a fresh copy of the current `.app` bundle after this process
    /// exits, then asks AppKit to quit immediately.
    public static func restart() {
        do {
            try scheduleRelaunchAfterCurrentProcessExits()
            NSApp.terminate(nil)
        } catch {
            AppLog.error("Application restart failed: \(error.localizedDescription)", category: .app)
            quit()
        }
    }

    private static func scheduleRelaunchAfterCurrentProcessExits() throws {
        guard let bundleURL = currentApplicationBundleURL() else {
            throw LifecycleError.missingApplicationBundle
        }

        let processID = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            """
            while /bin/kill -0 "$1" 2>/dev/null; do
                /bin/sleep 0.1
            done
            /usr/bin/open -n "$2"
            """,
            "steno-relaunch",
            String(processID),
            bundleURL.path
        ]
        try process.run()
    }

    private static func currentApplicationBundleURL() -> URL? {
        if let runningBundleURL = NSRunningApplication.current.bundleURL,
           runningBundleURL.pathExtension == "app" {
            return runningBundleURL
        }

        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else {
            return nil
        }
        return bundleURL
    }
}

private enum LifecycleError: LocalizedError {
    case missingApplicationBundle

    var errorDescription: String? {
        switch self {
        case .missingApplicationBundle:
            "Current process is not running from an application bundle."
        }
    }
}
