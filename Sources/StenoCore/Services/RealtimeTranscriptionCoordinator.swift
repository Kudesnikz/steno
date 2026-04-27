import Foundation

public actor RealtimeTranscriptionCoordinator {
    public typealias UpdateHandler = @Sendable (TranscriptDocument) -> Void

    private let baseName: String
    private let saveDirectory: URL
    private let config: AppConfig
    private let transcriptionService: WhisperTranscriptionService
    private let onUpdate: UpdateHandler?
    private var document: TranscriptDocument
    private var states: [RecordingAudioSource: SourceState] = [:]
    private var lastCommittedEndBySource: [RecordingAudioSource: Double] = [:]
    private var isDraining = false

    private let sampleRate = AudioSampleBufferConverter.outputSampleRate
    private let windowSeconds = 10.0
    private let overlapSeconds = 1.0
    private let minimumFlushSeconds = 1.5

    public init(
        baseName: String,
        saveDirectory: URL,
        config: AppConfig,
        transcriptionService: WhisperTranscriptionService = WhisperTranscriptionService(),
        onUpdate: UpdateHandler? = nil
    ) {
        self.baseName = baseName
        self.saveDirectory = saveDirectory
        self.config = config
        self.transcriptionService = transcriptionService
        self.onUpdate = onUpdate
        self.document = TranscriptDocument(
            baseName: baseName,
            modelName: config.localTranscriptionModel,
            language: config.localTranscriptionLanguage
        )
    }

    public func accept(_ chunk: RecordingAudioChunk) async throws {
        guard config.localTranscriptionEnabled, !chunk.samples.isEmpty else {
            return
        }

        var state = states[chunk.source] ?? SourceState()
        if state.samples.isEmpty {
            state.startTimeSeconds = chunk.startTimeSeconds
        }
        state.samples.append(contentsOf: chunk.samples)
        states[chunk.source] = state

        guard !isDraining else {
            return
        }
        isDraining = true
        defer { isDraining = false }
        try await drain(force: false)
    }

    public func finish() async throws -> TranscriptDocument {
        while isDraining {
            try await Task.sleep(for: .milliseconds(100))
        }

        isDraining = true
        defer { isDraining = false }
        try await drain(force: true)
        try persist()
        return document
    }

    public func currentDocument() -> TranscriptDocument {
        document
    }

    private func drain(force: Bool) async throws {
        let sources = Array(states.keys).sorted { $0.rawValue < $1.rawValue }
        for source in sources {
            try await drain(source: source, force: force)
        }
    }

    private func drain(source: RecordingAudioSource, force: Bool) async throws {
        let windowSampleCount = Int(windowSeconds * sampleRate)
        let overlapSampleCount = Int(overlapSeconds * sampleRate)
        let minimumFlushSampleCount = Int(minimumFlushSeconds * sampleRate)

        while var state = states[source] {
            let shouldProcessFullWindow = state.samples.count >= windowSampleCount
            let shouldProcessFinalWindow = force && state.samples.count >= minimumFlushSampleCount
            guard shouldProcessFullWindow || shouldProcessFinalWindow else {
                states[source] = state
                return
            }

            let sampleCount = shouldProcessFullWindow ? windowSampleCount : state.samples.count
            let samples = Array(state.samples.prefix(sampleCount))
            let startTime = state.startTimeSeconds ?? 0
            if shouldProcessFullWindow {
                let removeCount = max(1, windowSampleCount - overlapSampleCount)
                state.samples.removeFirst(min(removeCount, state.samples.count))
                state.startTimeSeconds = startTime + Double(removeCount) / sampleRate
            } else {
                state.samples.removeAll(keepingCapacity: false)
                state.startTimeSeconds = nil
            }
            states[source] = state

            let segments = try await transcriptionService.transcribe(
                samples: samples,
                source: source,
                startTimeSeconds: startTime,
                config: config
            )
            appendCommittedSegments(segments, source: source)
        }
    }

    private func appendCommittedSegments(_ segments: [TranscriptSegment], source: RecordingAudioSource) {
        let lastEnd = lastCommittedEndBySource[source] ?? 0
        let committed = segments.filter { segment in
            segment.endTimeSeconds > lastEnd + 0.2
        }
        guard !committed.isEmpty else {
            return
        }
        document.append(committed)
        lastCommittedEndBySource[source] = max(lastEnd, committed.map(\.endTimeSeconds).max() ?? lastEnd)
        try? persist()
        onUpdate?(document)
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

private struct SourceState {
    var samples: [Float] = []
    var startTimeSeconds: Double?
}
