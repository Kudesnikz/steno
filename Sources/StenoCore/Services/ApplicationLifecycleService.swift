import AppKit
import Foundation

/// Handles app-level quit and relaunch operations that SwiftUI scenes cannot
/// express directly.
@MainActor
public enum ApplicationLifecycleService {
    /// Dismisses transient SwiftUI presentation state, then asks AppKit to quit.
    public static func quit(prepareForTermination: (() -> Void)? = nil) {
        prepareForTermination?()
        Task { @MainActor in
            await Task.yield()
            NSApp.terminate(nil)
        }
    }

    /// Launches a fresh copy of the current `.app` bundle, then quits this
    /// process so macOS privacy changes are picked up by the new instance.
    public static func restart(prepareForTermination: (() -> Void)? = nil) {
        prepareForTermination?()
        do {
            try launchFreshApplicationInstance()
            Task { @MainActor in
                await Task.yield()
                NSApp.terminate(nil)
            }
        } catch {
            AppLog.error("Application restart failed: \(error.localizedDescription)", category: .app)
            quit(prepareForTermination: nil)
        }
    }

    private static func launchFreshApplicationInstance() throws {
        guard let bundleURL = currentApplicationBundleURL() else {
            throw LifecycleError.missingApplicationBundle
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", bundleURL.path]
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
