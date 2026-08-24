import AVFoundation
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

public struct SegmentedRecordingPolicy: Hashable, Sendable {
    public static let maximumSegmentDurationSeconds = 55 * 60
    public static let maximumSegmentBytes: Int64 = 1_800_000_000
    public static let sizeSafetyMarginBytes: Int64 = 8_000_000

    public var profile: SegmentedRecordingLimitProfile

    public init(profile: SegmentedRecordingLimitProfile) {
        self.profile = profile
    }

    public func stopReason(elapsedSeconds: Double, payloadBytes: Int64, partCount: Int) -> RecordingStopReason? {
        if elapsedSeconds >= Double(profile.maximumDurationSeconds) { return .durationLimit }
        if payloadBytes >= profile.maximumPayloadBytes - Self.sizeSafetyMarginBytes { return .sizeLimit }
        if partCount > profile.maximumVideoParts { return .partLimit }
        return nil
    }

    public func shouldRotateSegment(durationSeconds: Double, bytes: Int64) -> Bool {
        durationSeconds >= Double(Self.maximumSegmentDurationSeconds) ||
            bytes >= Self.maximumSegmentBytes - Self.sizeSafetyMarginBytes
    }
}

public struct SegmentedRecordingResult: Sendable {
    public var segments: [RecordingSegment]
    public var durationSeconds: Double
    public var stopReason: RecordingStopReason

    public init(segments: [RecordingSegment], durationSeconds: Double, stopReason: RecordingStopReason) {
        self.segments = segments.sorted { $0.index < $1.index }
        self.durationSeconds = durationSeconds
        self.stopReason = stopReason
    }
}

public enum SegmentedRecorderEvent: Sendable {
    case didStart
    case didFinalizeSegment(RecordingSegment)
    case didReachLimit(RecordingStopReason)
    case didFail(String)
}

public final class SegmentedScreenRecordingService: NSObject, @unchecked Sendable {
    public typealias EventHandler = @Sendable (SegmentedRecorderEvent) -> Void

    private enum Lifecycle {
        case idle
        case starting
        case recording
        case stopping
        case finished
        case failed
    }

    private final class SegmentContext: @unchecked Sendable {
        let index: Int
        let globalStartSeconds: Double
        let startTime: CMTime
        var lastVideoTime: CMTime
        let videoWriter: AVAssetWriter
        let videoInput: AVAssetWriterInput
        let systemAudioInput: AVAssetWriterInput
        let microphoneWriter: AVAssetWriter
        let microphoneInput: AVAssetWriterInput
        let temporaryVideoURL: URL
        let finalVideoURL: URL
        let temporaryMicrophoneURL: URL
        let finalMicrophoneURL: URL

        init(
            index: Int,
            globalStartSeconds: Double,
            startTime: CMTime,
            videoWriter: AVAssetWriter,
            videoInput: AVAssetWriterInput,
            systemAudioInput: AVAssetWriterInput,
            microphoneWriter: AVAssetWriter,
            microphoneInput: AVAssetWriterInput,
            temporaryVideoURL: URL,
            finalVideoURL: URL,
            temporaryMicrophoneURL: URL,
            finalMicrophoneURL: URL
        ) {
            self.index = index
            self.globalStartSeconds = globalStartSeconds
            self.startTime = startTime
            self.lastVideoTime = startTime
            self.videoWriter = videoWriter
            self.videoInput = videoInput
            self.systemAudioInput = systemAudioInput
            self.microphoneWriter = microphoneWriter
            self.microphoneInput = microphoneInput
            self.temporaryVideoURL = temporaryVideoURL
            self.finalVideoURL = finalVideoURL
            self.temporaryMicrophoneURL = temporaryMicrophoneURL
            self.finalMicrophoneURL = finalMicrophoneURL
        }

        var durationSeconds: Double {
            max(0, CMTimeGetSeconds(CMTimeSubtract(lastVideoTime, startTime)))
        }
    }

    private final class AssetWriterReference: @unchecked Sendable {
        let writer: AVAssetWriter
        let label: String

        init(_ writer: AVAssetWriter, label: String) {
            self.writer = writer
            self.label = label
        }
    }

    private let writerQueue = DispatchQueue(label: "com.steno.recording.segmented-writer", qos: .userInitiated)
    private let stateLock = NSLock()
    private var lifecycle: Lifecycle = .idle
    private var stream: SCStream?
    private var eventHandler: EventHandler?
    private var outputDirectory: URL?
    private var baseName = ""
    private var preset: VideoQualityPreset?
    private var policy: SegmentedRecordingPolicy?
    private var currentSegment: SegmentContext?
    private var finalizationTasks: [Task<RecordingSegment, any Error>] = []
    private var nextSegmentIndex = 0
    private var closedDurationSeconds = 0.0
    private var microphoneEnabled = true
    private var systemAudioEnabled = true
    private var didEmitLimit = false
    private var didEmitFailure = false
    private var lastPolicyCheckTime = CMTime.invalid
    private var loggedScreenFrameIssues: Set<String> = []

    public func start(
        outputDirectory: URL,
        baseName: String,
        preset: VideoQualityPreset,
        profile: SegmentedRecordingLimitProfile,
        selectedDisplayID: String? = nil,
        audioState: RecordingAudioState = RecordingAudioState(),
        eventHandler: @escaping EventHandler
    ) async throws {
        stateLock.withLock {
            lifecycle = .starting
            microphoneEnabled = audioState.microphoneEnabled
            systemAudioEnabled = audioState.systemAudioEnabled
            didEmitLimit = false
            didEmitFailure = false
        }
        self.outputDirectory = outputDirectory
        self.baseName = baseName
        self.preset = preset
        self.policy = SegmentedRecordingPolicy(profile: profile)
        self.eventHandler = eventHandler
        currentSegment = nil
        finalizationTasks = []
        nextSegmentIndex = 0
        closedDurationSeconds = 0
        lastPolicyCheckTime = .invalid
        loggedScreenFrameIssues = []

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        removeIncompleteArtifacts()

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
            self.stream = stream
            try await startCapture(stream)
        } catch {
            resetAfterStop()
            throw RecordingError.recordingFailed(error.localizedDescription)
        }
        stateLock.withLock { lifecycle = .recording }
        eventHandler(.didStart)
        AppLog.info(
            "Segmented MP4 recording started profile=\(profile.rawValue) width=\(preset.width) height=\(preset.height) fps=\(preset.fps)",
            category: .recording
        )
    }

    public func setMicrophoneEnabled(_ enabled: Bool) {
        stateLock.withLock { microphoneEnabled = enabled }
    }

    public func setSystemAudioEnabled(_ enabled: Bool) {
        stateLock.withLock { systemAudioEnabled = enabled }
    }

    public func stop(reason requestedReason: RecordingStopReason = .user) async throws -> SegmentedRecordingResult {
        let shouldStop = stateLock.withLock { () -> Bool in
            guard lifecycle == .recording || lifecycle == .starting || lifecycle == .failed else { return false }
            lifecycle = .stopping
            return true
        }
        guard shouldStop else {
            return SegmentedRecordingResult(segments: [], durationSeconds: 0, stopReason: requestedReason)
        }
        if let stream {
            do {
                try await stopCapture(stream, timeoutSeconds: 5)
            } catch {
                AppLog.warning("Ignoring ScreenCaptureKit stop failure: \(error.localizedDescription)", category: .recording)
            }
        }

        let tasks = await closeAllWriters()
        guard !tasks.isEmpty else {
            resetAfterStop()
            throw RecordingError.recordingFailed("No video frames were captured.")
        }
        do {
            var segments: [RecordingSegment] = []
            for task in tasks {
                segments.append(try await task.value)
            }
            let sorted = segments.sorted { $0.index < $1.index }
            let duration = sorted.reduce(0) { $0 + $1.durationSeconds }
            stateLock.withLock { lifecycle = .finished }
            resetAfterStop()
            return SegmentedRecordingResult(segments: sorted, durationSeconds: duration, stopReason: requestedReason)
        } catch {
            cancelWriters()
            resetAfterStop()
            throw RecordingError.recordingFailed("Segment finalization failed: \(error.localizedDescription)")
        }
    }

    private func append(_ sampleBuffer: CMSampleBuffer, type: SCStreamOutputType) {
        guard CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferDataIsReady(sampleBuffer),
              stateLock.withLock({ lifecycle == .recording || lifecycle == .stopping }) else { return }
        if type == .screen, !isCompleteScreenFrame(sampleBuffer) { return }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if type == .screen {
            do {
                try rotateBeforeFrameIfNeeded(at: presentationTime)
                if currentSegment == nil {
                    currentSegment = try makeSegment(startTime: presentationTime)
                }
            } catch {
                fail(error.localizedDescription)
                return
            }
        }
        guard let segment = currentSegment else { return }

        let input: AVAssetWriterInput?
        switch type {
        case .screen:
            input = segment.videoInput
            segment.lastVideoTime = presentationTime
        case .audio:
            if !stateLock.withLock({ systemAudioEnabled }) { zeroAudioData(in: sampleBuffer) }
            input = segment.systemAudioInput
        case .microphone:
            if !stateLock.withLock({ microphoneEnabled }) { zeroAudioData(in: sampleBuffer) }
            input = segment.microphoneInput
        @unknown default:
            input = nil
        }
        guard let input, input.isReadyForMoreMediaData else { return }
        if !input.append(sampleBuffer) {
            let error = type == .microphone ? segment.microphoneWriter.error : segment.videoWriter.error
            logWriterFailure(
                type == .microphone ? segment.microphoneWriter : segment.videoWriter,
                stage: "append",
                segmentIndex: segment.index,
                streamType: type
            )
            fail(error?.localizedDescription ?? "AVAssetWriter append failed")
            return
        }
        if type == .screen {
            checkPolicy(at: presentationTime, segment: segment)
        }
    }

    private func rotateBeforeFrameIfNeeded(at presentationTime: CMTime) throws {
        guard let segment = currentSegment, let policy else { return }
        let bytes = fileSize(at: segment.temporaryVideoURL) + fileSize(at: segment.temporaryMicrophoneURL)
        guard policy.shouldRotateSegment(durationSeconds: segment.durationSeconds, bytes: bytes) else { return }
        if nextSegmentIndex >= policy.profile.maximumVideoParts {
            emitLimitIfNeeded(.partLimit)
            return
        }
        closeCurrentSegment()
        currentSegment = try makeSegment(startTime: presentationTime)
    }

    private func checkPolicy(at presentationTime: CMTime, segment: SegmentContext) {
        if lastPolicyCheckTime.isValid,
           CMTimeGetSeconds(CMTimeSubtract(presentationTime, lastPolicyCheckTime)) < 0.5 {
            return
        }
        lastPolicyCheckTime = presentationTime
        guard let policy else { return }
        let payloadBytes = currentPayloadBytes()
        let elapsed = closedDurationSeconds + segment.durationSeconds
        if let reason = policy.stopReason(
            elapsedSeconds: elapsed,
            payloadBytes: payloadBytes,
            partCount: nextSegmentIndex
        ) {
            emitLimitIfNeeded(reason)
        }
    }

    private func makeSegment(startTime: CMTime) throws -> SegmentContext {
        guard let outputDirectory, let preset else {
            throw RecordingError.failedToConfigureWriter("Recording configuration is unavailable.")
        }
        let index = nextSegmentIndex
        nextSegmentIndex += 1
        let suffix = String(format: "%03d", index)
        let finalVideoURL = outputDirectory.appending(path: "\(baseName)_part_\(suffix).mp4")
        let finalMicrophoneURL = outputDirectory.appending(path: "\(baseName)_part_\(suffix)_mic.m4a")
        let temporaryVideoURL = outputDirectory.appending(path: ".\(baseName)_part_\(suffix).mp4.partial")
        let temporaryMicrophoneURL = outputDirectory.appending(path: ".\(baseName)_part_\(suffix)_mic.m4a.partial")
        [finalVideoURL, finalMicrophoneURL, temporaryVideoURL, temporaryMicrophoneURL].forEach {
            try? FileManager.default.removeItem(at: $0)
        }

        let videoWriter = try AVAssetWriter(outputURL: temporaryVideoURL, fileType: .mp4)
        Self.configureVideoWriter(videoWriter)
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
        let systemAudioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.systemAudioSettings())
        systemAudioInput.expectsMediaDataInRealTime = true
        guard videoWriter.canAdd(videoInput), videoWriter.canAdd(systemAudioInput) else {
            throw RecordingError.failedToConfigureWriter("MP4 writer rejected video or system audio input.")
        }
        videoWriter.add(videoInput)
        videoWriter.add(systemAudioInput)

        let microphoneWriter = try AVAssetWriter(outputURL: temporaryMicrophoneURL, fileType: .m4a)
        microphoneWriter.shouldOptimizeForNetworkUse = true
        let microphoneInput = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.microphoneAudioSettings())
        microphoneInput.expectsMediaDataInRealTime = true
        guard microphoneWriter.canAdd(microphoneInput) else {
            throw RecordingError.failedToConfigureWriter("M4A writer rejected microphone input.")
        }
        microphoneWriter.add(microphoneInput)
        guard videoWriter.startWriting() else {
            logWriterFailure(videoWriter, stage: "startWriting", segmentIndex: index, streamType: nil)
            throw RecordingError.failedToConfigureWriter(
                videoWriter.error?.localizedDescription ?? "MP4 startWriting failed"
            )
        }
        guard microphoneWriter.startWriting() else {
            logWriterFailure(microphoneWriter, stage: "startWriting", segmentIndex: index, streamType: .microphone)
            videoWriter.cancelWriting()
            throw RecordingError.failedToConfigureWriter(
                microphoneWriter.error?.localizedDescription ?? "M4A startWriting failed"
            )
        }
        videoWriter.startSession(atSourceTime: startTime)
        microphoneWriter.startSession(atSourceTime: startTime)
        AppLog.debug(
            "Asset writers started segment=\(index) mp4Fragmentation=disabled video=\(finalVideoURL.lastPathComponent) microphone=\(finalMicrophoneURL.lastPathComponent)",
            category: .recording
        )
        return SegmentContext(
            index: index,
            globalStartSeconds: closedDurationSeconds,
            startTime: startTime,
            videoWriter: videoWriter,
            videoInput: videoInput,
            systemAudioInput: systemAudioInput,
            microphoneWriter: microphoneWriter,
            microphoneInput: microphoneInput,
            temporaryVideoURL: temporaryVideoURL,
            finalVideoURL: finalVideoURL,
            temporaryMicrophoneURL: temporaryMicrophoneURL,
            finalMicrophoneURL: finalMicrophoneURL
        )
    }

    private func closeCurrentSegment() {
        guard let segment = currentSegment else { return }
        currentSegment = nil
        closedDurationSeconds += segment.durationSeconds
        segment.videoInput.markAsFinished()
        segment.systemAudioInput.markAsFinished()
        segment.microphoneInput.markAsFinished()
        let handler = eventHandler
        let task = Task { [weak self] () throws -> RecordingSegment in
            guard let self else { throw RecordingError.recordingFailed("Recorder was released during finalization.") }
            let result = try await self.finalize(segment)
            handler?(.didFinalizeSegment(result))
            return result
        }
        finalizationTasks.append(task)
    }

    private func closeAllWriters() async -> [Task<RecordingSegment, any Error>] {
        await withCheckedContinuation { continuation in
            writerQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: [])
                    return
                }
                self.closeCurrentSegment()
                continuation.resume(returning: self.finalizationTasks)
            }
        }
    }

    private func finalize(_ segment: SegmentContext) async throws -> RecordingSegment {
        async let videoFinish: Void = finish(AssetWriterReference(
            segment.videoWriter,
            label: "segment=\(segment.index) stream=video+system-audio"
        ))
        async let microphoneFinish: Void = finish(AssetWriterReference(
            segment.microphoneWriter,
            label: "segment=\(segment.index) stream=microphone"
        ))
        _ = try await (videoFinish, microphoneFinish)
        try moveCompletedFile(from: segment.temporaryVideoURL, to: segment.finalVideoURL)
        try moveCompletedFile(from: segment.temporaryMicrophoneURL, to: segment.finalMicrophoneURL)
        try await validate(segment: segment)
        return RecordingSegment(
            index: segment.index,
            startSeconds: segment.globalStartSeconds,
            durationSeconds: segment.durationSeconds,
            videoPath: segment.finalVideoURL.lastPathComponent,
            microphoneAudioPath: segment.finalMicrophoneURL.lastPathComponent,
            videoSizeBytes: fileSize(at: segment.finalVideoURL),
            microphoneSizeBytes: fileSize(at: segment.finalMicrophoneURL)
        )
    }

    private func finish(_ reference: AssetWriterReference) async throws {
        try await withCheckedThrowingContinuation { continuation in
            reference.writer.finishWriting {
                let writer = reference.writer
                if writer.status == .completed {
                    AppLog.debug("Asset writer finalized \(reference.label)", category: .recording)
                    continuation.resume()
                } else {
                    AppLog.error(
                        "Asset writer finalization failed \(reference.label) status=\(String(describing: writer.status)) " +
                            Self.diagnosticDescription(for: writer.error),
                        category: .recording
                    )
                    continuation.resume(throwing: RecordingError.recordingFailed(
                        writer.error?.localizedDescription ?? "finishWriting failed"
                    ))
                }
            }
        }
    }

    static func configureVideoWriter(_ writer: AVAssetWriter) {
        writer.shouldOptimizeForNetworkUse = true
        // File boundaries are controlled by SegmentedRecordingPolicy. Keeping the MP4 itself
        // non-fragmented avoids CoreMedia MovieHeaderMaker failures during live capture.
        writer.movieFragmentInterval = .invalid
    }

    static func diagnosticDescription(for error: (any Error)?) -> String {
        guard let error else { return "error=nil" }
        return diagnosticDescription(for: error as NSError, depth: 0)
    }

    private static func diagnosticDescription(for error: NSError, depth: Int) -> String {
        var fields = [
            "domain=\(error.domain)",
            "code=\(error.code)",
            "description=\(error.localizedDescription)"
        ]
        if let reason = error.localizedFailureReason, !reason.isEmpty {
            fields.append("reason=\(reason)")
        }
        if let suggestion = error.localizedRecoverySuggestion, !suggestion.isEmpty {
            fields.append("recoverySuggestion=\(suggestion)")
        }
        let keys = error.userInfo.keys.map(String.init(describing:)).sorted()
        if !keys.isEmpty {
            fields.append("userInfoKeys=\(keys.joined(separator: ","))")
        }
        if depth < 8, let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            fields.append("underlying={\(diagnosticDescription(for: underlying, depth: depth + 1))}")
        }
        return fields.joined(separator: " ")
    }

    private func logWriterFailure(
        _ writer: AVAssetWriter,
        stage: String,
        segmentIndex: Int,
        streamType: SCStreamOutputType?
    ) {
        let stream = streamType.map(Self.streamDescription) ?? "video+system-audio"
        AppLog.error(
            "Asset writer failed stage=\(stage) segment=\(segmentIndex) stream=\(stream) " +
                "status=\(String(describing: writer.status)) output=\(writer.outputURL.lastPathComponent) " +
                Self.diagnosticDescription(for: writer.error),
            category: .recording
        )
    }

    private static func streamDescription(_ type: SCStreamOutputType) -> String {
        switch type {
        case .screen: "video"
        case .audio: "system-audio"
        case .microphone: "microphone"
        @unknown default: "unknown(\(type.rawValue))"
        }
    }

    private func isCompleteScreenFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
            let attachments = attachmentsArray.first,
            let statusRawValue = attachments[.status] as? Int,
            let status = SCFrameStatus(rawValue: statusRawValue) else {
            logScreenFrameIssueOnce(
                key: "missing-status",
                message: "Dropping screen frame without ScreenCaptureKit frame status"
            )
            return false
        }
        guard status == .complete else {
            logScreenFrameIssueOnce(
                key: "status-\(statusRawValue)",
                message: "Dropping non-complete ScreenCaptureKit frame status=\(String(describing: status)) rawValue=\(statusRawValue)"
            )
            return false
        }
        guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil else {
            logScreenFrameIssueOnce(
                key: "missing-image-buffer",
                message: "Dropping complete ScreenCaptureKit frame without image buffer"
            )
            return false
        }
        return true
    }

    private func logScreenFrameIssueOnce(key: String, message: String) {
        guard loggedScreenFrameIssues.insert(key).inserted else { return }
        AppLog.debug(message, category: .recording)
    }

    private func validate(segment: SegmentContext) async throws {
        let videoAsset = AVURLAsset(url: segment.finalVideoURL)
        let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
        let systemTracks = try await videoAsset.loadTracks(withMediaType: .audio)
        guard videoTracks.count == 1, systemTracks.count == 1 else {
            throw RecordingError.recordingFailed(
                "Part \(segment.index) must contain one video and one system-audio track; got \(videoTracks.count)/\(systemTracks.count)."
            )
        }
        let microphoneTracks = try await AVURLAsset(url: segment.finalMicrophoneURL).loadTracks(withMediaType: .audio)
        guard microphoneTracks.count == 1 else {
            throw RecordingError.recordingFailed(
                "Microphone part \(segment.index) must contain exactly one audio track; got \(microphoneTracks.count)."
            )
        }
    }

    private func moveCompletedFile(from source: URL, to destination: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: source, to: destination)
    }

    private func currentPayloadBytes() -> Int64 {
        guard let outputDirectory,
              let items = try? FileManager.default.contentsOfDirectory(at: outputDirectory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        return items
            .filter { $0.lastPathComponent.contains("\(baseName)_part_") }
            .reduce(Int64(0)) { $0 + fileSize(at: $1) }
    }

    private func fileSize(at url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }

    private func emitLimitIfNeeded(_ reason: RecordingStopReason) {
        let shouldEmit = stateLock.withLock {
            guard !didEmitLimit else { return false }
            didEmitLimit = true
            return true
        }
        if shouldEmit { eventHandler?(.didReachLimit(reason)) }
    }

    private func fail(_ message: String) {
        let shouldEmit = stateLock.withLock {
            lifecycle = .failed
            guard !didEmitFailure else { return false }
            didEmitFailure = true
            return true
        }
        if shouldEmit {
            AppLog.error("Segmented recording writer failed: \(message)", category: .recording)
            eventHandler?(.didFail(message))
        }
    }

    private func cancelWriters() {
        writerQueue.sync {
            currentSegment?.videoWriter.cancelWriting()
            currentSegment?.microphoneWriter.cancelWriting()
            currentSegment = nil
        }
    }

    private func removeIncompleteArtifacts() {
        guard let outputDirectory,
              let items = try? FileManager.default.contentsOfDirectory(at: outputDirectory, includingPropertiesForKeys: nil) else { return }
        for item in items where item.lastPathComponent.hasPrefix(".\(baseName)_part_") {
            try? FileManager.default.removeItem(at: item)
        }
    }

    private func resetAfterStop() {
        stateLock.withLock { lifecycle = .idle }
        stream = nil
        currentSegment = nil
        finalizationTasks = []
        eventHandler = nil
        outputDirectory = nil
        preset = nil
        policy = nil
    }

    private func selectedDisplay(from displays: [SCDisplay], configuredID: String?) -> SCDisplay? {
        guard !displays.isEmpty else { return nil }
        guard let configuredID, configuredID != CaptureDisplaySelection.legacyDefaultDisplayID else { return displays.first }
        return displays.first { String($0.displayID) == configuredID } ?? displays.first
    }

    private func startCapture(_ stream: SCStream) async throws {
        try await withCheckedThrowingContinuation { continuation in
            stream.startCapture { error in
                error.map { continuation.resume(throwing: $0) } ?? continuation.resume()
            }
        }
    }

    private func stopCapture(_ stream: SCStream, timeoutSeconds: Int) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let gate = SegmentedContinuationGate(continuation: continuation)
            stream.stopCapture { error in
                error.map { gate.resume(throwing: $0) } ?? gate.resume()
            }
            Task {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                gate.resume(throwing: RecordingError.recordingFailed("Timed out while stopping capture."))
            }
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

    private static func systemAudioSettings() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 160_000
        ]
    }

    private static func microphoneAudioSettings() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000
        ]
    }
}

extension SegmentedScreenRecordingService: SCStreamOutput {
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        append(sampleBuffer, type: type)
    }
}

extension SegmentedScreenRecordingService: SCStreamDelegate {
    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let isStopping = stateLock.withLock { lifecycle == .stopping }
        if !isStopping { fail(error.localizedDescription) }
    }
}

private final class SegmentedContinuationGate: @unchecked Sendable {
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
