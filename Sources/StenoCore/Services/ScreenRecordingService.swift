import AVFoundation
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

public enum RecordingError: LocalizedError, Sendable {
    case noDisplay
    case failedToConfigureWriter(String)
    case recordingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noDisplay:
            "No display is available for capture."
        case let .failedToConfigureWriter(message):
            "Failed to configure recording writer: \(message)"
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

    private enum Lifecycle {
        case idle
        case starting
        case recording
        case stopping
        case finished
        case failed
    }

    private let writerQueue = DispatchQueue(label: "com.steno.recording.writer", qos: .userInitiated)
    private let stateLock = NSLock()
    private let postProcessor: AudioPostProcessor
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemAudioInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
    private var eventHandler: EventHandler?
    private var lifecycle: Lifecycle = .idle
    private var didStartWriter = false
    private var didSendTerminalEvent = false
    private var microphoneEnabled = true
    private var systemAudioEnabled = true
    private var outputURL: URL?
    private var temporaryURL: URL?

    public init(postProcessor: AudioPostProcessor = AudioPostProcessor()) {
        self.postProcessor = postProcessor
        super.init()
    }

    public func start(
        outputURL: URL,
        preset: VideoQualityPreset,
        selectedDisplayID: String? = nil,
        audioState: RecordingAudioState = RecordingAudioState(),
        eventHandler: @escaping EventHandler
    ) async throws {
        stateLock.withLock {
            lifecycle = .starting
            didStartWriter = false
            didSendTerminalEvent = false
            microphoneEnabled = audioState.microphoneEnabled
            systemAudioEnabled = audioState.systemAudioEnabled
        }
        self.eventHandler = eventHandler
        self.outputURL = outputURL
        let temporaryURL = outputURL.deletingLastPathComponent().appending(
            path: ".\(outputURL.deletingPathExtension().lastPathComponent)_capture.mov"
        )
        self.temporaryURL = temporaryURL
        try? FileManager.default.removeItem(at: outputURL)
        try? FileManager.default.removeItem(at: temporaryURL)
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            resetAfterStop()
            throw error
        }
        guard let display = selectedDisplay(from: content.displays, configuredID: selectedDisplayID) else {
            resetAfterStop()
            throw RecordingError.noDisplay
        }

        do {
            try configureWriter(url: temporaryURL, preset: preset)
        } catch {
            resetAfterStop()
            throw RecordingError.failedToConfigureWriter(error.localizedDescription)
        }

        let configuration = SCStreamConfiguration()
        configuration.width = preset.width
        configuration.height = preset.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(preset.fps, 1)))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 6
        configuration.showsCursor = true
        configuration.capturesAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = true

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: writerQueue)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: writerQueue)
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: writerQueue)
        } catch {
            resetAfterStop()
            throw RecordingError.recordingFailed(error.localizedDescription)
        }
        self.stream = stream
        do {
            try await startCapture(stream)
        } catch {
            resetAfterStop()
            throw error
        }
        stateLock.withLock { lifecycle = .recording }
        eventHandler(.didStart)
        AppLog.info(
            "Controlled recording started width=\(preset.width) height=\(preset.height) fps=\(preset.fps)",
            category: .recording
        )
    }

    public func setMicrophoneEnabled(_ enabled: Bool) {
        stateLock.withLock { microphoneEnabled = enabled }
    }

    public func setSystemAudioEnabled(_ enabled: Bool) {
        stateLock.withLock { systemAudioEnabled = enabled }
    }

    public func stop() async throws {
        let shouldStop = stateLock.withLock { () -> Bool in
            guard lifecycle == .recording || lifecycle == .starting || lifecycle == .failed else { return false }
            lifecycle = .stopping
            return true
        }
        guard shouldStop, let stream else { return }
        do {
            try await stopCapture(stream, timeoutSeconds: 5)
        } catch {
            AppLog.warning("Ignoring ScreenCaptureKit stop failure: \(error.localizedDescription)", category: .recording)
        }
        guard let temporaryURL, let outputURL else {
            throw RecordingError.recordingFailed("Recording output paths were lost.")
        }
        do {
            try await finishWriter()
            try await finalizeRecording(temporaryURL: temporaryURL, outputURL: outputURL)
            try? FileManager.default.removeItem(at: temporaryURL)
            emitTerminalEventIfNeeded(.didFinish)
            resetAfterStop()
        } catch {
            writer?.cancelWriting()
            let recoveryURL = preserveRecovery(temporaryURL: temporaryURL, outputURL: outputURL)
            resetAfterStop()
            if let recoveryURL {
                throw RecordingError.recordingFailed(
                    "Finalization failed. Recovery file saved as \(recoveryURL.lastPathComponent): \(error.localizedDescription)"
                )
            }
            throw error
        }
    }

    private func configureWriter(url: URL, preset: VideoQualityPreset) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: preset.width,
            AVVideoHeightKey: preset.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: preset.bitrate,
                AVVideoMaxKeyFrameIntervalKey: max(1, preset.fps * 2),
                AVVideoExpectedSourceFrameRateKey: preset.fps
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        // QuickTime supports ScreenCaptureKit's native PCM formats. Keeping both
        // tracks as PCM avoids lossy resampling and allows different mic/system formats.
        let systemInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
        systemInput.expectsMediaDataInRealTime = true
        let microphoneInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
        microphoneInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(videoInput), writer.canAdd(systemInput), writer.canAdd(microphoneInput) else {
            throw RecordingError.failedToConfigureWriter("AVAssetWriter rejected one or more inputs.")
        }
        writer.add(videoInput)
        writer.add(systemInput)
        writer.add(microphoneInput)
        self.writer = writer
        self.videoInput = videoInput
        self.systemAudioInput = systemInput
        self.microphoneInput = microphoneInput
    }

    private func append(_ sampleBuffer: CMSampleBuffer, type: SCStreamOutputType) {
        guard CMSampleBufferDataIsReady(sampleBuffer), let writer else { return }
        if !didStartWriter {
            guard type == .screen else { return }
            guard writer.startWriting() else {
                failWriter(writer.error?.localizedDescription ?? "startWriting failed")
                return
            }
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            didStartWriter = true
        }
        guard writer.status == .writing else {
            if writer.status == .failed { failWriter(writer.error?.localizedDescription ?? "writer failed") }
            return
        }
        let input: AVAssetWriterInput?
        switch type {
        case .screen:
            input = videoInput
        case .audio:
            if !stateLock.withLock({ systemAudioEnabled }) { zeroAudioData(in: sampleBuffer) }
            input = systemAudioInput
        case .microphone:
            if !stateLock.withLock({ microphoneEnabled }) { zeroAudioData(in: sampleBuffer) }
            input = microphoneInput
        @unknown default:
            input = nil
        }
        guard let input, input.isReadyForMoreMediaData else { return }
        if !input.append(sampleBuffer) {
            failWriter(writer.error?.localizedDescription ?? "append failed")
        }
    }

    private func zeroAudioData(in sampleBuffer: CMSampleBuffer) {
        if let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
            let length = CMBlockBufferGetDataLength(blockBuffer)
            if length > 0 {
                _ = CMBlockBufferFillDataBytes(with: 0, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: length)
                return
            }
        }

        var requiredSize = 0
        var retainedBlock: CMBlockBuffer?
        _ = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &requiredSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &retainedBlock
        )
        guard requiredSize > 0 else { return }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: requiredSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        let list = storage.assumingMemoryBound(to: AudioBufferList.self)
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: list,
            bufferListSize: requiredSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &retainedBlock
        )
        guard status == noErr else { return }
        for buffer in UnsafeMutableAudioBufferListPointer(list) {
            if let data = buffer.mData, buffer.mDataByteSize > 0 {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }
    }

    private func finishWriter() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            writerQueue.async { [weak self] in
                guard let self, self.writer != nil else {
                    continuation.resume(throwing: RecordingError.recordingFailed("Writer is unavailable."))
                    return
                }
                guard self.didStartWriter else {
                    continuation.resume(throwing: RecordingError.recordingFailed("No video frames were captured."))
                    return
                }
                self.videoInput?.markAsFinished()
                self.systemAudioInput?.markAsFinished()
                self.microphoneInput?.markAsFinished()
                self.writer?.finishWriting { [weak self] in
                    guard let writer = self?.writer else {
                        continuation.resume(throwing: RecordingError.recordingFailed("Writer is unavailable."))
                        return
                    }
                    if writer.status == .completed {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: RecordingError.recordingFailed(
                            writer.error?.localizedDescription ?? "finishWriting failed"
                        ))
                    }
                }
            }
        }
    }

    private func finalizeRecording(temporaryURL: URL, outputURL: URL) async throws {
        let audioTracks = try await AVURLAsset(url: temporaryURL).loadTracks(withMediaType: .audio)
        let ffmpeg = postProcessor.ffmpegURL()
        var baseArguments = ["-y", "-i", temporaryURL.path, "-map", "0:v:0"]
        if audioTracks.count >= 2 {
            baseArguments += [
                "-filter_complex", "[0:a:0][0:a:1]amix=inputs=2:duration=longest:normalize=0,alimiter=limit=0.95[a]",
                "-map", "[a]", "-c:v", "copy", "-c:a", "aac", "-b:a", "160k"
            ]
        } else if audioTracks.count == 1 {
            baseArguments += ["-map", "0:a:0", "-c:v", "copy", "-c:a", "aac", "-b:a", "160k"]
        } else {
            baseArguments += ["-c:v", "copy", "-an"]
        }
        baseArguments += ["-movflags", "+faststart", outputURL.path]
        let arguments = ffmpeg.lastPathComponent == "env" ? ["ffmpeg"] + baseArguments : baseArguments
        do {
            _ = try await postProcessor.processRunner.runChecked(executableURL: ffmpeg, arguments: arguments)
        } catch {
            throw RecordingError.recordingFailed(
                "Audio finalization failed: \(error.localizedDescription)"
            )
        }
    }

    @discardableResult
    private func preserveRecovery(temporaryURL: URL, outputURL: URL) -> URL? {
        guard FileManager.default.fileExists(atPath: temporaryURL.path) else { return nil }
        let recoveryURL = outputURL.deletingLastPathComponent().appending(
            path: "\(outputURL.deletingPathExtension().lastPathComponent)_recovery.mov"
        )
        do {
            try? FileManager.default.removeItem(at: recoveryURL)
            try FileManager.default.copyItem(at: temporaryURL, to: recoveryURL)
            return recoveryURL
        } catch {
            AppLog.error("Could not preserve recording recovery file: \(error.localizedDescription)", category: .recording)
            return nil
        }
    }

    private func selectedDisplay(from displays: [SCDisplay], configuredID: String?) -> SCDisplay? {
        guard !displays.isEmpty else { return nil }
        guard let configuredID, configuredID != CaptureDisplaySelection.legacyDefaultDisplayID else { return displays.first }
        return displays.first { String($0.displayID) == configuredID } ?? displays.first
    }

    private func startCapture(_ stream: SCStream) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            stream.startCapture { error in
                error.map { continuation.resume(throwing: $0) } ?? continuation.resume()
            }
        }
    }

    private func stopCapture(_ stream: SCStream, timeoutSeconds: Int) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let gate = ContinuationGate(continuation: continuation)
            stream.stopCapture { error in
                error.map { gate.resume(throwing: $0) } ?? gate.resume()
            }
            Task {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                gate.resume(throwing: RecordingError.recordingFailed("Timed out while stopping capture."))
            }
        }
    }

    private func failWriter(_ message: String) {
        AppLog.error("Recording writer failed: \(message)", category: .recording)
        emitTerminalEventIfNeeded(.didFail(message))
    }

    private func emitTerminalEventIfNeeded(_ event: RecorderEvent) {
        let shouldEmit = stateLock.withLock {
            guard !didSendTerminalEvent else { return false }
            didSendTerminalEvent = true
            switch event {
            case .didFinish: lifecycle = .finished
            case .didFail: lifecycle = .failed
            case .didStart: break
            }
            return true
        }
        if shouldEmit { eventHandler?(event) }
    }

    private func resetAfterStop() {
        stateLock.withLock {
            lifecycle = .idle
            didStartWriter = false
            didSendTerminalEvent = false
        }
        stream = nil
        writer = nil
        videoInput = nil
        systemAudioInput = nil
        microphoneInput = nil
        eventHandler = nil
        outputURL = nil
        temporaryURL = nil
    }
}

extension ScreenRecordingService: SCStreamOutput {
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        append(sampleBuffer, type: type)
    }
}

extension ScreenRecordingService: SCStreamDelegate {
    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let isStopping = stateLock.withLock { lifecycle == .stopping }
        guard !isStopping else { return }
        emitTerminalEventIfNeeded(.didFail(error.localizedDescription))
    }
}

private final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?

    init(continuation: CheckedContinuation<Void, any Error>) {
        self.continuation = continuation
    }

    func resume() { take()?.resume() }
    func resume(throwing error: any Error) { take()?.resume(throwing: error) }

    private func take() -> CheckedContinuation<Void, any Error>? {
        lock.lock()
        defer { lock.unlock() }
        let value = continuation
        continuation = nil
        return value
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
