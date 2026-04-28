import Foundation
import whisper

public enum WhisperTranscriptionError: LocalizedError, Sendable {
    case modelNotFound(String)
    case contextInitializationFailed(String)
    case inferenceFailed

    public var errorDescription: String? {
        switch self {
        case let .modelNotFound(modelName):
            "Whisper model not found: \(modelName)."
        case let .contextInitializationFailed(path):
            "Failed to initialize Whisper context from \(path)."
        case .inferenceFailed:
            "Whisper inference failed."
        }
    }
}

public struct WhisperModelLocator: Sendable {
    public init() {}

    public func modelURL(named modelName: String) throws -> URL {
        if let url = Bundle.module.url(forResource: modelName, withExtension: "bin", subdirectory: "Models") {
            return url
        }
        let downloadedURL = UserPaths.whisperModelsDirectory.appending(path: "\(modelName).bin")
        if FileManager.default.fileExists(atPath: downloadedURL.path) {
            return downloadedURL
        }
        throw WhisperTranscriptionError.modelNotFound(modelName)
    }
}

public actor WhisperTranscriptionService {
    private let modelLocator: WhisperModelLocator
    private var contextBox: WhisperContextBox?
    private var loadedModelName: String?

    public init(modelLocator: WhisperModelLocator = WhisperModelLocator()) {
        self.modelLocator = modelLocator
    }

    public func transcribe(samples: [Float], source: RecordingAudioSource, startTimeSeconds: Double, config: AppConfig) async throws -> [TranscriptSegment] {
        guard !samples.isEmpty else {
            return []
        }

        let context = try loadContextIfNeeded(config: config)
        let language = normalizedLanguage(config.localTranscriptionLanguage)
        let threadCount = normalizedThreadCount(config.localTranscriptionThreadCount)
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.n_threads = Int32(threadCount)
        params.offset_ms = 0
        params.no_context = true
        params.single_segment = false
        params.temperature = 0
        params.temperature_inc = 0
        params.suppress_blank = true
        params.suppress_non_speech_tokens = true

        let result = language.withCString { languagePointer in
            params.language = languagePointer
            return samples.withUnsafeBufferPointer { buffer in
                whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
            }
        }
        guard result == 0 else {
            throw WhisperTranscriptionError.inferenceFailed
        }

        let segmentCount = whisper_full_n_segments(context)
        var segments: [TranscriptSegment] = []
        for index in 0..<segmentCount {
            guard let textPointer = whisper_full_get_segment_text(context, index) else {
                continue
            }
            let text = String(cString: textPointer).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                continue
            }
            let relativeStart = Double(whisper_full_get_segment_t0(context, index)) / 100
            let relativeEnd = Double(whisper_full_get_segment_t1(context, index)) / 100
            let absoluteStart = max(0, startTimeSeconds + relativeStart)
            let absoluteEnd = max(absoluteStart, startTimeSeconds + relativeEnd)
            segments.append(
                TranscriptSegment(
                    id: "\(source.rawValue)-\(Int((absoluteStart * 1000).rounded()))-\(index)",
                    source: source,
                    startTimeSeconds: absoluteStart,
                    endTimeSeconds: absoluteEnd,
                    text: text
                )
            )
        }
        return segments
    }

    private func loadContextIfNeeded(config: AppConfig) throws -> OpaquePointer {
        if let contextBox, loadedModelName == config.localTranscriptionModel {
            return contextBox.pointer
        }

        contextBox = nil
        loadedModelName = nil

        let modelURL = try modelLocator.modelURL(named: config.localTranscriptionModel)
        var contextParams = whisper_context_default_params()
        contextParams.use_gpu = config.localTranscriptionUseGPU
        contextParams.flash_attn = false

        guard let loadedContext = whisper_init_from_file_with_params(modelURL.path, contextParams) else {
            throw WhisperTranscriptionError.contextInitializationFailed(modelURL.path)
        }
        contextBox = WhisperContextBox(pointer: loadedContext)
        loadedModelName = config.localTranscriptionModel
        return loadedContext
    }

    private func normalizedLanguage(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? "auto" : trimmed
    }

    private func normalizedThreadCount(_ value: Int) -> Int {
        let requested = value > 0 ? value : max(1, ProcessInfo.processInfo.processorCount / 2)
        return max(1, min(4, requested))
    }
}

private final class WhisperContextBox: @unchecked Sendable {
    let pointer: OpaquePointer

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        whisper_free(pointer)
    }
}
