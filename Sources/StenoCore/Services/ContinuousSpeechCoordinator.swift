import Foundation
@preconcurrency import Speech

public enum NativeSpeechTranscriptionError: LocalizedError, Sendable {
    case authorizationDenied(String)
    case dictationDisabled
    case recognizerUnavailable(String)
    case offlineRecognitionUnavailable(String)
    case recognitionFailed(String)
    case recognitionValidationTimedOut

    public var errorDescription: String? {
        switch self {
        case let .authorizationDenied(status):
            "Speech Recognition permission is required for offline transcription. Current status: \(status)."
        case .dictationDisabled:
            "Siri and Dictation are disabled. Enable Dictation in macOS Keyboard settings to use offline transcription."
        case let .recognizerUnavailable(language):
            "Apple Speech is unavailable for \(language)."
        case let .offlineRecognitionUnavailable(language):
            "Offline Apple Speech recognition is not available for \(language). Install the dictation language in macOS Settings."
        case let .recognitionFailed(message):
            "Apple Speech recognition failed: \(message)"
        case .recognitionValidationTimedOut:
            "Apple Speech readiness check timed out."
        }
    }

    var requiresDictationSettings: Bool {
        switch self {
        case .dictationDisabled, .offlineRecognitionUnavailable:
            true
        case .authorizationDenied, .recognizerUnavailable, .recognitionFailed, .recognitionValidationTimedOut:
            false
        }
    }

    static func recognitionFailure(for error: any Error) -> NativeSpeechTranscriptionError {
        if isDictationDisabled(error) {
            return .dictationDisabled
        }
        return .recognitionFailed(error.localizedDescription)
    }

    static func recognitionFailure(message: String) -> NativeSpeechTranscriptionError {
        if isDictationDisabledMessage(message) {
            return .dictationDisabled
        }
        return .recognitionFailed(message)
    }

    static func isDictationDisabled(_ error: any Error) -> Bool {
        isDictationDisabledMessage(error.localizedDescription)
    }

    static func isExpectedEmptyAudioPreflightError(_ error: any Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("no speech") ||
            message.contains("no utterance") ||
            message.contains("audio is empty") ||
            message.contains("recognition request was canceled")
    }

    private static func isDictationDisabledMessage(_ message: String) -> Bool {
        let normalized = message.lowercased()
        let mentionsDictation = normalized.contains("dictation") || normalized.contains("диктов")
        let mentionsDisabled = normalized.contains("disabled") ||
            normalized.contains("отключ") ||
            normalized.contains("выключ")
        return mentionsDictation && mentionsDisabled
    }
}

public actor NativeSpeechService {
    public init() {}

    public func requestAuthorizationIfNeeded() async throws {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .authorized {
            return
        }

        let resolvedStatus: SFSpeechRecognizerAuthorizationStatus
        if status == .notDetermined {
            resolvedStatus = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { authorizationStatus in
                    continuation.resume(returning: authorizationStatus)
                }
            }
        } else {
            resolvedStatus = status
        }

        guard resolvedStatus == .authorized else {
            throw NativeSpeechTranscriptionError.authorizationDenied(Self.description(for: resolvedStatus))
        }
    }

    public nonisolated func makeOfflineRecognizer(languageCode: String) throws -> SFSpeechRecognizer {
        let normalized = NativeSpeechDefaults.normalizedLanguageCode(languageCode)
        let recognizer: SFSpeechRecognizer?
        if normalized == NativeSpeechDefaults.systemLanguageCode {
            recognizer = SFSpeechRecognizer()
        } else {
            recognizer = SFSpeechRecognizer(locale: Locale(identifier: normalized))
        }

        guard let recognizer else {
            throw NativeSpeechTranscriptionError.recognizerUnavailable(normalized)
        }
        guard recognizer.isAvailable else {
            throw NativeSpeechTranscriptionError.recognizerUnavailable(recognizer.locale.identifier)
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw NativeSpeechTranscriptionError.offlineRecognitionUnavailable(recognizer.locale.identifier)
        }
        return recognizer
    }

    private nonisolated static func description(for status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .authorized:
            "authorized"
        case .denied:
            "denied"
        case .restricted:
            "restricted"
        case .notDetermined:
            "not determined"
        @unknown default:
            "unknown"
        }
    }
}

public actor ContinuousSpeechCoordinator {
    public typealias UpdateHandler = @Sendable (TranscriptDocument) -> Void
    public typealias ProgressHandler = @Sendable (TranscriptionProgress) -> Void

    private let baseName: String
    private let saveDirectory: URL
    private let config: AppConfig
    private let speechService: NativeSpeechService
    private let onUpdate: UpdateHandler?
    private let onProgress: ProgressHandler?
    private var document: TranscriptDocument
    private var sessions: [RecordingAudioSource: NativeSpeechSession] = [:]
    private var recentBuffers: [RecordingAudioSource: [RecordingAudioBuffer]] = [:]
    private var lastCommittedEndBySource: [RecordingAudioSource: Double] = [:]
    private var isFinishing = false
    private var didReturnFinalDocument = false
    private var lastReportedProgress: TranscriptionProgress?
    private var lastPartialUpdate = Date.distantPast
    private var pendingError: (any Error)?

    private let restartAfterSeconds = 48.0
    private let hardRestartSeconds = 55.0
    private let overlapSeconds = 2.0
    private let partialUpdateInterval = 0.25

    public init(
        baseName: String,
        saveDirectory: URL,
        config: AppConfig,
        speechService: NativeSpeechService = NativeSpeechService(),
        onUpdate: UpdateHandler? = nil,
        onProgress: ProgressHandler? = nil
    ) {
        self.baseName = baseName
        self.saveDirectory = saveDirectory
        self.config = config
        self.speechService = speechService
        self.onUpdate = onUpdate
        self.onProgress = onProgress
        self.document = TranscriptDocument(
            baseName: baseName,
            modelName: NativeSpeechDefaults.engineDisplayName,
            language: NativeSpeechDefaults.normalizedLanguageCode(config.localTranscriptionLanguage)
        )
    }

    public func prepare() async throws {
        guard config.localTranscriptionEnabled else {
            return
        }
        try await speechService.requestAuthorizationIfNeeded()
        _ = try speechService.makeOfflineRecognizer(languageCode: config.localTranscriptionLanguage)
    }

    public func accept(_ buffer: RecordingAudioBuffer) async throws {
        guard config.localTranscriptionEnabled, !isFinishing else {
            return
        }
        if let pendingError {
            throw pendingError
        }

        rememberRecentBuffer(buffer)
        var session = try activeSession(for: buffer.source, initialStartTime: buffer.startTimeSeconds)
        if shouldRotate(session: session, nextBuffer: buffer) {
            end(session)
            session = try startSession(
                source: buffer.source,
                initialStartTime: buffer.startTimeSeconds,
                includeOverlap: true
            )
        }

        session.append(buffer)
        reportProgress()
    }

    public func finish() async throws -> TranscriptDocument {
        isFinishing = true
        reportProgress(force: true)
        for session in sessions.values {
            end(session)
        }
        sessions.removeAll()

        try await Task.sleep(for: .milliseconds(1_600))
        if let pendingError {
            throw pendingError
        }

        try persist()
        didReturnFinalDocument = true
        isFinishing = false
        reportProgress(force: true)
        return document
    }

    public func currentDocument() -> TranscriptDocument {
        document
    }

    private func activeSession(for source: RecordingAudioSource, initialStartTime: Double) throws -> NativeSpeechSession {
        if let session = sessions[source] {
            return session
        }
        return try startSession(source: source, initialStartTime: initialStartTime, includeOverlap: false)
    }

    private func startSession(
        source: RecordingAudioSource,
        initialStartTime: Double,
        includeOverlap: Bool
    ) throws -> NativeSpeechSession {
        let overlap = includeOverlap ? recentBuffers[source] ?? [] : []
        let sessionStartTime = overlap.first?.startTimeSeconds ?? initialStartTime
        let sessionID = UUID().uuidString
        let recognizer = try speechService.makeOfflineRecognizer(languageCode: config.localTranscriptionLanguage)
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation

        let bridge = NativeSpeechRecognitionBridge(
            recognizer: recognizer,
            request: request,
            source: source,
            sessionID: sessionID,
            sessionStartTimeSeconds: sessionStartTime,
            coordinator: self
        )

        let session = NativeSpeechSession(
            id: sessionID,
            source: source,
            startTimeSeconds: sessionStartTime,
            bridge: bridge
        )
        sessions[source] = session

        for buffer in overlap {
            session.append(buffer)
        }
        AppLog.debug("Started Apple Speech session source=\(source.rawValue) id=\(sessionID)", category: .recording)
        return session
    }

    private func shouldRotate(session: NativeSpeechSession, nextBuffer: RecordingAudioBuffer) -> Bool {
        let elapsed = max(0, nextBuffer.endTimeSeconds - session.startTimeSeconds)
        if elapsed >= hardRestartSeconds {
            return true
        }
        return elapsed >= restartAfterSeconds && !AudioActivityDetector.containsSpeech(level: nextBuffer.level, source: nextBuffer.source)
    }

    private func end(_ session: NativeSpeechSession) {
        guard !session.didEndAudio else {
            return
        }
        session.didEndAudio = true
        session.endAudio()
        AppLog.debug("Ended Apple Speech session source=\(session.source.rawValue) id=\(session.id)", category: .recording)
    }

    private func rememberRecentBuffer(_ buffer: RecordingAudioBuffer) {
        var buffers = recentBuffers[buffer.source] ?? []
        buffers.append(buffer)
        let cutoff = buffer.endTimeSeconds - overlapSeconds
        buffers.removeAll { $0.endTimeSeconds < cutoff }
        recentBuffers[buffer.source] = buffers
    }

    fileprivate func handleRecognition(snapshot: NativeSpeechRecognitionSnapshot?, errorDescription: String?) {
        guard !didReturnFinalDocument else {
            return
        }

        if let errorDescription, snapshot == nil {
            AppLog.warning("Apple Speech task error: \(errorDescription)", category: .recording)
            if !isFinishing {
                pendingError = NativeSpeechTranscriptionError.recognitionFailure(message: errorDescription)
            }
            return
        }

        guard let snapshot else {
            return
        }

        if snapshot.isFinal {
            appendCommittedSegments(snapshot.segments, source: snapshot.source)
        } else {
            publishPartialSegments(snapshot.segments, source: snapshot.source)
        }
    }

    private func publishPartialSegments(_ segments: [TranscriptSegment], source: RecordingAudioSource) {
        let now = Date()
        guard now.timeIntervalSince(lastPartialUpdate) >= partialUpdateInterval else {
            return
        }
        lastPartialUpdate = now

        let lastEnd = lastCommittedEndBySource[source] ?? 0
        let provisional = TranscriptSegmentDeduplicator.filterForAppend(
            candidates: segments.filter { $0.endTimeSeconds > lastEnd + 0.2 },
            existingSegments: document.segments
        )
        guard !provisional.isEmpty else {
            return
        }

        var liveDocument = document
        liveDocument.append(provisional)
        onUpdate?(liveDocument)
    }

    private func appendCommittedSegments(_ segments: [TranscriptSegment], source: RecordingAudioSource) {
        let lastEnd = lastCommittedEndBySource[source] ?? 0
        let candidates = segments.filter { segment in
            segment.endTimeSeconds > lastEnd + 0.2
        }
        let committed = TranscriptSegmentDeduplicator.filterForAppend(
            candidates: candidates,
            existingSegments: document.segments
        )

        if let maxCandidateEnd = candidates.map(\.endTimeSeconds).max() {
            lastCommittedEndBySource[source] = max(lastEnd, maxCandidateEnd)
        }
        guard !committed.isEmpty else {
            return
        }

        document.append(committed)
        try? persist()
        onUpdate?(document)
        reportProgress(force: true)
    }

    private func reportProgress(force: Bool = false) {
        let progress = TranscriptionProgress(
            queuedWindowCount: 0,
            activeWindowCount: sessions.count,
            bufferedAudioSeconds: recentBuffers.values.flatMap { $0 }.map(\.durationSeconds).reduce(0, +),
            activeSourceCount: sessions.count,
            isProcessing: !sessions.isEmpty,
            isFinishing: isFinishing,
            finishingTotalWindowCount: isFinishing ? max(1, sessions.count) : nil
        )
        guard force || progress != lastReportedProgress else {
            return
        }
        lastReportedProgress = progress
        onProgress?(progress)
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let jsonData = try encoder.encode(document)
        try jsonData.write(to: transcriptURL, options: .atomic)
        try document.timestampedMarkdown.write(to: markdownURL, atomically: true, encoding: .utf8)
    }

    private var transcriptURL: URL {
        saveDirectory.appending(path: "\(baseName)_transcript.json")
    }

    private var markdownURL: URL {
        saveDirectory.appending(path: "\(baseName)_transcript.md")
    }
}

private final class NativeSpeechSession: @unchecked Sendable {
    let id: String
    let source: RecordingAudioSource
    let startTimeSeconds: Double
    private let bridge: NativeSpeechRecognitionBridge
    var didEndAudio = false

    init(
        id: String,
        source: RecordingAudioSource,
        startTimeSeconds: Double,
        bridge: NativeSpeechRecognitionBridge
    ) {
        self.id = id
        self.source = source
        self.startTimeSeconds = startTimeSeconds
        self.bridge = bridge
    }

    func append(_ buffer: RecordingAudioBuffer) {
        bridge.append(buffer)
    }

    func endAudio() {
        bridge.endAudio()
    }
}

private final class NativeSpeechRecognitionBridge: @unchecked Sendable {
    private let request: SFSpeechAudioBufferRecognitionRequest
    private let task: SFSpeechRecognitionTask

    init(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechAudioBufferRecognitionRequest,
        source: RecordingAudioSource,
        sessionID: String,
        sessionStartTimeSeconds: Double,
        coordinator: ContinuousSpeechCoordinator
    ) {
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak coordinator] result, error in
            let snapshot = result.map {
                NativeSpeechRecognitionSnapshot(
                    result: $0,
                    source: source,
                    sessionID: sessionID,
                    sessionStartTimeSeconds: sessionStartTimeSeconds
                )
            }
            let errorDescription = error?.localizedDescription
            Task { [snapshot, errorDescription] in
                guard let coordinator else {
                    return
                }
                await coordinator.handleRecognition(snapshot: snapshot, errorDescription: errorDescription)
            }
        }
    }

    func append(_ buffer: RecordingAudioBuffer) {
        request.appendAudioSampleBuffer(buffer.sampleBuffer)
    }

    func endAudio() {
        request.endAudio()
    }

    deinit {
        task.cancel()
    }
}

fileprivate struct NativeSpeechRecognitionSnapshot: Sendable {
    var source: RecordingAudioSource
    var sessionID: String
    var isFinal: Bool
    var segments: [TranscriptSegment]

    init(
        result: SFSpeechRecognitionResult,
        source: RecordingAudioSource,
        sessionID: String,
        sessionStartTimeSeconds: Double
    ) {
        self.source = source
        self.sessionID = sessionID
        isFinal = result.isFinal
        segments = result.bestTranscription.segments.enumerated().compactMap { index, segment in
            let text = segment.substring.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return nil
            }
            let start = max(0, sessionStartTimeSeconds + segment.timestamp)
            let end = max(start, sessionStartTimeSeconds + segment.timestamp + segment.duration)
            return TranscriptSegment(
                id: "\(source.rawValue)-\(sessionID)-\(Int((start * 1000).rounded()))-\(index)",
                source: source,
                startTimeSeconds: start,
                endTimeSeconds: end,
                text: text
            )
        }
    }
}
