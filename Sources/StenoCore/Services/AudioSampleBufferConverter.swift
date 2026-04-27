@preconcurrency import AVFoundation
import CoreMedia
import Foundation

public enum AudioSampleConversionError: LocalizedError, Sendable {
    case missingFormatDescription
    case unsupportedAudioFormat
    case bufferAllocationFailed
    case pcmCopyFailed(OSStatus)
    case converterCreationFailed
    case conversionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingFormatDescription:
            "Audio sample buffer is missing a format description."
        case .unsupportedAudioFormat:
            "Audio sample buffer uses an unsupported format."
        case .bufferAllocationFailed:
            "Failed to allocate an audio conversion buffer."
        case let .pcmCopyFailed(status):
            "Failed to copy PCM data from sample buffer: \(status)."
        case .converterCreationFailed:
            "Failed to create audio converter."
        case let .conversionFailed(message):
            "Audio conversion failed: \(message)"
        }
    }
}

public final class AudioSampleBufferConverter: @unchecked Sendable {
    public static let outputSampleRate: Double = 16_000

    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outputSampleRate, channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var states: [RecordingAudioSource: ConverterState] = [:]

    public init() {}

    public func convert(sampleBuffer: CMSampleBuffer, source: RecordingAudioSource, startTimeSeconds: Double) throws -> RecordingAudioChunk? {
        try lock.withLock {
            try convertLocked(sampleBuffer: sampleBuffer, source: source, startTimeSeconds: startTimeSeconds)
        }
    }

    private func convertLocked(sampleBuffer: CMSampleBuffer, source: RecordingAudioSource, startTimeSeconds: Double) throws -> RecordingAudioChunk? {
        guard CMSampleBufferDataIsReady(sampleBuffer) else {
            return nil
        }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw AudioSampleConversionError.missingFormatDescription
        }
        let inputFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)

        let inputFrameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard inputFrameCount > 0,
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputFrameCount) else {
            return nil
        }
        inputBuffer.frameLength = inputFrameCount

        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(inputFrameCount),
            into: inputBuffer.mutableAudioBufferList
        )
        guard copyStatus == noErr else {
            throw AudioSampleConversionError.pcmCopyFailed(copyStatus)
        }

        var state = states[source]
        if state?.inputFormat != inputFormat {
            guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                throw AudioSampleConversionError.converterCreationFailed
            }
            converter.sampleRateConverterQuality = AVAudioQuality.medium.rawValue
            state = ConverterState(inputFormat: inputFormat, converter: converter)
        }
        guard let converter = state?.converter else {
            throw AudioSampleConversionError.converterCreationFailed
        }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount((Double(inputFrameCount) * ratio).rounded(.up)) + 64
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
            throw AudioSampleConversionError.bufferAllocationFailed
        }

        let inputProvider = ConverterInputProvider(buffer: inputBuffer)
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outputStatus in
            inputProvider.provide(outputStatus: outputStatus)
        }

        states[source] = state

        if status == .error {
            throw AudioSampleConversionError.conversionFailed(conversionError?.localizedDescription ?? "Unknown converter error")
        }
        guard outputBuffer.frameLength > 0,
              let channelData = outputBuffer.floatChannelData?[0] else {
            return nil
        }

        let sampleCount = Int(outputBuffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData, count: sampleCount))
        return RecordingAudioChunk(
            source: source,
            startTimeSeconds: startTimeSeconds,
            durationSeconds: Double(sampleCount) / Self.outputSampleRate,
            samples: samples
        )
    }
}

private struct ConverterState {
    var inputFormat: AVAudioFormat
    var converter: AVAudioConverter
}

private final class ConverterInputProvider: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var didProvideInput = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func provide(outputStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if didProvideInput {
            outputStatus.pointee = .noDataNow
            return nil
        }
        didProvideInput = true
        outputStatus.pointee = .haveData
        return buffer
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
