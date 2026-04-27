import Foundation

public struct RecordingInfo: Codable, Hashable, Sendable {
    public var durationSeconds: Int
    public var videoQuality: String
    public var videoPath: String
    public var microphoneAudioPath: String
    public var videoSizeMB: Double
    public var microphoneSizeMB: Double

    enum CodingKeys: String, CodingKey {
        case durationSeconds = "duration_seconds"
        case videoQuality = "video_quality"
        case videoPath = "video_path"
        case microphoneAudioPath = "mic_audio_path"
        case videoSizeMB = "video_size_mb"
        case microphoneSizeMB = "mic_size_mb"
    }

    public init(
        durationSeconds: Int,
        videoQuality: String,
        videoPath: String,
        microphoneAudioPath: String,
        videoSizeMB: Double,
        microphoneSizeMB: Double
    ) {
        self.durationSeconds = durationSeconds
        self.videoQuality = videoQuality
        self.videoPath = videoPath
        self.microphoneAudioPath = microphoneAudioPath
        self.videoSizeMB = videoSizeMB
        self.microphoneSizeMB = microphoneSizeMB
    }
}

public struct ReportTokens: Codable, Hashable, Sendable {
    public var input: Int
    public var output: Int
    public var total: Int

    public init(input: Int, output: Int, total: Int) {
        self.input = input
        self.output = output
        self.total = total
    }
}

public struct ReportInfo: Codable, Identifiable, Hashable, Sendable {
    public var id: String { "\(agentID)-\(createdAt)-\(outputPath)" }
    public var agentID: String
    public var agentName: String
    public var model: String
    public var createdAt: String
    public var processingDurationSeconds: Int
    public var tokens: ReportTokens
    public var outputPath: String
    public var status: String
    public var error: String?

    enum CodingKeys: String, CodingKey {
        case agentID = "agent_id"
        case agentName = "agent_name"
        case model
        case createdAt = "created_at"
        case processingDurationSeconds = "processing_duration_seconds"
        case tokens
        case outputPath = "output_path"
        case status
        case error
    }

    public init(
        agentID: String,
        agentName: String,
        model: String,
        createdAt: String,
        processingDurationSeconds: Int,
        tokens: ReportTokens,
        outputPath: String,
        status: String,
        error: String? = nil
    ) {
        self.agentID = agentID
        self.agentName = agentName
        self.model = model
        self.createdAt = createdAt
        self.processingDurationSeconds = processingDurationSeconds
        self.tokens = tokens
        self.outputPath = outputPath
        self.status = status
        self.error = error
    }
}

public struct SessionMetadata: Codable, Hashable, Sendable {
    public var name: String?
    public var createdAt: String?
    public var recording: RecordingInfo?
    public var reports: [ReportInfo]?

    enum CodingKeys: String, CodingKey {
        case name
        case createdAt = "created_at"
        case recording
        case reports
    }

    public init(name: String? = nil, createdAt: String? = nil, recording: RecordingInfo? = nil, reports: [ReportInfo]? = nil) {
        self.name = name
        self.createdAt = createdAt
        self.recording = recording
        self.reports = reports
    }
}

public struct MeetingSession: Identifiable, Hashable, Sendable {
    public var id: String { baseName }
    public var baseName: String
    public var baseURL: URL
    public var videoURL: URL
    public var metadataURL: URL
    public var audioURLs: [URL]
    public var reportURLsByAgentID: [String: URL]
    public var metadata: SessionMetadata
    public var modifiedAt: Date

    public init(
        baseName: String,
        baseURL: URL,
        videoURL: URL,
        metadataURL: URL,
        audioURLs: [URL],
        reportURLsByAgentID: [String: URL],
        metadata: SessionMetadata,
        modifiedAt: Date
    ) {
        self.baseName = baseName
        self.baseURL = baseURL
        self.videoURL = videoURL
        self.metadataURL = metadataURL
        self.audioURLs = audioURLs
        self.reportURLsByAgentID = reportURLsByAgentID
        self.metadata = metadata
        self.modifiedAt = modifiedAt
    }
}

public extension MeetingSession {
    var displayName: String {
        if let name = metadata.name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }

        let pattern = #"Meet_(\d{2}\.\d{2}\.\d{4}_\d{2}:\d{2}:\d{2})"#
        if let range = baseName.range(of: pattern, options: .regularExpression) {
            return String(baseName[range]).replacingOccurrences(of: "Meet_", with: "").replacingOccurrences(of: "_", with: " ")
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy HH:mm:ss"
        return formatter.string(from: modifiedAt)
    }

    var totalSizeMB: Double {
        let urls = [videoURL, metadataURL] + audioURLs + Array(reportURLsByAgentID.values)
        let totalBytes = urls.reduce(Int64(0)) { result, url in
            let value = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            return result + value
        }
        return Double(totalBytes) / 1_048_576.0
    }

    var sortedReportAgentIDs: [String] {
        reportURLsByAgentID.keys.sorted()
    }
}
