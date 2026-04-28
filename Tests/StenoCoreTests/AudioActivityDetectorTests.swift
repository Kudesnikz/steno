@testable import StenoCore
import XCTest

final class AudioActivityDetectorTests: XCTestCase {
    func testSilentSystemAudioIsNotSentToWhisper() {
        let samples = Array(repeating: Float.zero, count: 16_000)

        XCTAssertFalse(AudioActivityDetector.containsSpeech(samples: samples, source: .system))
    }

    func testLowNoiseSystemAudioIsNotSentToWhisper() {
        let samples = (0..<16_000).map { index in
            index.isMultiple(of: 2) ? Float(0.0004) : Float(-0.0004)
        }

        XCTAssertFalse(AudioActivityDetector.containsSpeech(samples: samples, source: .system))
    }

    func testIsolatedClickIsNotEnoughForSpeechActivity() {
        var samples = Array(repeating: Float.zero, count: 16_000)
        for index in 2_000..<2_080 {
            samples[index] = 0.5
        }

        XCTAssertFalse(AudioActivityDetector.containsSpeech(samples: samples, source: .system))
    }

    func testSpeechLikeWaveformIsSentToWhisper() {
        let sampleRate = 16_000.0
        let samples = (0..<16_000).map { index in
            Float(sin(2.0 * .pi * 220.0 * Double(index) / sampleRate) * 0.03)
        }

        XCTAssertTrue(AudioActivityDetector.containsSpeech(samples: samples, source: .system))
    }
}
