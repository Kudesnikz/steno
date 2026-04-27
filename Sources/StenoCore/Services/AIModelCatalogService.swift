import Foundation

public struct AIModelRefreshResult: Sendable {
    public var models: [AIModelReference]
    public var warnings: [String]

    public init(models: [AIModelReference], warnings: [String]) {
        self.models = models
        self.warnings = warnings
    }
}

public actor AIModelCatalogService {
    private let urlSession: URLSession
    private let decoder = JSONDecoder()
    private let openAICompatibleClient: OpenAICompatibleClient
    private let bedrockClient: BedrockClient

    public init(
        urlSession: URLSession = .shared,
        openAICompatibleClient: OpenAICompatibleClient = OpenAICompatibleClient(),
        bedrockClient: BedrockClient = BedrockClient()
    ) {
        self.urlSession = urlSession
        self.openAICompatibleClient = openAICompatibleClient
        self.bedrockClient = bedrockClient
    }

    /// Pulls provider catalogs and returns only Steno-allowed models that can accept video input.
    public func refreshAvailableModels(config: AppConfig) async -> AIModelRefreshResult {
        var warnings: [String] = []
        var modelsByProvider: [AIProviderID: [AIModelReference]] = [:]

        do {
            let models = try await fetchOpenRouterModels(baseURL: config.openRouterBaseURL)
            modelsByProvider[.openRouter] = models
        } catch {
            warnings.append("OpenRouter: \(error.localizedDescription)")
        }

        if !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                let modelIDs = try await fetchGeminiModelIDs(baseURL: config.baseURL, apiKey: config.apiKey)
                modelsByProvider[.gemini] = AIModelCatalog.filterAllowedListedModelIDs(providerID: .gemini, remoteModelIDs: modelIDs)
            } catch {
                warnings.append("Gemini: \(error.localizedDescription)")
            }
        }

        if !config.kimiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                let modelIDs = try await openAICompatibleClient.listModelIDs(baseURL: config.kimiBaseURL, apiKey: config.kimiAPIKey)
                modelsByProvider[.kimi] = AIModelCatalog.filterAllowedListedModelIDs(providerID: .kimi, remoteModelIDs: modelIDs)
            } catch {
                warnings.append("Kimi: \(error.localizedDescription)")
            }
        }

        if !config.qwenAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                let modelIDs = try await openAICompatibleClient.listModelIDs(baseURL: config.qwenBaseURL, apiKey: config.qwenAPIKey)
                modelsByProvider[.qwen] = AIModelCatalog.filterAllowedListedModelIDs(providerID: .qwen, remoteModelIDs: modelIDs)
            } catch {
                warnings.append("Qwen: \(error.localizedDescription)")
            }
        }

        if !config.awsAccessKeyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !config.awsSecretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                let remoteModels = try await bedrockClient.listFoundationModels(config: config)
                modelsByProvider[.amazonBedrock] = AIModelCatalog.filterAllowedRemoteModels(providerID: .amazonBedrock, remoteModels: remoteModels)
            } catch {
                warnings.append("Amazon Bedrock: \(error.localizedDescription)")
            }
        }

        let models = AIProviderID.allCases.flatMap { providerID -> [AIModelReference] in
            if let verified = modelsByProvider[providerID], !verified.isEmpty {
                return verified
            }
            if providerID == .openRouter {
                return []
            }
            return AIModelCatalog.providerModels(providerID)
        }
        .sorted(by: AIModelCatalog.sortModels)

        return AIModelRefreshResult(models: models, warnings: warnings)
    }

    /// Performs a live OpenRouter capability check before sending local video data.
    public func isOpenRouterModelVideoCapable(config: AppConfig, modelID: String) async -> Bool {
        do {
            let models = try await fetchOpenRouterModels(baseURL: config.openRouterBaseURL)
            return models.contains { $0.modelID == modelID }
        } catch {
            AppLog.warning("OpenRouter model capability check failed: \(error.localizedDescription)", category: .ai)
            return false
        }
    }

    private func fetchOpenRouterModels(baseURL: String) async throws -> [AIModelReference] {
        let url = try endpoint(baseURL: baseURL, path: "models?output_modalities=text")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await urlSession.data(for: request)
        try validate(response, data: data, provider: AIProviderID.openRouter.displayName, context: "GET \(url.absoluteString)")
        let decoded = try decoder.decode(OpenRouterModelsResponse.self, from: data)
        let remoteModels = decoded.data.map {
            RemoteAIModelCapability(
                modelID: $0.id,
                displayName: $0.name,
                inputModalities: $0.architecture?.inputModalities ?? []
            )
        }
        return AIModelCatalog.filterAllowedRemoteModels(providerID: .openRouter, remoteModels: remoteModels)
    }

    private func fetchGeminiModelIDs(baseURL: String, apiKey: String) async throws -> [String] {
        let normalizedBase = normalizedAPIBase(baseURL)
        guard var components = URLComponents(string: "\(normalizedBase)/v1beta/models") else {
            throw AIClientError.invalidURL(baseURL)
        }
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else {
            throw AIClientError.invalidURL(baseURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await urlSession.data(for: request)
        try validate(response, data: data, provider: AIProviderID.gemini.displayName, context: "GET Gemini models")
        let decoded = try decoder.decode(GeminiModelsResponse.self, from: data)
        return decoded.models
            .filter { ($0.supportedGenerationMethods ?? []).contains("generateContent") }
            .map { $0.name.replacingOccurrences(of: "models/", with: "") }
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
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw AIClientError.apiError(provider: provider, status: http.statusCode, message: String(message.prefix(800)), context: context)
        }
    }
}

private struct OpenRouterModelsResponse: Decodable {
    var data: [OpenRouterModel]
}

private struct OpenRouterModel: Decodable {
    var id: String
    var name: String?
    var architecture: OpenRouterArchitecture?
}

private struct OpenRouterArchitecture: Decodable {
    var inputModalities: [String]?

    enum CodingKeys: String, CodingKey {
        case inputModalities = "input_modalities"
    }
}

private struct GeminiModelsResponse: Decodable {
    var models: [GeminiModelSummary]
}

private struct GeminiModelSummary: Decodable {
    var name: String
    var supportedGenerationMethods: [String]?
}
