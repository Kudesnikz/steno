import AVFoundation
import Foundation

struct MixedRecordingAudioBuffer: @unchecked Sendable {
    var startTimeSeconds: Double
    var pcmBuffer: AVAudioPCMBuffer
}

final class RealtimeAudioMixer: @unchecked Sendable {
    private struct SourceSegment {
        var startFrame: Int64
        var left: [Float]
        var right: [Float]

        var endFrame: Int64 {
            startFrame + Int64(left.count)
        }
    }

    private struct ConverterState {
        var inputFormat: AVAudioFormat
        var converter: AVAudioConverter
    }

    private let lock = NSLock()
    private let outputSampleRate: Double
    private let outputChannelCount: AVAudioChannelCount
    let outputFormat: AVAudioFormat
    private let chunkFrameCount = 2_048
    private let latencyFrames: Int64
    private let maxSourceLagFrames: Int64

    private var converterStates: [RecordingAudioSource: ConverterState] = [:]
    private var segments: [RecordingAudioSource: [SourceSegment]] = [:]
    private var latestFrameBySource: [RecordingAudioSource: Int64] = [:]
    private var renderCursorFrame: Int64 = 0
    private var didRender = false
    private var lastDiagnosticFrame: Int64 = -1

    init(sampleRate: Double = 44_100, channelCount: AVAudioChannelCount = 2) {
        outputSampleRate = sampleRate
        outputChannelCount = channelCount
        outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: false
        )!
        latencyFrames = Int64((sampleRate * 0.20).rounded())
        maxSourceLagFrames = Int64((sampleRate * 0.80).rounded())
    }

    func append(
        _ buffer: AVAudioPCMBuffer,
        source: RecordingAudioSource,
        startTimeSeconds: Double
    ) -> [MixedRecordingAudioBuffer] {
        lock.withLock {
            do {
                let converted = try convert(buffer, source: source)
                let startFrame = max(0, Int64((startTimeSeconds * outputSampleRate).rounded()))
                store(converted, source: source, startFrame: startFrame)
                return renderAvailable(force: false)
            } catch {
                AppLog.warning("Skipping \(source.rawValue) audio mix buffer: \(error.localizedDescription)", category: .recording)
                return []
            }
        }
    }

    func flush() -> [MixedRecordingAudioBuffer] {
        lock.withLock {
            renderAvailable(force: true)
        }
    }

    private func convert(_ inputBuffer: AVAudioPCMBuffer, source: RecordingAudioSource) throws -> AVAudioPCMBuffer {
        if inputBuffer.format == outputFormat {
            return inputBuffer
        }

        var state = converterStates[source]
        if state?.inputFormat != inputBuffer.format {
            guard let converter = AVAudioConverter(from: inputBuffer.format, to: outputFormat) else {
                throw AudioSampleConversionError.converterCreationFailed
            }
            converter.sampleRateConverterQuality = AVAudioQuality.medium.rawValue
            state = ConverterState(inputFormat: inputBuffer.format, converter: converter)
        }
        guard let converter = state?.converter else {
            throw AudioSampleConversionError.converterCreationFailed
        }

        let ratio = outputFormat.sampleRate / inputBuffer.format.sampleRate
        let outputCapacity = AVAudioFrameCount((Double(inputBuffer.frameLength) * ratio).rounded(.up)) + 64
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
            throw AudioSampleConversionError.bufferAllocationFailed
        }

        let inputProvider = RealtimeMixerInputProvider(buffer: inputBuffer)
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outputStatus in
            inputProvider.provide(outputStatus: outputStatus)
        }

        converterStates[source] = state
        if status == .error {
            throw AudioSampleConversionError.conversionFailed(conversionError?.localizedDescription ?? "Unknown converter error")
        }
        return outputBuffer
    }

    private func store(_ buffer: AVAudioPCMBuffer, source: RecordingAudioSource, startFrame: Int64) {
        guard buffer.frameLength > 0,
              let channelData = buffer.floatChannelData else {
            return
        }

        let frameCount = Int(buffer.frameLength)
        let leftPointer = channelData[0]
        let rightPointer = outputChannelCount > 1 ? channelData[1] : channelData[0]
        let left = Array(UnsafeBufferPointer(start: leftPointer, count: frameCount))
        let right = Array(UnsafeBufferPointer(start: rightPointer, count: frameCount))
        var sourceSegments = segments[source] ?? []
        sourceSegments.append(SourceSegment(startFrame: startFrame, left: left, right: right))
        segments[source] = sourceSegments
        latestFrameBySource[source] = max(latestFrameBySource[source] ?? 0, startFrame + Int64(frameCount))
    }

    private func renderAvailable(force: Bool) -> [MixedRecordingAudioBuffer] {
        guard let maxLatestFrame = latestFrameBySource.values.max() else {
            return []
        }

        let targetFrame: Int64
        if force {
            targetFrame = maxLatestFrame
        } else if latestFrameBySource.count <= 1 {
            targetFrame = max(renderCursorFrame, maxLatestFrame - maxSourceLagFrames)
        } else {
            let minLatestFrame = latestFrameBySource.values.min() ?? maxLatestFrame
            let lag = maxLatestFrame - minLatestFrame
            let synchronizedTarget = lag > maxSourceLagFrames ? maxLatestFrame : minLatestFrame
            targetFrame = max(renderCursorFrame, synchronizedTarget - latencyFrames)
        }

        var rendered: [MixedRecordingAudioBuffer] = []
        while renderCursorFrame < targetFrame {
            let remaining = targetFrame - renderCursorFrame
            let frameCount: Int
            if force {
                frameCount = Int(min(Int64(chunkFrameCount), remaining))
            } else {
                guard remaining >= Int64(chunkFrameCount) else {
                    break
                }
                frameCount = chunkFrameCount
            }

            guard frameCount > 0 else {
                break
            }
            if let buffer = renderChunk(startFrame: renderCursorFrame, frameCount: frameCount) {
                rendered.append(buffer)
            }
            renderCursorFrame += Int64(frameCount)
            didRender = true
            trimConsumedSegments()
        }
        return rendered
    }

    private func renderChunk(startFrame: Int64, frameCount: Int) -> MixedRecordingAudioBuffer? {
        var left = Array(repeating: Float(0), count: frameCount)
        var right = Array(repeating: Float(0), count: frameCount)

        mix(source: .system, startFrame: startFrame, frameCount: frameCount, left: &left, right: &right)
        mix(source: .microphone, startFrame: startFrame, frameCount: frameCount, left: &left, right: &right)
        applyLimiter(left: &left, right: &right)

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        guard let channels = buffer.floatChannelData else {
            return nil
        }

        channels[0].update(from: left, count: frameCount)
        if outputChannelCount > 1 {
            channels[1].update(from: right, count: frameCount)
        }

        logDiagnosticIfNeeded(startFrame: startFrame, frameCount: frameCount, left: left, right: right)
        return MixedRecordingAudioBuffer(
            startTimeSeconds: Double(startFrame) / outputSampleRate,
            pcmBuffer: buffer
        )
    }

    private func mix(
        source: RecordingAudioSource,
        startFrame: Int64,
        frameCount: Int,
        left: inout [Float],
        right: inout [Float]
    ) {
        guard let sourceSegments = segments[source] else {
            return
        }
        let endFrame = startFrame + Int64(frameCount)
        for segment in sourceSegments {
            let overlapStart = max(startFrame, segment.startFrame)
            let overlapEnd = min(endFrame, segment.endFrame)
            guard overlapStart < overlapEnd else {
                continue
            }

            let destinationOffset = Int(overlapStart - startFrame)
            let sourceOffset = Int(overlapStart - segment.startFrame)
            let count = Int(overlapEnd - overlapStart)
            for index in 0..<count {
                left[destinationOffset + index] += segment.left[sourceOffset + index]
                right[destinationOffset + index] += segment.right[sourceOffset + index]
            }
        }
    }

    private func applyLimiter(left: inout [Float], right: inout [Float]) {
        for index in left.indices {
            left[index] = softLimit(left[index])
            right[index] = softLimit(right[index])
        }
    }

    private func softLimit(_ sample: Float) -> Float {
        let drive = 1.4
        let limited = tanh(Double(sample) * drive) / tanh(drive)
        return Float(max(-0.95, min(0.95, limited * 0.95)))
    }

    private func trimConsumedSegments() {
        for source in [RecordingAudioSource.system, .microphone] {
            guard var sourceSegments = segments[source] else {
                continue
            }
            sourceSegments.removeAll { $0.endFrame <= renderCursorFrame }
            segments[source] = sourceSegments
        }
    }

    private func logDiagnosticIfNeeded(startFrame: Int64, frameCount: Int, left: [Float], right: [Float]) {
        guard startFrame - lastDiagnosticFrame >= Int64(outputSampleRate) || !didRender else {
            return
        }
        lastDiagnosticFrame = startFrame
        var peak = 0.0
        var sumSquares = 0.0
        for index in 0..<frameCount {
            let sample = max(abs(Double(left[index])), abs(Double(right[index])))
            peak = max(peak, sample)
            sumSquares += sample * sample
        }
        let rms = sqrt(sumSquares / Double(max(frameCount, 1)))
        AppLog.debug(
            "Realtime audio mix frames=\(frameCount) start=\(String(format: "%.3f", Double(startFrame) / outputSampleRate))s rms=\(String(format: "%.5f", rms)) peak=\(String(format: "%.5f", peak))",
            category: .recording
        )
    }
}

private final class RealtimeMixerInputProvider: @unchecked Sendable {
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
