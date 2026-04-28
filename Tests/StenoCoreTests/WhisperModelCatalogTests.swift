@testable import StenoCore
import XCTest

final class WhisperModelCatalogTests: XCTestCase {
    func testFallbackCatalogContainsMultipleFamiliesAndQuantizations() {
        let models = WhisperModelCatalogService.fallbackModels

        XCTAssertTrue(models.contains { $0.id == "ggml-tiny-q5_1" })
        XCTAssertTrue(models.contains { $0.id == "ggml-small-q8_0" })
        XCTAssertTrue(models.contains { $0.id == "ggml-large-v3-turbo-q5_0" })
        XCTAssertTrue(Set(models.map(\.quantization)).isSuperset(of: ["Q5_0", "Q5_1", "Q8_0", "Full"]))
    }

    func testDescriptorParsesFamilyQuantizationAndLanguage() {
        let model = WhisperModelCatalogService.descriptor(
            fileName: "ggml-large-v3-turbo-q5_0.bin",
            sizeBytes: 574_041_195,
            sha256: "abc"
        )

        XCTAssertEqual(model.id, "ggml-large-v3-turbo-q5_0")
        XCTAssertEqual(model.family, "large-v3-turbo")
        XCTAssertEqual(model.quantization, "Q5_0")
        XCTAssertEqual(model.language, "Multilingual")
        XCTAssertEqual(model.sha256, "abc")
    }
}
