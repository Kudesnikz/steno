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
    private var recordingOutput: SCRecordingOutput?
    private var eventHandler: EventHandler?
    private var audioHandler: AudioHandler?
    private var audioSidecarWriter: RecordingAudioSidecarWriter?
    private var completedAudioSidecars: RecordingAudioSidecars?
    private var addedAudioOutputTypes: [SCStreamOutputType] = []
    private var audioStartPTS: CMTime?
    private var systemVolume = 1.0
    private var microphoneVolume = 2.0
    private var lifecycle: Lifecycle = .idle
    private var didFinishOutput = false
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
        self.completedAudioSidecars = nil
        self.audioSidecarWriter = RecordingAudioSidecarWriter(outputURL: outputURL)
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

        let outputConfiguration = SCRecordingOutputConfiguration()
        outputConfiguration.outputURL = outputURL
        outputConfiguration.videoCodecType = .h264
        outputConfiguration.outputFileType = .mp4

        let recordingOutput = SCRecordingOutput(configuration: outputConfiguration, delegate: self)
        do {
            try stream.addRecordingOutput(recordingOutput)
        } catch {
            AppLog.error("Failed to add recording output: \(error.localizedDescription)", category: .recording)
            resetAfterStop()
            throw RecordingError.failedToAddRecordingOutput(error.localizedDescription)
        }

        addAudioOutputs(to: stream)

        self.stream = stream
        self.recordingOutput = recordingOutput

        do {
            try await startCapture(stream)
        } catch {
            resetAfterStop()
            throw error
        }
        setLifecycle(.recording)
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
        let recordingOutput = self.recordingOutput

        guard shouldStop, let stream else {
            return
        }

        do {
            try await stopCapture(stream, timeoutSeconds: 3)
        } catch {
            AppLog.warning("Ignoring stopCapture failure during stop: \(error.localizedDescription)", category: .recording)
        }

        if let recordingOutput, shouldRemoveRecordingOutput {
            do {
                try stream.removeRecordingOutput(recordingOutput)
            } catch {
                AppLog.warning("Ignoring removeRecordingOutput failure during stop: \(error.localizedDescription)", category: .recording)
            }
        }

        removeAudioOutputs(from: stream)
        completedAudioSidecars = audioSidecarWriter?.finish()
        audioSidecarWriter = nil

        AppLog.info("Recording stopped", category: .recording)
        emitTerminalEventIfNeeded(.didFinish)
        resetAfterStop()
    }

    public func takeCompletedAudioSidecars() -> RecordingAudioSidecars? {
        let sidecars = completedAudioSidecars
        completedAudioSidecars = nil
        return sidecars
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

    private var shouldRemoveRecordingOutput: Bool {
        stateLock.withLock {
            !didFinishOutput
        }
    }

    private func setLifecycle(_ value: Lifecycle) {
        stateLock.withLock {
            lifecycle = value
            if value == .starting {
                didFinishOutput = false
                didSendTerminalEvent = false
                audioStartPTS = nil
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
            didFinishOutput = false
            didSendTerminalEvent = false
        }
        stream = nil
        recordingOutput = nil
        eventHandler = nil
        audioHandler = nil
        audioSidecarWriter?.discard()
        audioSidecarWriter = nil
        addedAudioOutputTypes = []
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
                didFinishOutput = true
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

    private func addAudioOutputs(to stream: SCStream) {
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: nil)
            addedAudioOutputTypes.append(.audio)
            AppLog.info("Added system audio stream output for transcription", category: .recording)
        } catch {
            AppLog.warning("System audio stream output unavailable: \(error.localizedDescription)", category: .recording)
        }

        if #available(macOS 15.0, *) {
            do {
                try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: nil)
                addedAudioOutputTypes.append(.microphone)
                AppLog.info("Added microphone stream output for transcription", category: .recording)
            } catch {
                AppLog.warning("Microphone stream output unavailable: \(error.localizedDescription)", category: .recording)
            }
        }
    }

    private func removeAudioOutputs(from stream: SCStream) {
        for type in addedAudioOutputTypes {
            do {
                try stream.removeStreamOutput(self, type: type)
            } catch {
                AppLog.warning("Ignoring removeStreamOutput failure during stop: \(error.localizedDescription)", category: .recording)
            }
        }
        addedAudioOutputTypes = []
    }

    private func relativeAudioStartTime(for sampleBuffer: CMSampleBuffer) -> Double? {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid, pts.seconds.isFinite else {
            return nil
        }
        return stateLock.withLock {
            if audioStartPTS == nil {
                audioStartPTS = pts
            }
            guard let audioStartPTS else {
                return nil
            }
            return max(0, CMTimeSubtract(pts, audioStartPTS).seconds)
        }
    }
}

extension ScreenRecordingService: SCRecordingOutputDelegate {
    public func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        AppLog.info("Recording output did start", category: .recording)
        eventHandler?(.didStart)
    }

    public func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        if isStopping {
            AppLog.warning("Ignoring recording output failure during stop: \(error.localizedDescription)", category: .recording)
            return
        }
        AppLog.error("Recording output failed: \(error.localizedDescription)", category: .recording)
        emitTerminalEventIfNeeded(.didFail(error.localizedDescription))
    }

    public func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        AppLog.info("Recording output did finish", category: .recording)
        emitTerminalEventIfNeeded(.didFinish)
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
        guard audioHandler != nil || audioSidecarWriter != nil else {
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

        guard let startTimeSeconds = relativeAudioStartTime(for: sampleBuffer) else {
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
        audioSidecarWriter?.append(pcmBuffer, source: source, startTimeSeconds: startTimeSeconds)
        audioHandler?(RecordingAudioBuffer(
            source: source,
            startTimeSeconds: startTimeSeconds,
            durationSeconds: duration,
            pcmBuffer: pcmBuffer,
            level: level
        ))
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

private final class RecordingAudioSidecarWriter: @unchecked Sendable {
    private struct SourceState {
        var url: URL
        var file: AVAudioFile
        var format: AVAudioFormat
        var firstStartTimeSeconds: Double
        var frameCount: AVAudioFramePosition
    }

    private let lock = NSLock()
    private let fileManager: FileManager
    private let directory: URL
    private let baseName: String
    private var states: [RecordingAudioSource: SourceState] = [:]
    private var isFinished = false

    init(outputURL: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        directory = fileManager.temporaryDirectory.appending(
            path: "steno-audio-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        baseName = outputURL.deletingPathExtension().lastPathComponent
    }

    func append(_ buffer: AVAudioPCMBuffer, source: RecordingAudioSource, startTimeSeconds: Double) {
        lock.withLock {
            guard !isFinished else {
                return
            }

            do {
                var state = try state(for: source, buffer: buffer, startTimeSeconds: startTimeSeconds)
                guard Self.format(state.format, matches: buffer.format) else {
                    AppLog.warning(
                        "Skipping \(source.rawValue) sidecar audio with changed format old=\(Self.describe(state.format)) new=\(Self.describe(buffer.format))",
                        category: .recording
                    )
                    return
                }
                try state.file.write(from: buffer)
                state.frameCount += AVAudioFramePosition(buffer.frameLength)
                states[source] = state
            } catch {
                AppLog.warning("Failed to write \(source.rawValue) sidecar audio: \(error.localizedDescription)", category: .recording)
            }
        }
    }

    func finish() -> RecordingAudioSidecars? {
        lock.withLock {
            isFinished = true
            let sidecars = RecordingAudioSidecars(
                system: sidecarFile(for: .system),
                microphone: sidecarFile(for: .microphone),
                temporaryDirectory: directory
            )
            states = [:]
            guard sidecars.hasAudio else {
                try? fileManager.removeItem(at: directory)
                return nil
            }
            AppLog.info(
                "Finished normalized audio sidecars system=\(sidecars.system?.url.lastPathComponent ?? "none") microphone=\(sidecars.microphone?.url.lastPathComponent ?? "none")",
                category: .recording
            )
            return sidecars
        }
    }

    func discard() {
        lock.withLock {
            isFinished = true
            states = [:]
            try? fileManager.removeItem(at: directory)
        }
    }

    private func state(
        for source: RecordingAudioSource,
        buffer: AVAudioPCMBuffer,
        startTimeSeconds: Double
    ) throws -> SourceState {
        if let state = states[source] {
            return state
        }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(baseName)_\(source.rawValue).caf")
        try? fileManager.removeItem(at: url)
        let file = try AVAudioFile(
            forWriting: url,
            settings: buffer.format.settings,
            commonFormat: buffer.format.commonFormat,
            interleaved: buffer.format.isInterleaved
        )
        AppLog.info(
            "Started normalized \(source.rawValue) audio sidecar format=\(Self.describe(buffer.format))",
            category: .recording
        )
        return SourceState(
            url: url,
            file: file,
            format: buffer.format,
            firstStartTimeSeconds: max(0, startTimeSeconds),
            frameCount: 0
        )
    }

    private func sidecarFile(for source: RecordingAudioSource) -> RecordingAudioSidecarFile? {
        guard let state = states[source],
              state.frameCount > 0,
              fileManager.fileExists(atPath: state.url.path) else {
            return nil
        }

        return RecordingAudioSidecarFile(
            url: state.url,
            startOffsetSeconds: state.firstStartTimeSeconds,
            durationSeconds: Double(state.frameCount) / state.format.sampleRate
        )
    }

    private static func format(_ lhs: AVAudioFormat, matches rhs: AVAudioFormat) -> Bool {
        lhs.commonFormat == rhs.commonFormat &&
            lhs.sampleRate == rhs.sampleRate &&
            lhs.channelCount == rhs.channelCount &&
            lhs.isInterleaved == rhs.isInterleaved
    }

    private static func describe(_ format: AVAudioFormat) -> String {
        "\(Int(format.sampleRate))Hz \(format.channelCount)ch \(format.commonFormat) interleaved=\(format.isInterleaved)"
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
