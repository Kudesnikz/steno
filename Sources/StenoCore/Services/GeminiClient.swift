import Foundation

public struct AIProcessingMetadata: Hashable, Sendable {
    public var durationSeconds: Int
    public var tokensInput: Int
    public var tokensOutput: Int
    public var tokensTotal: Int
    public var model: String
    public var agentName: String
    public var outputFileName: String
    public var createdAt: String

    public init(
        durationSeconds: Int,
        tokensInput: Int,
        tokensOutput: Int,
        tokensTotal: Int,
        model: String,
        agentName: String,
        outputFileName: String,
        createdAt: String
    ) {
        self.durationSeconds = durationSeconds
        self.tokensInput = tokensInput
        self.tokensOutput = tokensOutput
        self.tokensTotal = tokensTotal
        self.model = model
        self.agentName = agentName
        self.outputFileName = outputFileName
        self.createdAt = createdAt
    }
}

public struct AIProcessingResult: Hashable, Sendable {
    public var text: String
    public var metadata: AIProcessingMetadata

    public init(text: String, metadata: AIProcessingMetadata) {
        self.text = text
        self.metadata = metadata
    }
}

public struct GeminiConnectionCheckResult: Hashable, Sendable {
    public var baseURL: String
    public var modelName: String

    public init(baseURL: String, modelName: String) {
        self.baseURL = baseURL
        self.modelName = modelName
    }
}

public enum GeminiClientError: LocalizedError, Sendable {
    case missingAPIKey
    case invalidURL(String)
    case uploadURLMissing
    case emptyResponse
    case fileProcessingFailed(String)
    case apiError(status: Int, message: String, context: String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Нет API ключа. Настройте ключ в Settings."
        case let .invalidURL(value):
            "Invalid Gemini URL: \(value)"
        case .uploadURLMissing:
            "Gemini upload session URL is missing."
        case .emptyResponse:
            "AI вернул пустой ответ."
        case let .fileProcessingFailed(name):
            "Google failed to process file \(name)."
        case let .apiError(status, message, context):
            "Gemini API error \(status) at \(context): \(message)"
        }
    }
}

public actor GeminiClient {
    private let urlSession: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(urlSession: URLSession = AIURLSessionFactory.makeLongRunningSession()) {
        self.urlSession = urlSession
    }

    public func validateConfiguration(config: AppConfig) async throws -> GeminiConnectionCheckResult {
        let apiKey = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            AppLog.warning("AI connection check requested without API key", category: .ai)
            throw GeminiClientError.missingAPIKey
        }

        let normalizedBase = normalizedAPIBase(config.baseURL)
        let url = try apiEndpoint(path: "v1beta/models/\(config.modelName):generateContent", baseURL: normalizedBase, apiKey: apiKey)
        let body = GenerateContentRequest(
            contents: [Content(role: "user", parts: [ContentPart(fileData: nil, text: "Ответь одним словом: ok")])],
            systemInstruction: Content(role: nil, parts: [ContentPart(fileData: nil, text: "Health check")])
        )
        AppLog.info("Checking Gemini generate endpoint baseURL=\(normalizedBase) model=\(config.modelName)", category: .ai)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await AIHTTPClient.data(
            for: request,
            body: try encoder.encode(body),
            session: urlSession,
            phase: .checkingConnection(provider: AIProviderID.gemini.displayName),
            timeout: AIHTTPTimeouts.healthCheck
        )
        try validate(response, data: data, context: "POST \(sanitizedEndpoint(url))")
        return GeminiConnectionCheckResult(baseURL: normalizedBase, modelName: config.modelName)
    }

    public func generateReport(
        videoURL: URL,
        audioURLs: [URL],
        transcript: AITranscriptContext?,
        config: AppConfig,
        agent: Agent,
        progress: AIProgressHandler? = nil
    ) async throws -> AIProcessingResult {
        guard !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            AppLog.warning("AI generation requested without API key", category: .ai)
            throw GeminiClientError.missingAPIKey
        }

        AppLog.info(
            "AI generation started model=\(config.modelName) baseURL=\(normalizedAPIBase(config.baseURL)) agent=\(agent.id) attachments=\(1 + audioURLs.count)",
            category: .ai
        )
        let start = Date()
        let files = [videoURL] + audioURLs
        var uploadedFiles: [GeminiFile] = []

        do {
            await progress?(.preparingMedia(provider: AIProviderID.gemini.displayName))
            let existingFiles = files.filter { FileManager.default.fileExists(atPath: $0.path) }
            for (index, fileURL) in existingFiles.enumerated() {
                try Task.checkCancellation()
                await progress?(
                    .uploadingMedia(
                        provider: AIProviderID.gemini.displayName,
                        fileName: fileURL.lastPathComponent,
                        fileIndex: index + 1,
                        totalFiles: existingFiles.count,
                        sizeBytes: (try? fileURL.fileSizeBytes()) ?? 0
                    )
                )
                AppLog.info("Uploading media file \(fileURL.lastPathComponent)", category: .ai)
                let file = try await upload(fileURL: fileURL, apiKey: config.apiKey, baseURL: config.baseURL)
                uploadedFiles.append(file)
            }

            var readyFiles: [GeminiFile] = []
            for file in uploadedFiles {
                readyFiles.append(
                    try await waitUntilReady(
                        file: file,
                        apiKey: config.apiKey,
                        baseURL: config.baseURL,
                        progress: progress
                    )
                )
            }

            await progress?(.generatingReport(provider: AIProviderID.gemini.displayName))
            let response = try await generateContent(
                files: readyFiles,
                videoURL: videoURL,
                transcript: transcript,
                config: config,
                agent: agent
            )
            guard let text = response.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                AppLog.error("AI generation returned empty response", category: .ai)
                throw GeminiClientError.emptyResponse
            }

            let usage = response.usageMetadata
            let createdAt = ISO8601DateFormatter().string(from: Date())
            let metadata = AIProcessingMetadata(
                durationSeconds: Int(Date().timeIntervalSince(start)),
                tokensInput: usage?.promptTokenCount ?? 0,
                tokensOutput: usage?.candidatesTokenCount ?? 0,
                tokensTotal: usage?.totalTokenCount ?? 0,
                model: config.modelName,
                agentName: agent.name,
                outputFileName: "",
                createdAt: createdAt
            )

            AppLog.info("AI generation finished tokens=\(metadata.tokensTotal) duration=\(metadata.durationSeconds)s", category: .ai)
            return AIProcessingResult(text: text, metadata: metadata)
        } catch {
            let safeMessage = error.localizedDescription.replacingOccurrences(of: config.apiKey, with: "***MASKED***")
            AppLog.error("AI generation failed: \(safeMessage)", category: .ai)
            for file in uploadedFiles {
                try? await delete(file: file, apiKey: config.apiKey, baseURL: config.baseURL)
            }
            throw error
        }
    }

    private func upload(fileURL: URL, apiKey: String, baseURL: String) async throws -> GeminiFile {
        let data = try Data(contentsOf: fileURL)
        let mimeType = fileURL.mimeType
        let startURL = try uploadEndpoint(path: "v1beta/files", baseURL: baseURL, apiKey: apiKey)

        var startRequest = URLRequest(url: startURL)
        startRequest.httpMethod = "POST"
        startRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        startRequest.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        startRequest.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        startRequest.setValue("\(data.count)", forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        startRequest.setValue(mimeType, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")

        let startBody = try encoder.encode(StartUploadRequest(file: StartUploadFile(displayName: fileURL.lastPathComponent)))
        let uploadPhase = AIProcessingPhase.uploadingMedia(
            provider: AIProviderID.gemini.displayName,
            fileName: fileURL.lastPathComponent,
            fileIndex: 1,
            totalFiles: 1,
            sizeBytes: Int64(data.count)
        )
        let (startData, startResponse) = try await withTransientRetry(operation: "Gemini upload start") {
            try await AIHTTPClient.data(
                for: startRequest,
                body: startBody,
                session: urlSession,
                phase: uploadPhase,
                timeout: AIHTTPTimeouts.uploadStart
            )
        }
        try validate(startResponse, data: startData, context: "POST \(sanitizedEndpoint(startURL))")
        guard let http = startResponse as? HTTPURLResponse,
              let uploadURLString = http.value(forHTTPHeaderField: "X-Goog-Upload-URL"),
              let uploadURL = URL(string: uploadURLString) else {
            throw GeminiClientError.uploadURLMissing
        }

        var uploadRequest = URLRequest(url: uploadURL)
        uploadRequest.httpMethod = "POST"
        uploadRequest.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")
        uploadRequest.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        uploadRequest.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")

        let (responseData, response) = try await withTransientRetry(operation: "Gemini media upload") {
            try await AIHTTPClient.data(
                for: uploadRequest,
                body: data,
                session: urlSession,
                phase: uploadPhase,
                timeout: AIHTTPTimeouts.mediaUpload
            )
        }
        try validate(response, data: responseData, context: "POST resumable upload session")
        return try decoder.decode(FileUploadResponse.self, from: responseData).file
    }

    private func waitUntilReady(
        file: GeminiFile,
        apiKey: String,
        baseURL: String,
        progress: AIProgressHandler?
    ) async throws -> GeminiFile {
        var current = file
        let startedAt = Date()
        var attempt = 0
        while current.state == "PROCESSING" {
            try Task.checkCancellation()
            let elapsed = Int(Date().timeIntervalSince(startedAt))
            guard elapsed < AIHTTPTimeouts.providerFileProcessing else {
                throw AIProcessingFailure.providerFileProcessingTimedOut(
                    provider: AIProviderID.gemini.displayName,
                    fileName: current.name,
                    timeoutSeconds: AIHTTPTimeouts.providerFileProcessing
                )
            }
            await progress?(
                .waitingForProviderProcessing(
                    provider: AIProviderID.gemini.displayName,
                    fileName: current.name,
                    elapsedSeconds: elapsed,
                    maxSeconds: AIHTTPTimeouts.providerFileProcessing
                )
            )
            AppLog.debug("Waiting for Gemini file processing: \(current.name)", category: .ai)
            let delay = min(10, 3 + attempt * 2)
            attempt += 1
            try await Task.sleep(for: .seconds(delay))
            current = try await get(file: current, apiKey: apiKey, baseURL: baseURL)
        }

        if current.state == "FAILED" {
            AppLog.error("Gemini file processing failed: \(current.name)", category: .ai)
            throw GeminiClientError.fileProcessingFailed(current.name)
        }
        return current
    }

    private func get(file: GeminiFile, apiKey: String, baseURL: String) async throws -> GeminiFile {
        let url = try fileResourceEndpoint(name: file.name, baseURL: baseURL, apiKey: apiKey)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await withTransientRetry(operation: "Gemini file polling") {
            try await AIHTTPClient.data(
                for: request,
                session: urlSession,
                phase: .waitingForProviderProcessing(
                    provider: AIProviderID.gemini.displayName,
                    fileName: file.name,
                    elapsedSeconds: 0,
                    maxSeconds: AIHTTPTimeouts.providerFileProcessing
                ),
                timeout: AIHTTPTimeouts.polling
            )
        }
        try validate(response, data: data, context: "GET \(sanitizedEndpoint(url))")
        return try decoder.decode(GeminiFile.self, from: data)
    }

    private func delete(file: GeminiFile, apiKey: String, baseURL: String) async throws {
        let url = try fileResourceEndpoint(name: file.name, baseURL: baseURL, apiKey: apiKey)
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        let (data, response) = try await AIHTTPClient.data(
            for: request,
            session: urlSession,
            phase: .waitingForProviderProcessing(
                provider: AIProviderID.gemini.displayName,
                fileName: file.name,
                elapsedSeconds: 0,
                maxSeconds: AIHTTPTimeouts.providerFileProcessing
            ),
            timeout: AIHTTPTimeouts.polling
        )
        try validate(response, data: data, context: "DELETE \(sanitizedEndpoint(url))")
    }

    private func generateContent(
        files: [GeminiFile],
        videoURL: URL,
        transcript: AITranscriptContext?,
        config: AppConfig,
        agent: Agent
    ) async throws -> GenerateContentResponse {
        let url = try apiEndpoint(path: "v1beta/models/\(config.modelName):generateContent", baseURL: config.baseURL, apiKey: config.apiKey)
        let prompt = AIPromptBuilder.meetingAnalysisPrompt(videoURL: videoURL, transcript: transcript)

        let parts = files.map {
            ContentPart(fileData: FileData(mimeType: $0.mimeType, fileURI: $0.uri), text: nil)
        } + [
            ContentPart(fileData: nil, text: prompt)
        ]

        let body = GenerateContentRequest(
            contents: [Content(role: "user", parts: parts)],
            systemInstruction: Content(
                role: nil,
                parts: [ContentPart(fileData: nil, text: PromptSecurity.systemPrompt(for: agent))]
            )
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let bodyData = try encoder.encode(body)

        var lastError: Error?
        for attempt in 0..<3 {
            do {
                let (data, response) = try await AIHTTPClient.data(
                    for: request,
                    body: bodyData,
                    session: urlSession,
                    phase: .generatingReport(provider: AIProviderID.gemini.displayName),
                    timeout: AIHTTPTimeouts.generation
                )
                try validate(response, data: data, context: "POST \(sanitizedEndpoint(url))")
                return try decoder.decode(GenerateContentResponse.self, from: data)
            } catch {
                lastError = error
                if error.isRateLimitLike, attempt < 2 {
                    let delay = UInt64(5 * (1 << attempt))
                    AppLog.warning("Gemini rate limit; retrying in \(delay)s", category: .ai)
                    try await Task.sleep(for: .seconds(delay))
                } else {
                    throw error
                }
            }
        }
        throw lastError ?? GeminiClientError.emptyResponse
    }

    private func validate(_ response: URLResponse, data: Data, context: String) throws {
        guard let http = response as? HTTPURLResponse else {
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = httpErrorMessage(statusCode: http.statusCode, data: data)
            throw GeminiClientError.apiError(status: http.statusCode, message: message, context: context)
        }
    }

    private func withTransientRetry<T>(
        operation: String,
        maxAttempts: Int = 3,
        body: () async throws -> T
    ) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await body()
            } catch {
                attempt += 1
                guard attempt < maxAttempts, error.isRetryableTransportOrProviderFailure else {
                    throw error
                }
                let delay = UInt64(min(30, 3 * (1 << (attempt - 1))))
                AppLog.warning("\(operation) failed transiently; retrying in \(delay)s", category: .ai)
                try await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private func apiEndpoint(path: String, baseURL: String, apiKey: String) throws -> URL {
        let normalizedBase = normalizedAPIBase(baseURL)
        guard var components = URLComponents(string: "\(normalizedBase)/\(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))") else {
            throw GeminiClientError.invalidURL(baseURL)
        }
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else {
            throw GeminiClientError.invalidURL(baseURL)
        }
        return url
    }

    private func uploadEndpoint(path: String, baseURL: String, apiKey: String) throws -> URL {
        let normalizedBase = normalizedAPIBase(baseURL)
        let uploadBase: String
        if normalizedBase.contains("/upload") {
            uploadBase = normalizedBase
        } else {
            uploadBase = "\(normalizedBase)/upload"
        }

        guard var components = URLComponents(string: "\(uploadBase)/\(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))") else {
            throw GeminiClientError.invalidURL(baseURL)
        }
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else {
            throw GeminiClientError.invalidURL(baseURL)
        }
        return url
    }

    private func normalizedAPIBase(_ baseURL: String) -> String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? "https://generativelanguage.googleapis.com" : trimmed
        let withScheme = value.hasPrefix("http://") || value.hasPrefix("https://") ? value : "https://\(value)"
        return withScheme.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func sanitizedEndpoint(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = nil
        return components?.url?.absoluteString ?? url.deletingQuery().absoluteString
    }

    private func httpErrorMessage(statusCode: Int, data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? [String: Any] {
            let status = error["status"] as? String
            let message = error["message"] as? String
            return [status, message]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " - ")
        }

        let rawMessage = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if rawMessage.isEmpty {
            return HTTPURLResponse.localizedString(forStatusCode: statusCode)
        }
        return String(rawMessage.prefix(800))
    }

    private func fileResourceEndpoint(name: String, baseURL: String, apiKey: String) throws -> URL {
        let trimmedName = name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path: String
        if trimmedName.hasPrefix("v1/") || trimmedName.hasPrefix("v1beta/") {
            path = trimmedName
        } else {
            path = "v1beta/\(trimmedName)"
        }
        return try apiEndpoint(path: path, baseURL: baseURL, apiKey: apiKey)
    }
}

private extension URL {
    func deletingQuery() -> URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return self
        }
        components.queryItems = nil
        return components.url ?? self
    }
}

private struct StartUploadRequest: Codable {
    var file: StartUploadFile
}

private struct StartUploadFile: Codable {
    var displayName: String

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
    }
}

private struct FileUploadResponse: Codable {
    var file: GeminiFile
}

private struct GeminiFile: Codable, Hashable, Sendable {
    var name: String
    var uri: String
    var mimeType: String
    var state: String?

    enum CodingKeys: String, CodingKey {
        case name
        case uri
        case mimeType
        case state
    }
}

private struct GenerateContentRequest: Codable {
    var contents: [Content]
    var systemInstruction: Content
}

private struct Content: Codable {
    var role: String?
    var parts: [ContentPart]
}

private struct ContentPart: Codable {
    var fileData: FileData?
    var text: String?
}

private struct FileData: Codable {
    var mimeType: String
    var fileURI: String

    enum CodingKeys: String, CodingKey {
        case mimeType
        case fileURI = "fileUri"
    }
}

private struct GenerateContentResponse: Codable {
    var candidates: [Candidate]?
    var usageMetadata: UsageMetadata?

    var text: String? {
        candidates?.first?.content.parts.compactMap(\.text).joined(separator: "\n")
    }
}

private struct Candidate: Codable {
    var content: Content
}

private struct UsageMetadata: Codable {
    var promptTokenCount: Int?
    var candidatesTokenCount: Int?
    var totalTokenCount: Int?
}

private extension URL {
    var mimeType: String {
        switch pathExtension.lowercased() {
        case "mp4":
            "video/mp4"
        case "m4a":
            "audio/mp4"
        case "mp3":
            "audio/mpeg"
        case "wav":
            "audio/wav"
        default:
            "application/octet-stream"
        }
    }
}

private extension Error {
    var isRateLimitLike: Bool {
        let message = localizedDescription
        return message.contains("429") || message.contains("RESOURCE_EXHAUSTED") || message.localizedCaseInsensitiveContains("quota")
    }

    var isRetryableTransportOrProviderFailure: Bool {
        if let failure = self as? AIProcessingFailure,
           case .requestTimedOut = failure {
            return true
        }
        if let geminiError = self as? GeminiClientError,
           case let .apiError(status, _, _) = geminiError {
            return status == 429 || [500, 502, 503, 504].contains(status)
        }
        let message = localizedDescription
        return message.localizedCaseInsensitiveContains("network connection was lost") ||
            message.localizedCaseInsensitiveContains("could not connect to the server")
    }
}
