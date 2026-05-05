import Foundation

public actor OpenAICompatibleClient {
    private let urlSession: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(urlSession: URLSession = AIURLSessionFactory.makeLongRunningSession()) {
        self.urlSession = urlSession
    }

    /// Sends a minimal chat completion to an OpenAI-compatible provider.
    public func validateConfiguration(config: AppConfig, model: AIModelReference) async throws -> String {
        let body = OpenAIChatRequest(
            model: model.modelID,
            messages: [
                OpenAIMessage(role: "system", content: .text("Health check")),
                OpenAIMessage(role: "user", content: .text("Ответь одним словом: ok"))
            ],
            temperature: 0
        )
        let response = try await sendChatRequest(
            body: body,
            config: config,
            model: model,
            context: "health check",
            options: AIHTTPRequestOptions(
                phase: .checkingConnection(provider: model.providerID.displayName),
                timeout: AIHTTPTimeouts.healthCheck
            )
        )
        return response.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sends the meeting video as a base64 `video_url` content part.
    public func generateReport(
        videoURL: URL,
        config: AppConfig,
        model: AIModelReference,
        agent: Agent,
        progress: AIProgressHandler? = nil
    ) async throws -> AIProcessingResult {
        let start = Date()
        await progress?(.preparingMedia(provider: model.providerID.displayName))
        try AIMediaLimits.validateSingleRequestVideo(
            url: videoURL,
            provider: model.providerID,
            limitBytes: AIMediaLimits.openAICompatibleSingleRequestVideoBytes
        )
        await progress?(
            .uploadingMedia(
                provider: model.providerID.displayName,
                fileName: videoURL.lastPathComponent,
                fileIndex: 1,
                totalFiles: 1,
                sizeBytes: (try? videoURL.fileSizeBytes()) ?? 0
            )
        )
        let videoDataURL = try videoURL.dataURL
        let prompt = AIPromptBuilder.meetingAnalysisPrompt(videoURL: videoURL)
        let systemPrompt = PromptSecurity.systemPrompt(for: agent)
        let body = OpenAIChatRequest(
            model: model.modelID,
            messages: [
                OpenAIMessage(role: "system", content: .text(systemPrompt)),
                OpenAIMessage(
                    role: "user",
                    content: .parts([
                        OpenAIContentPart(type: "video_url", text: nil, videoURL: OpenAIMediaURL(url: videoDataURL)),
                        OpenAIContentPart(type: "text", text: prompt, videoURL: nil)
                    ])
                )
            ],
            temperature: 0.2
        )

        await progress?(.generatingReport(provider: model.providerID.displayName))
        let response = try await sendChatRequest(
            body: body,
            config: config,
            model: model,
            context: "generate report",
            options: AIHTTPRequestOptions(
                phase: .generatingReport(provider: model.providerID.displayName),
                timeout: AIHTTPTimeouts.generation
            )
        )
        let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw AIClientError.emptyResponse
        }

        let usage = response.usage
        return AIProcessingResult(
            text: text,
            metadata: AIProcessingMetadata(
                durationSeconds: Int(Date().timeIntervalSince(start)),
                tokensInput: usage?.promptTokens ?? 0,
                tokensOutput: usage?.completionTokens ?? 0,
                tokensTotal: usage?.totalTokens ?? 0,
                model: model.displayName,
                agentName: agent.name,
                outputFileName: "",
                createdAt: ISO8601DateFormatter().string(from: Date())
            )
        )
    }

    /// Reads `/models` from providers that expose OpenAI-compatible model discovery.
    public func listModelIDs(baseURL: String, apiKey: String) async throws -> [String] {
        let url = try endpoint(baseURL: baseURL, path: "models")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await AIHTTPClient.data(
            for: request,
            session: urlSession,
            phase: .generatingReport(provider: "OpenAI-compatible"),
            timeout: AIHTTPTimeouts.modelCatalog
        )
        try validate(response, data: data, provider: "OpenAI-compatible", context: "GET \(sanitizedEndpoint(url))")
        let models = try decoder.decode(OpenAIModelsResponse.self, from: data)
        return models.data.map(\.id)
    }

    private func sendChatRequest(
        body: OpenAIChatRequest,
        config: AppConfig,
        model: AIModelReference,
        context: String,
        options: AIHTTPRequestOptions
    ) async throws -> OpenAIChatResponse {
        let url = try endpoint(baseURL: config.baseURL(for: model.providerID), path: "chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey(config: config, providerID: model.providerID))", forHTTPHeaderField: "Authorization")
        if model.providerID == .openRouter {
            request.setValue("Steno", forHTTPHeaderField: "X-Title")
        }

        let (data, response) = try await AIHTTPClient.data(
            for: request,
            body: try encoder.encode(body),
            session: urlSession,
            phase: options.phase,
            timeout: options.timeout
        )
        try validate(response, data: data, provider: model.providerID.displayName, context: "POST \(sanitizedEndpoint(url)) \(context)")
        return try decoder.decode(OpenAIChatResponse.self, from: data)
    }

    private func apiKey(config: AppConfig, providerID: AIProviderID) -> String {
        config.apiKey(for: providerID).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func endpoint(baseURL: String, path: String) throws -> URL {
        let normalizedBase = normalizedAPIBase(baseURL)
        guard let url = URL(string: "\(normalizedBase)/\(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))") else {
            throw AIClientError.invalidURL(baseURL)
        }
        return url
    }

    private func normalizedAPIBase(_ baseURL: String) -> String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") ? trimmed : "https://\(trimmed)"
        return withScheme.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func validate(_ response: URLResponse, data: Data, provider: String, context: String) throws {
        guard let http = response as? HTTPURLResponse else {
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AIClientError.apiError(provider: provider, status: http.statusCode, message: httpErrorMessage(statusCode: http.statusCode, data: data), context: context)
        }
    }

    private func sanitizedEndpoint(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = nil
        return components?.url?.absoluteString ?? url.absoluteString
    }

    private func httpErrorMessage(statusCode: Int, data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String
            let code = error["code"] as? String
            return [code, message]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " - ")
        }

        let rawMessage = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return rawMessage.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: statusCode) : String(rawMessage.prefix(800))
    }
}

private struct OpenAIChatRequest: Encodable {
    var model: String
    var messages: [OpenAIMessage]
    var temperature: Double
}

private struct OpenAIMessage: Encodable {
    var role: String
    var content: OpenAIMessageContent
}

private enum OpenAIMessageContent: Encodable {
    case text(String)
    case parts([OpenAIContentPart])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .text(text):
            try container.encode(text)
        case let .parts(parts):
            try container.encode(parts)
        }
    }
}

private struct OpenAIContentPart: Encodable {
    var type: String
    var text: String?
    var videoURL: OpenAIMediaURL?

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case videoURL = "video_url"
    }
}

private struct OpenAIMediaURL: Encodable {
    var url: String
}

private struct OpenAIChatResponse: Decodable {
    var choices: [OpenAIChoice]
    var usage: OpenAIUsage?

    var text: String {
        choices.first?.message.content ?? ""
    }
}

private struct OpenAIChoice: Decodable {
    var message: OpenAIResponseMessage
}

private struct OpenAIResponseMessage: Decodable {
    var content: String?
}

private struct OpenAIUsage: Decodable {
    var promptTokens: Int?
    var completionTokens: Int?
    var totalTokens: Int?

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }
}

private struct OpenAIModelsResponse: Decodable {
    var data: [OpenAIModel]
}

private struct OpenAIModel: Decodable {
    var id: String
}

private extension URL {
    var dataURL: String {
        get throws {
            let data = try Data(contentsOf: self)
            return "data:\(mimeType);base64,\(data.base64EncodedString())"
        }
    }

    var mimeType: String {
        switch pathExtension.lowercased() {
        case "mp4":
            "video/mp4"
        case "mov":
            "video/quicktime"
        case "mpeg", "mpg":
            "video/mpeg"
        case "webm":
            "video/webm"
        case "avi":
            "video/x-msvideo"
        default:
            "video/mp4"
        }
    }
}
