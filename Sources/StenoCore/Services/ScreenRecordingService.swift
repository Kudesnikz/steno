import AVFoundation
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

public enum RecordingError: LocalizedError, Sendable {
    case noDisplay
    case failedToAddRecordingOutput(String)
    case recordingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noDisplay:
            "No display is available for capture."
        case let .failedToAddRecordingOutput(message):
            "Failed to add recording output: \(message)"
        case let .recordingFailed(message):
            "Recording failed: \(message)"
        }
    }
}

public enum RecorderEvent: Sendable {
    case didStart
    case didFinish
    case didFail(String)
}

public final class ScreenRecordingService: NSObject, @unchecked Sendable {
    public typealias EventHandler = @Sendable (RecorderEvent) -> Void
    public typealias AudioHandler = @Sendable (RecordingAudioBuffer) -> Void

    private enum Lifecycle {
        case idle
        case starting
        case recording
        case stopping
        case finished
        case failed
    }

    private var stream: SCStream?
    private var recordingWriter: RealtimeRecordingWriter?
    private var audioMixer: RealtimeAudioMixer?
    private var eventHandler: EventHandler?
    private var audioHandler: AudioHandler?
    private var addedStreamOutputTypes: [SCStreamOutputType] = []
    private var mediaStartPTS: CMTime?
    private var systemVolume = 1.0
    private var microphoneVolume = 2.0
    private var lifecycle: Lifecycle = .idle
    private var didSendTerminalEvent = false
    private let stateLock = NSLock()

    public override init() {
        super.init()
    }

    public func start(
        outputURL: URL,
        preset: VideoQualityPreset,
        selectedDisplayID: String? = nil,
        systemVolume: Double = 1.0,
        microphoneVolume: Double = 2.0,
        audioHandler: AudioHandler? = nil,
        eventHandler: @escaping EventHandler
    ) async throws {
        setLifecycle(.starting)
        self.eventHandler = eventHandler
        self.audioHandler = audioHandler
        self.systemVolume = Self.sanitizedVolume(systemVolume, range: 0...2)
        self.microphoneVolume = Self.sanitizedVolume(microphoneVolume, range: 0...4)
        AppLog.info(
            "Starting recording width=\(preset.width) height=\(preset.height) fps=\(preset.fps) displayID=\(selectedDisplayID ?? "default") systemVolume=\(self.systemVolume) microphoneVolume=\(self.microphoneVolume)",
            category: .recording
        )

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            resetAfterStop()
            throw error
        }
        guard let display = selectedDisplay(from: content.displays, configuredID: selectedDisplayID) else {
            AppLog.error("Recording start failed: no display", category: .recording)
            resetAfterStop()
            throw RecordingError.noDisplay
        }

        try? FileManager.default.removeItem(at: outputURL)
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let audioMixer = RealtimeAudioMixer()
        let recordingWriter = try RealtimeRecordingWriter(
            outputURL: outputURL,
            preset: preset,
            audioFormat: audioMixer.outputFormat
        )

        let configuration = SCStreamConfiguration()
        configuration.width = preset.width
        configuration.height = preset.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(preset.fps, 1)))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 6
        configuration.showsCursor = true
        configuration.capturesAudio = true
        configuration.sampleRate = 44_100
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = true

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)

        do {
            try addStreamOutputs(to: stream)
        } catch {
            resetAfterStop()
            throw error
        }

        self.stream = stream
        self.recordingWriter = recordingWriter
        self.audioMixer = audioMixer

        do {
            try await startCapture(stream)
        } catch {
            removeStreamOutputs(from: stream)
            resetAfterStop()
            throw error
        }
        setLifecycle(.recording)
        self.eventHandler?(.didStart)
        AppLog.info("ScreenCaptureKit stream started", category: .recording)
    }

    private func selectedDisplay(from displays: [SCDisplay], configuredID: String?) -> SCDisplay? {
        guard !displays.isEmpty else {
            return nil
        }
        guard let configuredID, configuredID != CaptureDisplaySelection.legacyDefaultDisplayID else {
            return displays.first
        }
        return displays.first { String($0.displayID) == configuredID } ?? displays.first
    }

    public func stop() async throws {
        let shouldStop = beginStopping()
        let stream = self.stream
        let recordingWriter = self.recordingWriter
        let audioMixer = self.audioMixer

        guard shouldStop, let stream else {
            return
        }

        do {
            try await stopCapture(stream, timeoutSeconds: 3)
        } catch {
            AppLog.warning("Ignoring stopCapture failure during stop: \(error.localizedDescription)", category: .recording)
        }

        removeStreamOutputs(from: stream)

        do {
            for mixedBuffer in audioMixer?.flush() ?? [] {
                try recordingWriter?.appendAudio(
                    mixedBuffer.pcmBuffer,
                    startTimeSeconds: mixedBuffer.startTimeSeconds
                )
            }
            try await recordingWriter?.finish()
        } catch {
            AppLog.error("Realtime writer finish failed: \(error.localizedDescription)", category: .recording)
            resetAfterStop()
            throw error
        }

        AppLog.info("Recording stopped", category: .recording)
        emitTerminalEventIfNeeded(.didFinish)
        resetAfterStop()
    }

    private func startCapture(_ stream: SCStream) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            stream.startCapture { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func stopCapture(_ stream: SCStream, timeoutSeconds: Int) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let gate = ContinuationGate(continuation: continuation)
            stream.stopCapture { error in
                if let error {
                    gate.resume(throwing: error)
                } else {
                    gate.resume()
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                gate.resume(throwing: RecordingError.recordingFailed("Timed out while stopping ScreenCaptureKit stream."))
            }
        }
    }

    private func setLifecycle(_ value: Lifecycle) {
        stateLock.withLock {
            lifecycle = value
            if value == .starting {
                didSendTerminalEvent = false
                mediaStartPTS = nil
            }
        }
    }

    private func beginStopping() -> Bool {
        stateLock.withLock {
            switch lifecycle {
            case .starting, .recording, .failed:
                lifecycle = .stopping
                return true
            case .idle, .stopping, .finished:
                return false
            }
        }
    }

    private func resetAfterStop() {
        stateLock.withLock {
            lifecycle = .idle
            didSendTerminalEvent = false
        }
        stream = nil
        recordingWriter?.cancel()
        recordingWriter = nil
        audioMixer = nil
        eventHandler = nil
        audioHandler = nil
        addedStreamOutputTypes = []
    }

    private var isStopping: Bool {
        stateLock.withLock {
            lifecycle == .stopping
        }
    }

    private func emitTerminalEventIfNeeded(_ event: RecorderEvent) {
        let shouldEmit = stateLock.withLock {
            guard !didSendTerminalEvent else {
                return false
            }
            didSendTerminalEvent = true
            switch event {
            case .didFinish:
                lifecycle = .finished
            case .didFail:
                lifecycle = .failed
            case .didStart:
                break
            }
            return true
        }
        if shouldEmit {
            eventHandler?(event)
        }
    }

    private func addStreamOutputs(to stream: SCStream) throws {
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: nil)
            addedStreamOutputTypes.append(.screen)
            AppLog.info("Added screen stream output for realtime recording", category: .recording)
        } catch {
            AppLog.error("Screen stream output unavailable: \(error.localizedDescription)", category: .recording)
            throw RecordingError.failedToAddRecordingOutput(error.localizedDescription)
        }

        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: nil)
            addedStreamOutputTypes.append(.audio)
            AppLog.info("Added system audio stream output for realtime recording", category: .recording)
        } catch {
            AppLog.warning("System audio stream output unavailable: \(error.localizedDescription)", category: .recording)
        }

        if #available(macOS 15.0, *) {
            do {
                try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: nil)
                addedStreamOutputTypes.append(.microphone)
                AppLog.info("Added microphone stream output for realtime recording", category: .recording)
            } catch {
                AppLog.warning("Microphone stream output unavailable: \(error.localizedDescription)", category: .recording)
            }
        }
    }

    private func removeStreamOutputs(from stream: SCStream) {
        for type in addedStreamOutputTypes {
            do {
                try stream.removeStreamOutput(self, type: type)
            } catch {
                AppLog.warning("Ignoring removeStreamOutput failure during stop: \(error.localizedDescription)", category: .recording)
            }
        }
        addedStreamOutputTypes = []
    }

    private func relativeMediaStartTime(for sampleBuffer: CMSampleBuffer) -> Double? {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid, pts.seconds.isFinite else {
            return nil
        }
        return stateLock.withLock {
            if mediaStartPTS == nil {
                mediaStartPTS = pts
            }
            guard let mediaStartPTS else {
                return nil
            }
            return max(0, CMTimeSubtract(pts, mediaStartPTS).seconds)
        }
    }
}

extension ScreenRecordingService: SCStreamDelegate {
    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        if isStopping {
            AppLog.warning("Ignoring stream stop error during user stop: \(error.localizedDescription)", category: .recording)
            return
        }
        AppLog.error("ScreenCaptureKit stream stopped with error: \(error.localizedDescription)", category: .recording)
        emitTerminalEventIfNeeded(.didFail(error.localizedDescription))
    }
}

extension ScreenRecordingService: SCStreamOutput {
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let startTimeSeconds = relativeMediaStartTime(for: sampleBuffer) else {
            return
        }

        if type == .screen {
            appendVideo(sampleBuffer, startTimeSeconds: startTimeSeconds)
            return
        }

        let source: RecordingAudioSource
        switch type {
        case .audio:
            source = .system
        case .microphone:
            source = .microphone
        default:
            return
        }

        let duration = audioDuration(sampleBuffer: sampleBuffer)
        let rawLevel = AudioSampleBufferLevelAnalyzer.level(for: sampleBuffer)
        guard let pcmBuffer = copyPCMBuffer(from: sampleBuffer) else {
            AppLog.warning("Skipping audio buffer that could not be copied for transcription", category: .recording)
            return
        }
        let gain = volumeMultiplier(for: source)
        applyGain(gain, to: pcmBuffer)
        let level = RecordingAudioLevel(rms: rawLevel.rms * gain, peak: rawLevel.peak * gain)
        for mixedBuffer in audioMixer?.append(pcmBuffer, source: source, startTimeSeconds: startTimeSeconds) ?? [] {
            appendMixedAudio(mixedBuffer)
        }
        audioHandler?(RecordingAudioBuffer(
            source: source,
            startTimeSeconds: startTimeSeconds,
            durationSeconds: duration,
            pcmBuffer: pcmBuffer,
            level: level
        ))
    }

    private func appendVideo(_ sampleBuffer: CMSampleBuffer, startTimeSeconds: Double) {
        do {
            try recordingWriter?.appendVideo(sampleBuffer, startTimeSeconds: startTimeSeconds)
        } catch {
            handleRealtimeWriterError(error)
        }
    }

    private func appendMixedAudio(_ buffer: MixedRecordingAudioBuffer) {
        do {
            try recordingWriter?.appendAudio(buffer.pcmBuffer, startTimeSeconds: buffer.startTimeSeconds)
        } catch {
            handleRealtimeWriterError(error)
        }
    }

    private func handleRealtimeWriterError(_ error: any Error) {
        if isStopping {
            AppLog.warning("Ignoring realtime writer error during stop: \(error.localizedDescription)", category: .recording)
            return
        }
        AppLog.error("Realtime writer failed: \(error.localizedDescription)", category: .recording)
        emitTerminalEventIfNeeded(.didFail(error.localizedDescription))
    }

    private func volumeMultiplier(for source: RecordingAudioSource) -> Double {
        switch source {
        case .system:
            systemVolume
        case .microphone:
            microphoneVolume
        }
    }

    private func copyPCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return nil
        }

        let format = AVAudioFormat(cmAudioFormatDescription: formatDescription)
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        pcmBuffer.frameLength = frameCount

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcmBuffer.mutableAudioBufferList
        )
        guard status == noErr else {
            AppLog.warning("Failed to copy audio PCM buffer for transcription status=\(status)", category: .recording)
            return nil
        }
        return pcmBuffer
    }

    private func applyGain(_ gain: Double, to pcmBuffer: AVAudioPCMBuffer) {
        guard gain.isFinite, gain != 1 else {
            return
        }
        let asbd = pcmBuffer.format.streamDescription.pointee
        let flags = asbd.mFormatFlags
        let isFloat = flags & kAudioFormatFlagIsFloat != 0
        let isSignedInteger = flags & kAudioFormatFlagIsSignedInteger != 0
        let buffers = UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList)

        for buffer in buffers {
            guard let data = buffer.mData else {
                continue
            }
            if isFloat, asbd.mBitsPerChannel == 32 {
                scaleFloat32(data: data, byteCount: Int(buffer.mDataByteSize), gain: Float(gain))
            } else if isFloat, asbd.mBitsPerChannel == 64 {
                scaleFloat64(data: data, byteCount: Int(buffer.mDataByteSize), gain: gain)
            } else if isSignedInteger, asbd.mBitsPerChannel == 16 {
                scaleInt16(data: data, byteCount: Int(buffer.mDataByteSize), gain: gain)
            } else if isSignedInteger, asbd.mBitsPerChannel == 32 {
                scaleInt32(data: data, byteCount: Int(buffer.mDataByteSize), gain: gain)
            }
        }
    }

    private func scaleFloat32(data: UnsafeMutableRawPointer, byteCount: Int, gain: Float) {
        let values = data.bindMemory(to: Float.self, capacity: byteCount / MemoryLayout<Float>.stride)
        for index in 0..<(byteCount / MemoryLayout<Float>.stride) {
            values[index] *= gain
        }
    }

    private func scaleFloat64(data: UnsafeMutableRawPointer, byteCount: Int, gain: Double) {
        let values = data.bindMemory(to: Double.self, capacity: byteCount / MemoryLayout<Double>.stride)
        for index in 0..<(byteCount / MemoryLayout<Double>.stride) {
            values[index] *= gain
        }
    }

    private func scaleInt16(data: UnsafeMutableRawPointer, byteCount: Int, gain: Double) {
        let values = data.bindMemory(to: Int16.self, capacity: byteCount / MemoryLayout<Int16>.stride)
        for index in 0..<(byteCount / MemoryLayout<Int16>.stride) {
            let scaled = (Double(values[index]) * gain).rounded()
            values[index] = Int16(min(max(scaled, Double(Int16.min)), Double(Int16.max)))
        }
    }

    private func scaleInt32(data: UnsafeMutableRawPointer, byteCount: Int, gain: Double) {
        let values = data.bindMemory(to: Int32.self, capacity: byteCount / MemoryLayout<Int32>.stride)
        for index in 0..<(byteCount / MemoryLayout<Int32>.stride) {
            let scaled = (Double(values[index]) * gain).rounded()
            values[index] = Int32(min(max(scaled, Double(Int32.min)), Double(Int32.max)))
        }
    }

    private func audioDuration(sampleBuffer: CMSampleBuffer) -> Double {
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        if duration.isValid, duration.seconds.isFinite, duration.seconds > 0 {
            return duration.seconds
        }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return 0
        }
        let format = AVAudioFormat(cmAudioFormatDescription: formatDescription)
        guard format.sampleRate > 0 else {
            return 0
        }
        return Double(CMSampleBufferGetNumSamples(sampleBuffer)) / format.sampleRate
    }

    private static func sanitizedVolume(_ value: Double, range: ClosedRange<Double>) -> Double {
        guard value.isFinite else {
            return range.lowerBound
        }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

private final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?

    init(continuation: CheckedContinuation<Void, any Error>) {
        self.continuation = continuation
    }

    func resume() {
        take()?.resume()
    }

    func resume(throwing error: any Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<Void, any Error>? {
        lock.lock()
        defer { lock.unlock() }
        let continuation = continuation
        self.continuation = nil
        return continuation
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
