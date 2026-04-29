import Foundation

public struct AIConnectionCheckResult: Hashable, Sendable {
    public var providerName: String
    public var baseURL: String
    public var modelName: String
    public var responseText: String

    public init(providerName: String, baseURL: String, modelName: String, responseText: String) {
        self.providerName = providerName
        self.baseURL = baseURL
        self.modelName = modelName
        self.responseText = responseText
    }
}

public enum AIClientError: LocalizedError, Sendable {
    case missingAPIKey(AIProviderID)
    case unsupportedModel(providerID: AIProviderID, modelID: String)
    case emptyResponse
    case invalidURL(String)
    case apiError(provider: String, status: Int, message: String, context: String)

    public var errorDescription: String? {
        switch self {
        case let .missingAPIKey(providerID):
            "Нет API ключа для \(providerID.displayName). Настройте ключ в Settings."
        case let .unsupportedModel(providerID, modelID):
            "Модель \(modelID) не разрешена для \(providerID.displayName) или не подтверждена как video-input."
        case .emptyResponse:
            "AI вернул пустой ответ."
        case let .invalidURL(value):
            "Invalid AI URL: \(value)"
        case let .apiError(provider, status, message, context):
            "\(provider) API error \(status) at \(context): \(message)"
        }
    }
}

public actor AIProcessingClient {
    private let geminiClient: GeminiClient
    private let openAICompatibleClient: OpenAICompatibleClient
    private let bedrockClient: BedrockClient
    private let modelCatalogService: AIModelCatalogService
    private let mediaPreparationService: AIMediaPreparationService

    public init(
        geminiClient: GeminiClient = GeminiClient(),
        openAICompatibleClient: OpenAICompatibleClient = OpenAICompatibleClient(),
        bedrockClient: BedrockClient = BedrockClient(),
        modelCatalogService: AIModelCatalogService = AIModelCatalogService(),
        mediaPreparationService: AIMediaPreparationService = AIMediaPreparationService()
    ) {
        self.geminiClient = geminiClient
        self.openAICompatibleClient = openAICompatibleClient
        self.bedrockClient = bedrockClient
        self.modelCatalogService = modelCatalogService
        self.mediaPreparationService = mediaPreparationService
    }

    /// Validates credentials, selected model allowlist membership, and provider reachability.
    public func validateConfiguration(config: AppConfig) async throws -> AIConnectionCheckResult {
        let model = try selectedAllowedModel(config: config)
        try requireCredentials(config: config, providerID: model.providerID)
        try await verifyDynamicVideoCapabilityIfNeeded(config: config, model: model)

        switch model.providerID {
        case .gemini:
            let result = try await geminiClient.validateConfiguration(config: config)
            return AIConnectionCheckResult(
                providerName: model.providerID.displayName,
                baseURL: result.baseURL,
                modelName: result.modelName,
                responseText: result.responseText
            )
        case .kimi, .qwen, .openRouter:
            let responseText = try await openAICompatibleClient.validateConfiguration(config: config, model: model)
            return AIConnectionCheckResult(
                providerName: model.providerID.displayName,
                baseURL: config.baseURL(for: model.providerID),
                modelName: model.modelID,
                responseText: responseText
            )
        case .amazonBedrock:
            let responseText = try await bedrockClient.validateConfiguration(config: config, model: model)
            return AIConnectionCheckResult(
                providerName: model.providerID.displayName,
                baseURL: config.baseURL(for: model.providerID),
                modelName: model.modelID,
                responseText: responseText
            )
        }
    }

    /// Generates a meeting protocol using the selected provider while preserving the shared prompt contract.
    public func generateReport(
        videoURL: URL,
        audioURLs: [URL],
        transcript: AITranscriptContext?,
        config: AppConfig,
        agent: Agent,
        progress: AIProgressHandler? = nil
    ) async throws -> AIProcessingResult {
        let model = try selectedAllowedModel(config: config)
        try requireCredentials(config: config, providerID: model.providerID)
        try await verifyDynamicVideoCapabilityIfNeeded(config: config, model: model)
        let preparedMedia = try await mediaPreparationService.prepareVideoIfNeeded(
            videoURL: videoURL,
            providerID: model.providerID,
            progress: progress
        )
        defer {
            mediaPreparationService.cleanup(preparedMedia)
        }

        switch model.providerID {
        case .gemini:
            return try await geminiClient.generateReport(
                videoURL: preparedMedia.videoURL,
                audioURLs: audioURLs,
                transcript: transcript,
                config: config,
                agent: agent,
                progress: progress
            )
        case .kimi, .qwen, .openRouter:
            return try await openAICompatibleClient.generateReport(
                videoURL: preparedMedia.videoURL,
                transcript: transcript,
                config: config,
                model: model,
                agent: agent,
                progress: progress
            )
        case .amazonBedrock:
            return try await bedrockClient.generateReport(
                videoURL: preparedMedia.videoURL,
                transcript: transcript,
                config: config,
                model: model,
                agent: agent,
                progress: progress
            )
        }
    }

    private func selectedAllowedModel(config: AppConfig) throws -> AIModelReference {
        let providerID = config.aiProvider
        let modelID = AIModelCatalog.normalizedModelID(config.modelName)
        guard let model = AIModelCatalog.model(providerID: providerID, modelID: modelID),
              AIModelCatalog.hasVideoInput(model.inputModalities) else {
            throw AIClientError.unsupportedModel(providerID: providerID, modelID: modelID)
        }
        return model
    }

    private func requireCredentials(config: AppConfig, providerID: AIProviderID) throws {
        let apiKey = config.apiKey(for: providerID).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw AIClientError.missingAPIKey(providerID)
        }
    }

    private func verifyDynamicVideoCapabilityIfNeeded(config: AppConfig, model: AIModelReference) async throws {
        guard model.providerID == .openRouter else {
            return
        }
        let isVideoCapable = await modelCatalogService.isOpenRouterModelVideoCapable(config: config, modelID: model.modelID)
        guard isVideoCapable else {
            throw AIClientError.unsupportedModel(providerID: model.providerID, modelID: model.modelID)
        }
    }
}
