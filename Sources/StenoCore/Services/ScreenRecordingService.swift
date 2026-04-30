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
    private var addedAudioOutputTypes: [SCStreamOutputType] = []
    private var audioStartPTS: CMTime?
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
        audioHandler: AudioHandler? = nil,
        eventHandler: @escaping EventHandler
    ) async throws {
        setLifecycle(.starting)
        self.eventHandler = eventHandler
        self.audioHandler = audioHandler
        AppLog.info(
            "Starting recording width=\(preset.width) height=\(preset.height) fps=\(preset.fps) displayID=\(selectedDisplayID ?? "default")",
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

        if audioHandler != nil {
            addAudioOutputs(to: stream)
        }

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
        guard let audioHandler else {
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
        let level = AudioSampleBufferLevelAnalyzer.level(for: sampleBuffer)
        audioHandler(RecordingAudioBuffer(
            source: source,
            startTimeSeconds: startTimeSeconds,
            durationSeconds: duration,
            sampleBuffer: sampleBuffer,
            level: level
        ))
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
