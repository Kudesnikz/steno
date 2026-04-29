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

/// Central policy for deciding whether Whisper may request Metal acceleration.
public enum WhisperAccelerationPolicy {
    public static var supportsGPUAcceleration: Bool {
        HardwareCapabilities.isNativeAppleSilicon
    }

    public static func effectiveUseGPU(requested: Bool) -> Bool {
        requested && supportsGPUAcceleration
    }
}
