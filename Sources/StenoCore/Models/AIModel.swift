import Foundation

/// Provider endpoint family used for meeting analysis.
public enum AIProviderID: String, Codable, CaseIterable, Identifiable, Sendable {
    case gemini = "gemini"
    case kimi = "kimi"
    case amazonBedrock = "amazon_bedrock"
    case qwen = "qwen"
    case openRouter = "openrouter"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .gemini:
            "Gemini API"
        case .kimi:
            "Kimi API"
        case .amazonBedrock:
            "Amazon Bedrock"
        case .qwen:
            "Qwen Cloud"
        case .openRouter:
            "OpenRouter"
        }
    }
}

/// Cost bucket shown in Settings so expensive and economical models remain explicit.
public enum AIModelTier: String, Codable, Sendable {
    case premium
    case economical

    public var displayName: String {
        switch self {
        case .premium:
            "дорогая"
        case .economical:
            "дешевая"
        }
    }
}

/// A model that Steno is allowed to use for video-based meeting protocols.
public struct AIModelReference: Codable, Identifiable, Hashable, Sendable {
    public var providerID: AIProviderID
    public var modelID: String
    public var displayName: String
    public var tier: AIModelTier
    public var inputModalities: [String]
    public var isDynamicallyVerified: Bool

    public var id: String { Self.id(providerID: providerID, modelID: modelID) }

    public init(
        providerID: AIProviderID,
        modelID: String,
        displayName: String,
        tier: AIModelTier,
        inputModalities: [String] = ["text", "video"],
        isDynamicallyVerified: Bool = false
    ) {
        self.providerID = providerID
        self.modelID = modelID
        self.displayName = displayName
        self.tier = tier
        self.inputModalities = inputModalities
        self.isDynamicallyVerified = isDynamicallyVerified
    }

    public static func id(providerID: AIProviderID, modelID: String) -> String {
        "\(providerID.rawValue):\(modelID)"
    }

    public func verified(inputModalities: [String]? = nil, displayName: String? = nil) -> AIModelReference {
        AIModelReference(
            providerID: providerID,
            modelID: modelID,
            displayName: displayName ?? self.displayName,
            tier: tier,
            inputModalities: inputModalities ?? self.inputModalities,
            isDynamicallyVerified: true
        )
    }
}

/// Normalized remote model metadata returned by provider model-list APIs.
public struct RemoteAIModelCapability: Hashable, Sendable {
    public var modelID: String
    public var displayName: String?
    public var inputModalities: [String]

    public init(modelID: String, displayName: String? = nil, inputModalities: [String]) {
        self.modelID = modelID
        self.displayName = displayName
        self.inputModalities = inputModalities
    }
}

/// Central allowlist: Steno never shows arbitrary provider models, only the requested models
/// that are documented or dynamically reported as accepting video input.
public enum AIModelCatalog {
    public static let allowedModels: [AIModelReference] = [
        AIModelReference(
            providerID: .gemini,
            modelID: "gemini-3.1-pro-preview",
            displayName: "Gemini 3.1 Pro Preview",
            tier: .premium,
            inputModalities: ["text", "image", "audio", "video", "file"]
        ),
        AIModelReference(
            providerID: .gemini,
            modelID: "gemini-3.1-flash-lite-preview",
            displayName: "Gemini 3.1 Flash Lite Preview",
            tier: .economical,
            inputModalities: ["text", "image", "audio", "video", "file"]
        ),
        AIModelReference(
            providerID: .gemini,
            modelID: "gemini-3-flash-preview",
            displayName: "Gemini 3 Flash Preview",
            tier: .economical,
            inputModalities: ["text", "image", "audio", "video", "file"]
        ),
        AIModelReference(
            providerID: .kimi,
            modelID: "kimi-k2.6",
            displayName: "Kimi K2.6",
            tier: .premium
        ),
        AIModelReference(
            providerID: .amazonBedrock,
            modelID: "amazon.nova-premier-v1:0",
            displayName: "Amazon Nova Premier",
            tier: .premium,
            inputModalities: ["TEXT", "IMAGE", "VIDEO"]
        ),
        AIModelReference(
            providerID: .amazonBedrock,
            modelID: "amazon.nova-2-lite-v1:0",
            displayName: "Amazon Nova 2 Lite",
            tier: .economical,
            inputModalities: ["TEXT", "IMAGE", "VIDEO"]
        ),
        AIModelReference(
            providerID: .qwen,
            modelID: "qwen3-vl-plus",
            displayName: "Qwen3-VL Plus",
            tier: .premium
        ),
        AIModelReference(
            providerID: .qwen,
            modelID: "qwen3-vl-flash",
            displayName: "Qwen3-VL Flash",
            tier: .economical
        ),
        AIModelReference(
            providerID: .openRouter,
            modelID: "google/gemini-3.1-pro-preview",
            displayName: "Gemini 3.1 Pro Preview via OpenRouter",
            tier: .premium,
            inputModalities: ["text", "image", "audio", "video", "file"]
        ),
        AIModelReference(
            providerID: .openRouter,
            modelID: "moonshotai/kimi-k2.6",
            displayName: "Kimi K2.6 via OpenRouter",
            tier: .premium
        ),
        AIModelReference(
            providerID: .openRouter,
            modelID: "amazon/nova-premier-v1",
            displayName: "Amazon Nova Premier via OpenRouter",
            tier: .premium
        ),
        AIModelReference(
            providerID: .openRouter,
            modelID: "qwen/qwen3-vl-plus",
            displayName: "Qwen3-VL Plus via OpenRouter",
            tier: .premium
        ),
        AIModelReference(
            providerID: .openRouter,
            modelID: "google/gemini-3.1-flash-lite-preview",
            displayName: "Gemini 3.1 Flash Lite Preview via OpenRouter",
            tier: .economical,
            inputModalities: ["text", "image", "audio", "video", "file"]
        ),
        AIModelReference(
            providerID: .openRouter,
            modelID: "google/gemini-3-flash-preview",
            displayName: "Gemini 3 Flash Preview via OpenRouter",
            tier: .economical,
            inputModalities: ["text", "image", "audio", "video", "file"]
        ),
        AIModelReference(
            providerID: .openRouter,
            modelID: "amazon/nova-2-lite-v1",
            displayName: "Amazon Nova 2 Lite via OpenRouter",
            tier: .economical,
            inputModalities: ["text", "image", "video", "file"]
        ),
        AIModelReference(
            providerID: .openRouter,
            modelID: "qwen/qwen3-vl-flash",
            displayName: "Qwen3-VL Flash via OpenRouter",
            tier: .economical
        )
    ]

    public static var fallbackModels: [AIModelReference] {
        allowedModels.filter { $0.providerID != .openRouter }
    }

    public static func providerModels(_ providerID: AIProviderID) -> [AIModelReference] {
        allowedModels
            .filter { $0.providerID == providerID }
            .sorted(by: sortModels)
    }

    public static func defaultModelID(for providerID: AIProviderID) -> String {
        providerModels(providerID).first?.modelID ?? "gemini-3-flash-preview"
    }

    public static func model(providerID: AIProviderID, modelID: String) -> AIModelReference? {
        let normalized = normalizedModelID(modelID)
        return allowedModels.first { $0.providerID == providerID && $0.modelID == normalized }
    }

    public static func normalizedModelID(_ modelID: String) -> String {
        switch modelID {
        case "gemini-3.1-flash-light-preview":
            "gemini-3.1-flash-lite-preview"
        default:
            modelID
        }
    }

    public static func filterAllowedRemoteModels(
        providerID: AIProviderID,
        remoteModels: [RemoteAIModelCapability]
    ) -> [AIModelReference] {
        remoteModels.compactMap { remote in
            guard hasVideoInput(remote.inputModalities),
                  let allowed = model(providerID: providerID, modelID: remote.modelID) else {
                return nil
            }
            return allowed.verified(
                inputModalities: remote.inputModalities,
                displayName: remote.displayName
            )
        }
        .sorted(by: sortModels)
    }

    public static func filterAllowedListedModelIDs(
        providerID: AIProviderID,
        remoteModelIDs: [String]
    ) -> [AIModelReference] {
        let normalizedIDs = Set(remoteModelIDs.map(normalizedModelID))
        return providerModels(providerID)
            .filter { normalizedIDs.contains($0.modelID) }
            .map { $0.verified() }
            .sorted(by: sortModels)
    }

    public static func hasVideoInput(_ modalities: [String]) -> Bool {
        modalities.contains { $0.localizedCaseInsensitiveCompare("video") == .orderedSame }
    }

    public static func sortModels(lhs: AIModelReference, rhs: AIModelReference) -> Bool {
        if lhs.providerID != rhs.providerID {
            return lhs.providerID.displayName < rhs.providerID.displayName
        }
        if lhs.tier != rhs.tier {
            return lhs.tier == .premium
        }
        return lhs.displayName < rhs.displayName
    }
}
