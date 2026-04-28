@preconcurrency import AVFoundation
import Foundation

public enum WhisperVoiceTestError: LocalizedError, Sendable {
    case missingInputDevice
    case recorderStartFailed(String)
    case emptyRecording

    public var errorDescription: String? {
        switch self {
        case .missingInputDevice:
            "No microphone input device is available."
        case let .recorderStartFailed(message):
            "Failed to start microphone test recording: \(message)"
        case .emptyRecording:
            "Microphone test recording did not capture audio."
        }
    }
}

public struct WhisperVoiceTestResult: Hashable, Sendable {
    public var transcript: String
    public var durationSeconds: Double

    public init(transcript: String, durationSeconds: Double) {
        self.transcript = transcript
        self.durationSeconds = durationSeconds
    }
}

public actor WhisperVoiceTestService {
    private let transcriptionService: WhisperTranscriptionService

    public init(transcriptionService: WhisperTranscriptionService = WhisperTranscriptionService()) {
        self.transcriptionService = transcriptionService
    }

    public func runTest(config: AppConfig, durationSeconds: Double = 5) async throws -> WhisperVoiceTestResult {
        let samples = try await MicrophoneSampleRecorder().record(durationSeconds: durationSeconds)
        let segments = try await transcriptionService.transcribe(
            samples: samples,
            source: .microphone,
            startTimeSeconds: 0,
            config: config
        )
        let text = segments.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return WhisperVoiceTestResult(transcript: text, durationSeconds: durationSeconds)
    }
}

private final class MicrophoneSampleRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var inputSampleRate: Double = 0

    func record(durationSeconds: Double) async throws -> [Float] {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw WhisperVoiceTestError.missingInputDevice
        }

        inputSampleRate = format.sampleRate
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self] buffer, _ in
            self?.append(buffer: buffer)
        }

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw WhisperVoiceTestError.recorderStartFailed(error.localizedDescription)
        }

        try await Task.sleep(for: .milliseconds(Int(max(1, durationSeconds) * 1_000)))
        engine.stop()
        input.removeTap(onBus: 0)

        let captured = lock.withLock { samples }
        guard !captured.isEmpty else {
            throw WhisperVoiceTestError.emptyRecording
        }
        return LinearPCMResampler.resampleMono(
            samples: captured,
            inputSampleRate: inputSampleRate,
            outputSampleRate: AudioSampleBufferConverter.outputSampleRate
        )
    }

    private func append(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else {
            return
        }
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        guard channelCount > 0, frameCount > 0 else {
            return
        }

        var mono = [Float](repeating: 0, count: frameCount)
        for channel in 0..<channelCount {
            let values = channelData[channel]
            for frame in 0..<frameCount {
                mono[frame] += values[frame] / Float(channelCount)
            }
        }

        lock.withLock {
            samples.append(contentsOf: mono)
        }
    }
}

private enum LinearPCMResampler {
    static func resampleMono(samples: [Float], inputSampleRate: Double, outputSampleRate: Double) -> [Float] {
        guard !samples.isEmpty, inputSampleRate > 0, outputSampleRate > 0 else {
            return samples
        }
        guard abs(inputSampleRate - outputSampleRate) > 0.1 else {
            return samples
        }

        let outputCount = max(1, Int((Double(samples.count) * outputSampleRate / inputSampleRate).rounded()))
        let ratio = inputSampleRate / outputSampleRate
        return (0..<outputCount).map { outputIndex in
            let inputPosition = Double(outputIndex) * ratio
            let lower = min(samples.count - 1, Int(inputPosition.rounded(.down)))
            let upper = min(samples.count - 1, lower + 1)
            let fraction = Float(inputPosition - Double(lower))
            return samples[lower] + (samples[upper] - samples[lower]) * fraction
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
