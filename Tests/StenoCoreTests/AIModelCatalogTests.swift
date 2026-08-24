@testable import StenoCore
import XCTest

final class AIModelCatalogTests: XCTestCase {
    func testOpenRouterFilterKeepsOnlyAllowlistedVideoModels() {
        let remoteModels = [
            RemoteAIModelCapability(
                modelID: "google/gemini-3.1-pro-preview",
                displayName: "Google: Gemini 3.1 Pro Preview",
                inputModalities: ["text", "image", "video", "file", "audio"]
            ),
            RemoteAIModelCapability(
                modelID: "moonshotai/kimi-k2.6",
                displayName: "MoonshotAI: Kimi K2.6",
                inputModalities: ["text", "image"]
            ),
            RemoteAIModelCapability(
                modelID: "amazon/nova-premier-v1",
                displayName: "Amazon: Nova Premier 1.0",
                inputModalities: ["text", "image"]
            ),
            RemoteAIModelCapability(
                modelID: "amazon/nova-2-lite-v1",
                displayName: "Amazon: Nova 2 Lite",
                inputModalities: ["text", "image", "video", "file"]
            ),
            RemoteAIModelCapability(
                modelID: "unrequested/video-model",
                displayName: "Unrequested Video Model",
                inputModalities: ["text", "video"]
            )
        ]

        let models = AIModelCatalog.filterAllowedRemoteModels(providerID: .openRouter, remoteModels: remoteModels)
        let modelIDs = Set(models.map(\.modelID))

        XCTAssertEqual(modelIDs, ["google/gemini-3.1-pro-preview", "amazon/nova-2-lite-v1"])
        XCTAssertTrue(models.allSatisfy(\.isDynamicallyVerified))
    }

    func testLegacyGeminiFlashLightNormalizesToLatestLiteAlias() {
        XCTAssertEqual(
            AIModelCatalog.normalizedModelID("gemini-3.1-flash-light-preview"),
            "gemini-flash-lite-latest"
        )
    }

    func testFallbackModelsDoNotIncludeOpenRouterWithoutDynamicVerification() {
        XCTAssertFalse(AIModelCatalog.fallbackModels.contains { $0.providerID == .openRouter })
    }

    func testConfigDecodesLegacyModelNameToNormalizedModel() throws {
        let payload = """
        {
          "ai_provider_id": "gemini",
          "model_name": "gemini-3.1-flash-light-preview"
        }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: XCTUnwrap(payload.data(using: .utf8)))

        XCTAssertEqual(config.aiProvider, .gemini)
        XCTAssertEqual(config.modelName, "gemini-flash-lite-latest")
    }

    func testProductionCatalogContainsOnlyGeminiLatestAliases() {
        XCTAssertEqual(Set(ProviderAvailability.activeProviderIDs), [.gemini])
        XCTAssertEqual(
            Set(AIModelCatalog.fallbackModels.map(\.modelID)),
            ["gemini-pro-latest", "gemini-flash-latest", "gemini-flash-lite-latest"]
        )
        XCTAssertEqual(AIModelCatalog.defaultModelID(for: .gemini), "gemini-flash-lite-latest")
    }

    func testDormantProviderModelIDIsNotRewritten() {
        XCTAssertEqual(
            AIModelCatalog.normalizedModelID("google/gemini-3.1-pro-preview"),
            "google/gemini-3.1-pro-preview"
        )
    }

    func testAllLegacyGeminiFamiliesMigrateToLatestAliases() {
        XCTAssertEqual(AIModelCatalog.normalizedModelID("gemini-2.5-pro"), "gemini-pro-latest")
        XCTAssertEqual(AIModelCatalog.normalizedModelID("gemini-2.5-flash"), "gemini-flash-latest")
        XCTAssertEqual(AIModelCatalog.normalizedModelID("gemini-2.5-flash-lite"), "gemini-flash-lite-latest")
    }
}
