import Foundation

/// Current realtime Whisper backlog and finishing progress.
public struct TranscriptionProgress: Equatable, Sendable {
    public var queuedWindowCount: Int
    public var activeWindowCount: Int
    public var bufferedAudioSeconds: Double
    public var activeSourceCount: Int
    public var isProcessing: Bool
    public var isFinishing: Bool
    public var finishingTotalWindowCount: Int?

    public init(
        queuedWindowCount: Int,
        activeWindowCount: Int,
        bufferedAudioSeconds: Double,
        activeSourceCount: Int,
        isProcessing: Bool,
        isFinishing: Bool,
        finishingTotalWindowCount: Int? = nil
    ) {
        self.queuedWindowCount = max(0, queuedWindowCount)
        self.activeWindowCount = max(0, activeWindowCount)
        self.bufferedAudioSeconds = max(0, bufferedAudioSeconds)
        self.activeSourceCount = max(0, activeSourceCount)
        self.isProcessing = isProcessing
        self.isFinishing = isFinishing
        self.finishingTotalWindowCount = finishingTotalWindowCount
    }

    public static let idle = TranscriptionProgress(
        queuedWindowCount: 0,
        activeWindowCount: 0,
        bufferedAudioSeconds: 0,
        activeSourceCount: 0,
        isProcessing: false,
        isFinishing: false
    )

    public var remainingWindowCount: Int {
        queuedWindowCount + activeWindowCount
    }

    public var hasRealtimeBacklog: Bool {
        remainingWindowCount > 1
    }

    public var finishingCompletionFraction: Double? {
        guard let finishingTotalWindowCount, finishingTotalWindowCount > 0 else {
            return nil
        }
        let completed = max(0, finishingTotalWindowCount - remainingWindowCount)
        return min(1, Double(completed) / Double(finishingTotalWindowCount))
    }
}
