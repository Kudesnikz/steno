import Foundation

enum TranscriptionProgressCalculator {
    static func pendingWindowCount(
        sampleCount: Int,
        windowSampleCount: Int,
        strideSampleCount: Int,
        minimumFlushSampleCount: Int,
        force: Bool
    ) -> Int {
        guard sampleCount > 0,
              windowSampleCount > 0,
              strideSampleCount > 0,
              minimumFlushSampleCount > 0 else {
            return 0
        }

        guard sampleCount >= windowSampleCount else {
            return force && sampleCount >= minimumFlushSampleCount ? 1 : 0
        }

        let fullWindowCount = ((sampleCount - windowSampleCount) / strideSampleCount) + 1
        let remainingSampleCount = sampleCount - (fullWindowCount * strideSampleCount)
        if force && remainingSampleCount >= minimumFlushSampleCount {
            return fullWindowCount + 1
        }
        return fullWindowCount
    }

    static func bufferedAudioSeconds(sampleCount: Int, sampleRate: Double) -> Double {
        guard sampleCount > 0, sampleRate > 0 else {
            return 0
        }
        return Double(sampleCount) / sampleRate
    }
}
