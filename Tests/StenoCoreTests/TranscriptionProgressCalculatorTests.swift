@testable import StenoCore
import XCTest

final class TranscriptionProgressCalculatorTests: XCTestCase {
    private let sampleRate = 16_000
    private var window: Int { 10 * sampleRate }
    private var stride: Int { 9 * sampleRate }
    private var minimumFlush: Int { Int(1.5 * Double(sampleRate)) }

    func testRealtimePendingWindowsUseOverlapStride() {
        XCTAssertEqual(
            TranscriptionProgressCalculator.pendingWindowCount(
                sampleCount: 10 * sampleRate,
                windowSampleCount: window,
                strideSampleCount: stride,
                minimumFlushSampleCount: minimumFlush,
                force: false
            ),
            1
        )

        XCTAssertEqual(
            TranscriptionProgressCalculator.pendingWindowCount(
                sampleCount: 19 * sampleRate,
                windowSampleCount: window,
                strideSampleCount: stride,
                minimumFlushSampleCount: minimumFlush,
                force: false
            ),
            2
        )
    }

    func testRealtimeDoesNotCountShortPartialWindow() {
        XCTAssertEqual(
            TranscriptionProgressCalculator.pendingWindowCount(
                sampleCount: 9 * sampleRate,
                windowSampleCount: window,
                strideSampleCount: stride,
                minimumFlushSampleCount: minimumFlush,
                force: false
            ),
            0
        )
    }

    func testFinishCountsFlushablePartialWindow() {
        XCTAssertEqual(
            TranscriptionProgressCalculator.pendingWindowCount(
                sampleCount: 2 * sampleRate,
                windowSampleCount: window,
                strideSampleCount: stride,
                minimumFlushSampleCount: minimumFlush,
                force: true
            ),
            1
        )
    }

    func testFinishKeepsOverlapBelowMinimumFlushOutOfQueue() {
        XCTAssertEqual(
            TranscriptionProgressCalculator.pendingWindowCount(
                sampleCount: 10 * sampleRate,
                windowSampleCount: window,
                strideSampleCount: stride,
                minimumFlushSampleCount: minimumFlush,
                force: true
            ),
            1
        )
    }

    func testFinishCountsFinalOverlapWhenEnoughAudioRemainsAfterFullWindows() {
        XCTAssertEqual(
            TranscriptionProgressCalculator.pendingWindowCount(
                sampleCount: Int(20.6 * Double(sampleRate)),
                windowSampleCount: window,
                strideSampleCount: stride,
                minimumFlushSampleCount: minimumFlush,
                force: true
            ),
            3
        )
    }

    func testFinishingCompletionFractionUsesRemainingActiveAndQueuedWindows() {
        let progress = TranscriptionProgress(
            queuedWindowCount: 2,
            activeWindowCount: 1,
            bufferedAudioSeconds: 18,
            activeSourceCount: 1,
            isProcessing: true,
            isFinishing: true,
            finishingTotalWindowCount: 4
        )

        XCTAssertEqual(progress.remainingWindowCount, 3)
        XCTAssertEqual(progress.finishingCompletionFraction, 0.25)
    }
}
