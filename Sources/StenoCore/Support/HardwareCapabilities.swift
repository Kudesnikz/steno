import Foundation

/// Hardware feature gates that must be shared by settings, services, and tests.
public enum HardwareCapabilities {
    /// True only for the native Apple Silicon slice of the universal app.
    public static var isNativeAppleSilicon: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }
}
