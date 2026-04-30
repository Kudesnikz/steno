import Foundation

struct AudioActivityDetector: Sendable {
    static func containsSpeech(samples: [Float], source: RecordingAudioSource) -> Bool {
        guard !samples.isEmpty else {
            return false
        }

        let thresholds = Thresholds(source: source)
        var validSampleCount = 0
        var activeSampleCount = 0
        var sumSquares = 0.0
        var peak = 0.0

        for sample in samples {
            guard sample.isFinite else {
                continue
            }
            let magnitude = abs(Double(sample))
            validSampleCount += 1
            sumSquares += magnitude * magnitude
            peak = max(peak, magnitude)
            if magnitude >= thresholds.activeSampleLevel {
                activeSampleCount += 1
            }
        }

        guard validSampleCount > 0 else {
            return false
        }

        let activeRatio = Double(activeSampleCount) / Double(validSampleCount)
        guard activeRatio >= thresholds.minimumActiveRatio else {
            return false
        }

        let rms = sqrt(sumSquares / Double(validSampleCount))
        return rms >= thresholds.minimumRMS || peak >= thresholds.minimumPeak
    }

    static func containsSpeech(level: RecordingAudioLevel, source: RecordingAudioSource) -> Bool {
        let thresholds = Thresholds(source: source)
        return level.rms >= thresholds.minimumRMS || level.peak >= thresholds.minimumPeak
    }
}

private struct Thresholds {
    var minimumRMS: Double
    var minimumPeak: Double
    var activeSampleLevel: Double
    var minimumActiveRatio: Double

    init(source: RecordingAudioSource) {
        switch source {
        case .system:
            minimumRMS = 0.002
            minimumPeak = 0.012
            activeSampleLevel = 0.003
            minimumActiveRatio = 0.01
        case .microphone:
            minimumRMS = 0.003
            minimumPeak = 0.018
            activeSampleLevel = 0.004
            minimumActiveRatio = 0.01
        }
    }
}
