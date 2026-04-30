@testable import StenoCore
import XCTest

final class AudioActivityDetectorTests: XCTestCase {
    func testSilentSystemAudioIsNotSentToTranscription() {
        let samples = Array(repeating: Float.zero, count: 16_000)

        XCTAssertFalse(AudioActivityDetector.containsSpeech(samples: samples, source: .system))
    }

    func testLowNoiseSystemAudioIsNotSentToTranscription() {
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

    func testSpeechLikeWaveformIsSentToTranscription() {
        let sampleRate = 16_000.0
        let samples = (0..<16_000).map { index in
            Float(sin(2.0 * .pi * 220.0 * Double(index) / sampleRate) * 0.03)
        }

        XCTAssertTrue(AudioActivityDetector.containsSpeech(samples: samples, source: .system))
    }

    func testAudioLevelUsesSourceThresholds() {
        XCTAssertFalse(AudioActivityDetector.containsSpeech(level: RecordingAudioLevel(rms: 0.0005, peak: 0.002), source: .system))
        XCTAssertTrue(AudioActivityDetector.containsSpeech(level: RecordingAudioLevel(rms: 0.004, peak: 0.01), source: .system))
    }
}
