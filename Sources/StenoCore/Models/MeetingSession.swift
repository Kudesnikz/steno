import Foundation

public enum RecordingStopReason: String, Codable, Hashable, Sendable {
    case user
    case durationLimit = "duration_limit"
    case sizeLimit = "size_limit"
    case partLimit = "part_limit"
    case failure
}

public struct RecordingSegment: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var index: Int
    public var startSeconds: Double
    public var durationSeconds: Double
    public var videoPath: String
    public var microphoneAudioPath: String?
    public var videoSizeBytes: Int64
    public var microphoneSizeBytes: Int64

    enum CodingKeys: String, CodingKey {
        case id
        case index
        case startSeconds = "start_seconds"
        case durationSeconds = "duration_seconds"
        case videoPath = "video_path"
        case microphoneAudioPath = "microphone_audio_path"
        case videoSizeBytes = "video_size_bytes"
        case microphoneSizeBytes = "microphone_size_bytes"
    }

    public init(
        id: String = UUID().uuidString,
        index: Int,
        startSeconds: Double,
        durationSeconds: Double,
        videoPath: String,
        microphoneAudioPath: String?,
        videoSizeBytes: Int64,
        microphoneSizeBytes: Int64
    ) {
        self.id = id
        self.index = index
        self.startSeconds = startSeconds
        self.durationSeconds = durationSeconds
        self.videoPath = videoPath
        self.microphoneAudioPath = microphoneAudioPath
        self.videoSizeBytes = videoSizeBytes
        self.microphoneSizeBytes = microphoneSizeBytes
    }

    public var totalSizeBytes: Int64 { videoSizeBytes + microphoneSizeBytes }
}

public struct SegmentedRecordingMetadataUpdate: Hashable, Sendable {
    public var duration: Int
    public var quality: String
    public var profile: SegmentedRecordingLimitProfile
    public var stopReason: RecordingStopReason?
    public var segments: [RecordingSegment]

    public init(
        duration: Int,
        quality: String,
        profile: SegmentedRecordingLimitProfile,
        stopReason: RecordingStopReason?,
        segments: [RecordingSegment]
    ) {
        self.duration = duration
        self.quality = quality
        self.profile = profile
        self.stopReason = stopReason
        self.segments = segments
    }
}

public struct RecordingInfo: Codable, Hashable, Sendable {
    public var durationSeconds: Int
    public var videoQuality: String
    public var videoPath: String
    public var microphoneAudioPath: String
    public var videoSizeMB: Double
    public var microphoneSizeMB: Double
    public var segmented: Bool
    public var limitProfileID: String?
    public var stopReason: RecordingStopReason?
    public var segments: [RecordingSegment]

    enum CodingKeys: String, CodingKey {
        case durationSeconds = "duration_seconds"
        case videoQuality = "video_quality"
        case videoPath = "video_path"
        case microphoneAudioPath = "mic_audio_path"
        case videoSizeMB = "video_size_mb"
        case microphoneSizeMB = "mic_size_mb"
        case segmented
        case limitProfileID = "limit_profile"
        case stopReason = "stop_reason"
        case segments
    }

    public init(
        durationSeconds: Int,
        videoQuality: String,
        videoPath: String,
        microphoneAudioPath: String,
        videoSizeMB: Double,
        microphoneSizeMB: Double,
        segmented: Bool = false,
        limitProfileID: String? = nil,
        stopReason: RecordingStopReason? = nil,
        segments: [RecordingSegment] = []
    ) {
        self.durationSeconds = durationSeconds
        self.videoQuality = videoQuality
        self.videoPath = videoPath
        self.microphoneAudioPath = microphoneAudioPath
        self.videoSizeMB = videoSizeMB
        self.microphoneSizeMB = microphoneSizeMB
        self.segmented = segmented
        self.limitProfileID = limitProfileID
        self.stopReason = stopReason
        self.segments = segments.sorted { $0.index < $1.index }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        durationSeconds = try container.decodeIfPresent(Int.self, forKey: .durationSeconds) ?? 0
        videoQuality = try container.decodeIfPresent(String.self, forKey: .videoQuality) ?? ""
        videoPath = try container.decodeIfPresent(String.self, forKey: .videoPath) ?? ""
        microphoneAudioPath = try container.decodeIfPresent(String.self, forKey: .microphoneAudioPath) ?? ""
        videoSizeMB = try container.decodeIfPresent(Double.self, forKey: .videoSizeMB) ?? 0
        microphoneSizeMB = try container.decodeIfPresent(Double.self, forKey: .microphoneSizeMB) ?? 0
        segmented = try container.decodeIfPresent(Bool.self, forKey: .segmented) ?? false
        limitProfileID = try container.decodeIfPresent(String.self, forKey: .limitProfileID)
        stopReason = try container.decodeIfPresent(RecordingStopReason.self, forKey: .stopReason)
        segments = try container.decodeIfPresent([RecordingSegment].self, forKey: .segments)?.sorted { $0.index < $1.index } ?? []
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
    public var id: String
    public var agentID: String
    public var agentName: String
    public var model: String
    public var modelVersion: String?
    public var providerID: String?
    public var promptSnapshot: String?
    public var createdAt: String
    public var processingDurationSeconds: Int
    public var tokens: ReportTokens
    public var outputPath: String
    public var status: String
    public var error: String?

    enum CodingKeys: String, CodingKey {
        case id
        case agentID = "agent_id"
        case agentName = "agent_name"
        case model
        case modelVersion = "model_version"
        case providerID = "provider_id"
        case promptSnapshot = "prompt_snapshot"
        case createdAt = "created_at"
        case processingDurationSeconds = "processing_duration_seconds"
        case tokens
        case outputPath = "output_path"
        case status
        case error
    }

    public init(
        id: String = UUID().uuidString,
        agentID: String,
        agentName: String,
        model: String,
        modelVersion: String? = nil,
        providerID: String? = nil,
        promptSnapshot: String? = nil,
        createdAt: String,
        processingDurationSeconds: Int,
        tokens: ReportTokens,
        outputPath: String,
        status: String,
        error: String? = nil
    ) {
        self.id = id
        self.agentID = agentID
        self.agentName = agentName
        self.model = model
        self.modelVersion = modelVersion
        self.providerID = providerID
        self.promptSnapshot = promptSnapshot
        self.createdAt = createdAt
        self.processingDurationSeconds = processingDurationSeconds
        self.tokens = tokens
        self.outputPath = outputPath
        self.status = status
        self.error = error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agentID = try container.decode(String.self, forKey: .agentID)
        agentName = try container.decodeIfPresent(String.self, forKey: .agentName) ?? agentID
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? AIModelCatalog.defaultModelID(for: .gemini)
        modelVersion = try container.decodeIfPresent(String.self, forKey: .modelVersion)
        providerID = try container.decodeIfPresent(String.self, forKey: .providerID)
        promptSnapshot = try container.decodeIfPresent(String.self, forKey: .promptSnapshot)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        processingDurationSeconds = try container.decodeIfPresent(Int.self, forKey: .processingDurationSeconds) ?? 0
        tokens = try container.decodeIfPresent(ReportTokens.self, forKey: .tokens) ?? ReportTokens(input: 0, output: 0, total: 0)
        outputPath = try container.decodeIfPresent(String.self, forKey: .outputPath) ?? ""
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
        error = try container.decodeIfPresent(String.self, forKey: .error)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? Self.legacyID(
            agentID: agentID,
            createdAt: createdAt,
            outputPath: outputPath
        )
    }

    private static func legacyID(agentID: String, createdAt: String, outputPath: String) -> String {
        let value = "\(agentID)|\(createdAt)|\(outputPath)"
        let hash = value.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { partial, byte in
            (partial ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return "legacy-\(String(hash, radix: 16))"
    }
}

public struct SessionMetadata: Codable, Hashable, Sendable {
    public var schemaVersion: Int?
    public var name: String?
    public var createdAt: String?
    public var folderID: String?
    public var source: RecordingSource?
    public var recording: RecordingInfo?
    public var reports: [ReportInfo]?
    public var remoteMedia: RemoteMediaManifest?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case name
        case createdAt = "created_at"
        case folderID = "folder_id"
        case source
        case recording
        case reports
        case remoteMedia = "remote_media"
    }

    public init(
        schemaVersion: Int? = 3,
        name: String? = nil,
        createdAt: String? = nil,
        folderID: String? = nil,
        source: RecordingSource? = nil,
        recording: RecordingInfo? = nil,
        reports: [ReportInfo]? = nil,
        remoteMedia: RemoteMediaManifest? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.name = name
        self.createdAt = createdAt
        self.folderID = folderID
        self.source = source
        self.recording = recording
        self.reports = reports
        self.remoteMedia = remoteMedia
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
    public var reportURLsByReportID: [String: URL]
    public var metadata: SessionMetadata
    public var modifiedAt: Date

    public init(
        baseName: String,
        baseURL: URL,
        videoURL: URL,
        metadataURL: URL,
        audioURLs: [URL],
        reportURLsByAgentID: [String: URL],
        reportURLsByReportID: [String: URL] = [:],
        metadata: SessionMetadata,
        modifiedAt: Date
    ) {
        self.baseName = baseName
        self.baseURL = baseURL
        self.videoURL = videoURL
        self.metadataURL = metadataURL
        self.audioURLs = audioURLs
        self.reportURLsByAgentID = reportURLsByAgentID
        self.reportURLsByReportID = reportURLsByReportID
        self.metadata = metadata
        self.modifiedAt = modifiedAt
    }
}

public extension MeetingSession {
    var recordingSegments: [RecordingSegment] {
        if let segments = metadata.recording?.segments, !segments.isEmpty {
            return segments.sorted { $0.index < $1.index }
        }
        let videoSize = (try? videoURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let micURL = audioURLs.first
        let micSize = micURL.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.map(Int64.init) ?? 0
        return [RecordingSegment(
            index: 0,
            startSeconds: 0,
            durationSeconds: Double(metadata.recording?.durationSeconds ?? 0),
            videoPath: videoURL.lastPathComponent,
            microphoneAudioPath: micURL?.lastPathComponent,
            videoSizeBytes: videoSize,
            microphoneSizeBytes: micSize
        )]
    }

    var isSegmentedRecording: Bool { metadata.recording?.segmented == true && recordingSegments.count > 0 }

    var segmentedLimitProfile: SegmentedRecordingLimitProfile? {
        metadata.recording?.limitProfileID.flatMap(SegmentedRecordingLimitProfile.init(rawValue:))
    }

    var segmentVideoURLs: [URL] {
        recordingSegments.map { baseURL.deletingLastPathComponent().appending(path: $0.videoPath) }
    }

    var segmentMicrophoneURLs: [URL] {
        recordingSegments.compactMap { segment in
            segment.microphoneAudioPath.map { baseURL.deletingLastPathComponent().appending(path: $0) }
        }
    }

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
        let mediaURLs = isSegmentedRecording ? segmentVideoURLs + segmentMicrophoneURLs : [videoURL] + audioURLs
        let urls = mediaURLs + [metadataURL] + Array(reportURLsByAgentID.values)
        let totalBytes = urls.reduce(Int64(0)) { result, url in
            let value = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            return result + value
        }
        return Double(totalBytes) / 1_048_576.0
    }

    var sortedReportAgentIDs: [String] {
        reportURLsByAgentID.keys.sorted()
    }

    var availableReports: [ReportInfo] {
        (metadata.reports ?? [])
            .filter { reportURLsByReportID[$0.id] != nil }
            .sorted { $0.createdAt > $1.createdAt }
    }
}
