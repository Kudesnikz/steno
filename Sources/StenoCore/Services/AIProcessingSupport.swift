import Foundation

public typealias AIProgressHandler = @Sendable (AIProcessingPhase) async -> Void

public enum AIProcessingPhase: Hashable, Sendable {
    case checkingConnection(provider: String)
    case preparingMedia(provider: String)
    case optimizingMedia(provider: String, fileName: String)
    case uploadingMedia(provider: String, fileName: String, fileIndex: Int, totalFiles: Int, sizeBytes: Int64)
    case waitingForProviderProcessing(provider: String, fileName: String, elapsedSeconds: Int, maxSeconds: Int)
    case generatingReport(provider: String)
    case savingResult(fileName: String)

    public var status: String {
        switch self {
        case .checkingConnection:
            "checking_connection"
        case .preparingMedia:
            "preparing_media"
        case .optimizingMedia:
            "optimizing_media"
        case .uploadingMedia:
            "uploading_media"
        case .waitingForProviderProcessing:
            "provider_processing"
        case .generatingReport:
            "generating_report"
        case .savingResult:
            "saving_result"
        }
    }

    public var statusMessage: String {
        switch self {
        case let .checkingConnection(provider):
            "Checking \(provider) connection"
        case let .preparingMedia(provider):
            "Preparing media for \(provider)"
        case let .optimizingMedia(provider, fileName):
            "Optimizing \(fileName) for \(provider) upload"
        case let .uploadingMedia(_, fileName, fileIndex, totalFiles, sizeBytes):
            "Uploading \(fileIndex)/\(totalFiles): \(fileName) (\(Self.megabytes(sizeBytes)))"
        case let .waitingForProviderProcessing(provider, fileName, elapsedSeconds, maxSeconds):
            "Waiting for \(provider) to process \(fileName) (\(elapsedSeconds)s / \(maxSeconds)s)"
        case let .generatingReport(provider):
            "Generating report with \(provider)"
        case let .savingResult(fileName):
            "Saving report: \(fileName)"
        }
    }

    private static func megabytes(_ bytes: Int64) -> String {
        let value = Double(bytes) / 1_048_576.0
        return String(format: "%.1f MB", value)
    }
}

public enum AIProcessingFailure: LocalizedError, Sendable {
    case requestTimedOut(phase: AIProcessingPhase, timeoutSeconds: Int)
    case providerFileProcessingTimedOut(provider: String, fileName: String, timeoutSeconds: Int)
    case fileTooLarge(provider: String, fileName: String, sizeBytes: Int64, maxBytes: Int64, recommendation: String)

    public var errorDescription: String? {
        switch self {
        case let .requestTimedOut(phase, timeoutSeconds):
            "\(phase.statusMessage) timed out after \(timeoutSeconds)s. " +
                "The provider may still be busy, the file may be too large, or the network may be unstable."
        case let .providerFileProcessingTimedOut(provider, fileName, timeoutSeconds):
            "\(provider) did not finish processing \(fileName) within \(timeoutSeconds)s. " +
                "Try a smaller AI media file or retry later."
        case let .fileTooLarge(provider, fileName, sizeBytes, maxBytes, recommendation):
            "\(fileName) is too large for \(provider) single-request video upload " +
                "(\(Self.megabytes(sizeBytes)) > \(Self.megabytes(maxBytes))). \(recommendation)"
        }
    }

    private static func megabytes(_ bytes: Int64) -> String {
        let value = Double(bytes) / 1_048_576.0
        return String(format: "%.1f MB", value)
    }
}

public enum AIHTTPTimeouts {
    public static let healthCheck: TimeInterval = 20
    public static let modelCatalog: TimeInterval = 30
    public static let uploadStart: TimeInterval = 120
    public static let mediaUpload: TimeInterval = 1_800
    public static let polling: TimeInterval = 60
    public static let generation: TimeInterval = 1_200
    public static let resource: TimeInterval = 3_600
    public static let providerFileProcessing: Int = 1_200
}

public struct AIHTTPRequestOptions: Sendable {
    public var phase: AIProcessingPhase
    public var timeout: TimeInterval

    public init(phase: AIProcessingPhase, timeout: TimeInterval) {
        self.phase = phase
        self.timeout = timeout
    }
}

public enum AIMediaLimits {
    public static let openAICompatibleSingleRequestVideoBytes: Int64 = 250 * 1_024 * 1_024
    public static let bedrockSingleRequestVideoBytes: Int64 = 100 * 1_024 * 1_024

    public static func validateSingleRequestVideo(
        url: URL,
        provider: AIProviderID,
        limitBytes: Int64
    ) throws {
        let size = try url.fileSizeBytes()
        guard size <= limitBytes else {
            throw AIProcessingFailure.fileTooLarge(
                provider: provider.displayName,
                fileName: url.lastPathComponent,
                sizeBytes: size,
                maxBytes: limitBytes,
                recommendation: "Use Gemini file upload or lower the recording quality."
            )
        }
    }
}

public enum AIURLSessionFactory {
    public static func makeLongRunningSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = AIHTTPTimeouts.generation
        configuration.timeoutIntervalForResource = AIHTTPTimeouts.resource
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration)
    }
}

public enum AIHTTPClient {
    public static func data(
        for request: URLRequest,
        body: Data? = nil,
        session: URLSession,
        phase: AIProcessingPhase,
        timeout: TimeInterval
    ) async throws -> (Data, URLResponse) {
        var request = request
        request.timeoutInterval = timeout
        do {
            if let body {
                return try await session.upload(for: request, from: body)
            }
            return try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw AIProcessingFailure.requestTimedOut(phase: phase, timeoutSeconds: Int(timeout))
        }
    }
}

public extension URL {
    func fileSizeBytes() throws -> Int64 {
        let values = try resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }
}
