import Foundation

public struct RecordingFolder: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var createdAt: Date

    public init(id: String = UUID().uuidString, name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

public enum RecordingSource: String, Codable, Hashable, Sendable {
    case captured
    case imported
    case legacy
}

public struct RemoteMediaPart: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var index: Int
    public var startSeconds: Double
    public var durationSeconds: Double
    public var resourceName: String
    public var uri: String
    public var mimeType: String
    public var sizeBytes: Int64
    public var state: String
    public var createdAt: Date
    public var expiresAt: Date
    /// Stable local attachment identity used to reuse unchanged files independently.
    public var attachmentID: String?
    /// `video_system_audio` or `microphone_audio` for segmented recordings.
    public var role: String?
    public var segmentIndex: Int?
    public var sourceFingerprint: String?

    public init(
        id: String = UUID().uuidString,
        index: Int,
        startSeconds: Double,
        durationSeconds: Double,
        resourceName: String,
        uri: String,
        mimeType: String,
        sizeBytes: Int64,
        state: String = "ACTIVE",
        createdAt: Date = Date(),
        expiresAt: Date,
        attachmentID: String? = nil,
        role: String? = nil,
        segmentIndex: Int? = nil,
        sourceFingerprint: String? = nil
    ) {
        self.id = id
        self.index = index
        self.startSeconds = startSeconds
        self.durationSeconds = durationSeconds
        self.resourceName = resourceName
        self.uri = uri
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.state = state
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.attachmentID = attachmentID
        self.role = role
        self.segmentIndex = segmentIndex
        self.sourceFingerprint = sourceFingerprint
    }
}

public struct RemoteUploadSession: Codable, Hashable, Sendable {
    public var attachmentID: String
    public var sourceFingerprint: String
    public var uploadURL: String
    public var uploadedBytes: Int64
    public var totalBytes: Int64
    public var updatedAt: Date

    public init(
        attachmentID: String,
        sourceFingerprint: String,
        uploadURL: String,
        uploadedBytes: Int64,
        totalBytes: Int64,
        updatedAt: Date = Date()
    ) {
        self.attachmentID = attachmentID
        self.sourceFingerprint = sourceFingerprint
        self.uploadURL = uploadURL
        self.uploadedBytes = uploadedBytes
        self.totalBytes = totalBytes
        self.updatedAt = updatedAt
    }
}

public struct RemoteMediaManifest: Codable, Hashable, Sendable {
    public var sourceFingerprint: String
    public var credentialFingerprint: String
    public var baseURLFingerprint: String
    public var parts: [RemoteMediaPart]
    /// The number of parts that must exist before this manifest can be reused.
    /// `nil` is reserved for manifests written by builds predating resumable manifests.
    public var expectedPartCount: Int?
    /// In-progress resumable sessions. Optional for schema compatibility.
    public var pendingUploads: [RemoteUploadSession]?
    public var updatedAt: Date

    public init(
        sourceFingerprint: String,
        credentialFingerprint: String,
        baseURLFingerprint: String,
        parts: [RemoteMediaPart],
        expectedPartCount: Int? = nil,
        pendingUploads: [RemoteUploadSession]? = nil,
        updatedAt: Date = Date()
    ) {
        self.sourceFingerprint = sourceFingerprint
        self.credentialFingerprint = credentialFingerprint
        self.baseURLFingerprint = baseURLFingerprint
        self.parts = parts.sorted { $0.index < $1.index }
        self.expectedPartCount = expectedPartCount
        self.pendingUploads = pendingUploads
        self.updatedAt = updatedAt
    }

    public var isComplete: Bool {
        !parts.isEmpty &&
            (expectedPartCount == nil || parts.count == expectedPartCount) &&
            pendingUploads?.isEmpty != false
    }

    public var isReadyForUse: Bool {
        isComplete && parts.allSatisfy { $0.state.uppercased() == "ACTIVE" }
    }

    public func isReusable(
        sourceFingerprint: String,
        credentialFingerprint: String,
        baseURLFingerprint: String,
        now: Date = Date(),
        safetyMargin: TimeInterval = 300
    ) -> Bool {
        self.sourceFingerprint == sourceFingerprint &&
            self.credentialFingerprint == credentialFingerprint &&
            self.baseURLFingerprint == baseURLFingerprint &&
            isReadyForUse &&
            parts.allSatisfy {
                $0.expiresAt.timeIntervalSince(now) > safetyMargin
            }
    }

    public var earliestExpiration: Date? {
        parts.map(\.expiresAt).min()
    }

    public func reusablePart(
        attachmentID: String,
        sourceFingerprint: String,
        position: Int,
        aggregateSourceFingerprint: String,
        now: Date = Date(),
        safetyMargin: TimeInterval = 300
    ) -> RemoteMediaPart? {
        matchingPart(
            attachmentID: attachmentID,
            sourceFingerprint: sourceFingerprint,
            position: position,
            aggregateSourceFingerprint: aggregateSourceFingerprint,
            now: now,
            safetyMargin: safetyMargin
        ).flatMap { $0.state.uppercased() == "ACTIVE" ? $0 : nil }
    }

    public func matchingPart(
        attachmentID: String,
        sourceFingerprint: String,
        position: Int,
        aggregateSourceFingerprint: String,
        now: Date = Date(),
        safetyMargin: TimeInterval = 300
    ) -> RemoteMediaPart? {
        parts.first { part in
            let identityMatches = part.attachmentID.map { $0 == attachmentID }
                ?? (self.sourceFingerprint == aggregateSourceFingerprint && part.index == position)
            let fingerprintMatches = part.sourceFingerprint.map { $0 == sourceFingerprint } ??
                (self.sourceFingerprint == aggregateSourceFingerprint)
            return identityMatches && fingerprintMatches &&
                part.expiresAt.timeIntervalSince(now) > safetyMargin
        }
    }
}

public enum RemoteMediaAvailability: Hashable, Sendable {
    case notUploaded
    case uploading(current: Int, total: Int)
    case available(until: Date)
    case expired
    case failed(String)
}

public enum ChatRole: String, Codable, Hashable, Sendable {
    case user
    case model
}

public enum ChatMessageStatus: String, Codable, Hashable, Sendable {
    case sending
    case sent
    case failed
}

public struct ChatMessage: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var role: ChatRole
    public var text: String
    public var createdAt: Date
    public var status: ChatMessageStatus
    public var error: String?
    public var tokens: ReportTokens?

    public init(
        id: String = UUID().uuidString,
        role: ChatRole,
        text: String,
        createdAt: Date = Date(),
        status: ChatMessageStatus = .sent,
        error: String? = nil,
        tokens: ReportTokens? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.status = status
        self.error = error
        self.tokens = tokens
    }
}

public struct ChatThread: Codable, Identifiable, Hashable, Sendable {
    public var id: String { reportID }
    public var schemaVersion: Int
    public var reportID: String
    public var modelAlias: String
    public var messages: [ChatMessage]
    public var historySummary: String?
    public var summarizedMessageCount: Int?
    public var updatedAt: Date

    public init(
        schemaVersion: Int = 1,
        reportID: String,
        modelAlias: String,
        messages: [ChatMessage] = [],
        historySummary: String? = nil,
        summarizedMessageCount: Int? = nil,
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.reportID = reportID
        self.modelAlias = modelAlias
        self.messages = messages
        self.historySummary = historySummary
        self.summarizedMessageCount = summarizedMessageCount
        self.updatedAt = updatedAt
    }
}

public enum GeminiUsageKind: String, Codable, Hashable, Sendable {
    case connectionCheck
    case report
    case chat
    case retry
}

public struct GeminiUsageEvent: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var timestamp: Date
    public var model: String
    public var kind: GeminiUsageKind
    public var succeeded: Bool
    public var statusCode: Int?
    public var tokens: ReportTokens?

    public init(
        id: String = UUID().uuidString,
        timestamp: Date = Date(),
        model: String,
        kind: GeminiUsageKind,
        succeeded: Bool,
        statusCode: Int? = nil,
        tokens: ReportTokens? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.model = model
        self.kind = kind
        self.succeeded = succeeded
        self.statusCode = statusCode
        self.tokens = tokens
    }
}

public struct GeminiUsageLedger: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    public var eventsByCredential: [String: [GeminiUsageEvent]]
    public var blockedUntilByCredential: [String: Date]

    public init(
        schemaVersion: Int = 1,
        eventsByCredential: [String: [GeminiUsageEvent]] = [:],
        blockedUntilByCredential: [String: Date] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.eventsByCredential = eventsByCredential
        self.blockedUntilByCredential = blockedUntilByCredential
    }
}

public struct RecordingAudioState: Codable, Hashable, Sendable {
    public var microphoneEnabled: Bool
    public var systemAudioEnabled: Bool

    public init(microphoneEnabled: Bool = true, systemAudioEnabled: Bool = true) {
        self.microphoneEnabled = microphoneEnabled
        self.systemAudioEnabled = systemAudioEnabled
    }
}
