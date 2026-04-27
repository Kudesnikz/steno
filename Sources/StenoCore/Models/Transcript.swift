import Foundation

public enum RecordingAudioSource: String, Codable, Hashable, Sendable {
    case system
    case microphone

    public var displayName: String {
        switch self {
        case .system:
            "System"
        case .microphone:
            "Microphone"
        }
    }
}

public struct RecordingAudioChunk: Hashable, Sendable {
    public var source: RecordingAudioSource
    public var startTimeSeconds: Double
    public var durationSeconds: Double
    public var samples: [Float]

    public init(source: RecordingAudioSource, startTimeSeconds: Double, durationSeconds: Double, samples: [Float]) {
        self.source = source
        self.startTimeSeconds = startTimeSeconds
        self.durationSeconds = durationSeconds
        self.samples = samples
    }
}

public enum TranscriptionStatus: String, Codable, Hashable, Sendable {
    case disabled
    case running
    case completed
    case failed
}

public struct TranscriptionInfo: Codable, Hashable, Sendable {
    public var status: TranscriptionStatus
    public var modelName: String
    public var language: String
    public var transcriptPath: String
    public var markdownPath: String
    public var segmentCount: Int
    public var error: String?

    enum CodingKeys: String, CodingKey {
        case status
        case modelName = "model_name"
        case language
        case transcriptPath = "transcript_path"
        case markdownPath = "markdown_path"
        case segmentCount = "segment_count"
        case error
    }

    public init(
        status: TranscriptionStatus,
        modelName: String,
        language: String,
        transcriptPath: String,
        markdownPath: String,
        segmentCount: Int,
        error: String? = nil
    ) {
        self.status = status
        self.modelName = modelName
        self.language = language
        self.transcriptPath = transcriptPath
        self.markdownPath = markdownPath
        self.segmentCount = segmentCount
        self.error = error
    }
}

public struct TranscriptSegment: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var source: RecordingAudioSource
    public var startTimeSeconds: Double
    public var endTimeSeconds: Double
    public var text: String

    enum CodingKeys: String, CodingKey {
        case id
        case source
        case startTimeSeconds = "start_time_seconds"
        case endTimeSeconds = "end_time_seconds"
        case text
    }

    public init(
        id: String = UUID().uuidString,
        source: RecordingAudioSource,
        startTimeSeconds: Double,
        endTimeSeconds: Double,
        text: String
    ) {
        self.id = id
        self.source = source
        self.startTimeSeconds = startTimeSeconds
        self.endTimeSeconds = endTimeSeconds
        self.text = text
    }
}

public struct TranscriptDocument: Codable, Hashable, Sendable {
    public var baseName: String
    public var modelName: String
    public var language: String
    public var createdAt: String
    public var updatedAt: String
    public var segments: [TranscriptSegment]

    enum CodingKeys: String, CodingKey {
        case baseName = "base_name"
        case modelName = "model_name"
        case language
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case segments
    }

    public init(
        baseName: String,
        modelName: String,
        language: String,
        createdAt: String = ISO8601DateFormatter().string(from: Date()),
        updatedAt: String = ISO8601DateFormatter().string(from: Date()),
        segments: [TranscriptSegment] = []
    ) {
        self.baseName = baseName
        self.modelName = modelName
        self.language = language
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.segments = segments
    }

    public var sortedSegments: [TranscriptSegment] {
        segments.sorted {
            if $0.startTimeSeconds == $1.startTimeSeconds {
                return $0.source.rawValue < $1.source.rawValue
            }
            return $0.startTimeSeconds < $1.startTimeSeconds
        }
    }

    public var plainText: String {
        sortedSegments.map(\.text).joined(separator: "\n")
    }

    public var timestampedMarkdown: String {
        var lines = [
            "# Transcript",
            "",
            "- Model: \(modelName)",
            "- Language: \(language)",
            "- Segments: \(segments.count)",
            ""
        ]
        lines += sortedSegments.map { segment in
            let start = StenoFormatters.duration(Int(segment.startTimeSeconds.rounded(.down)))
            let end = StenoFormatters.duration(Int(segment.endTimeSeconds.rounded(.up)))
            return "[\(start)-\(end)] [\(segment.source.displayName)] \(segment.text)"
        }
        return lines.joined(separator: "\n")
    }

    public mutating func append(_ newSegments: [TranscriptSegment]) {
        segments.append(contentsOf: newSegments)
        segments = deduplicated(segments)
        updatedAt = ISO8601DateFormatter().string(from: Date())
    }

    private func deduplicated(_ values: [TranscriptSegment]) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        for segment in values.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds }) {
            let normalized = segment.text.normalizedTranscriptText
            guard !normalized.isEmpty else {
                continue
            }
            let isDuplicate = result.contains { existing in
                existing.source == segment.source &&
                    abs(existing.startTimeSeconds - segment.startTimeSeconds) < 1.5 &&
                    existing.text.normalizedTranscriptText == normalized
            }
            if !isDuplicate {
                result.append(segment)
            }
        }
        return result
    }
}

public struct AITranscriptContext: Hashable, Sendable {
    public var text: String
    public var fileName: String

    public init(text: String, fileName: String) {
        self.text = text
        self.fileName = fileName
    }
}

private extension String {
    var normalizedTranscriptText: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()
    }
}
