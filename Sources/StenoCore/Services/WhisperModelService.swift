import CryptoKit
import Foundation

public enum WhisperModelServiceError: LocalizedError, Sendable {
    case modelUnavailable(String)
    case checksumMismatch(modelID: String)

    public var errorDescription: String? {
        switch self {
        case let .modelUnavailable(modelID):
            "Whisper model is unavailable: \(modelID)."
        case let .checksumMismatch(modelID):
            "Downloaded Whisper model failed checksum verification: \(modelID)."
        }
    }
}

public actor WhisperModelCatalogService {
    private let urlSession: URLSession
    private let decoder = JSONDecoder()

    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    public func refreshCatalog() async -> [WhisperModelDescriptor] {
        guard let url = URL(string: "https://huggingface.co/api/models/ggerganov/whisper.cpp/tree/main?recursive=false") else {
            return Self.fallbackModels
        }

        do {
            let (data, response) = try await urlSession.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                AppLog.warning("Whisper model catalog HTTP \(http.statusCode); using fallback catalog", category: .config)
                return Self.fallbackModels
            }
            let entries = try decoder.decode([HuggingFaceTreeEntry].self, from: data)
            let models = entries.compactMap(Self.descriptor(from:))
            return models.isEmpty ? Self.fallbackModels : models.sortedByWhisperModelRank()
        } catch {
            AppLog.warning("Whisper model catalog refresh failed: \(error.localizedDescription)", category: .config)
            return Self.fallbackModels
        }
    }

    public static let fallbackModels: [WhisperModelDescriptor] = [
        descriptor(fileName: "ggml-tiny-q5_1.bin", sizeBytes: 32_152_673, sha256: "818710568da3ca15689e31a743197b520007872ff9576237bda97bd1b469c3d7"),
        descriptor(fileName: "ggml-tiny-q8_0.bin", sizeBytes: 43_537_433, sha256: "c2085835d3f50733e2ff6e4b41ae8a2b8d8110461e18821b09a15c40c42d1cca"),
        descriptor(fileName: "ggml-tiny.bin", sizeBytes: 77_691_713, sha256: "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21"),
        descriptor(fileName: "ggml-base-q5_1.bin", sizeBytes: 59_707_625, sha256: "422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898"),
        descriptor(fileName: "ggml-base-q8_0.bin", sizeBytes: 81_768_585, sha256: "c577b9a86e7e048a0b7eada054f4dd79a56bbfa911fbdacf900ac5b567cbb7d9"),
        descriptor(fileName: "ggml-base.bin", sizeBytes: 147_951_465, sha256: "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"),
        descriptor(fileName: "ggml-small-q5_1.bin", sizeBytes: 190_085_487, sha256: "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb"),
        descriptor(fileName: "ggml-small-q8_0.bin", sizeBytes: 264_464_607, sha256: "49c8fb02b65e6049d5fa6c04f81f53b867b5ec9540406812c643f177317f779f"),
        descriptor(fileName: "ggml-small.bin", sizeBytes: 487_601_967, sha256: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b"),
        descriptor(fileName: "ggml-medium-q5_0.bin", sizeBytes: 539_212_467, sha256: "19fea4b380c3a618ec4723c3eef2eb785ffba0d0538cf43f8f235e7b3b34220f"),
        descriptor(fileName: "ggml-medium-q8_0.bin", sizeBytes: 823_369_779, sha256: "42a1ffcbe4167d224232443396968db4d02d4e8e87e213d3ee2e03095dea6502"),
        descriptor(fileName: "ggml-medium.bin", sizeBytes: 1_533_763_059, sha256: "6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208"),
        descriptor(fileName: "ggml-large-v3-turbo-q5_0.bin", sizeBytes: 574_041_195, sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"),
        descriptor(fileName: "ggml-large-v3-turbo-q8_0.bin", sizeBytes: 874_188_075, sha256: "317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1"),
        descriptor(fileName: "ggml-large-v3-turbo.bin", sizeBytes: 1_624_555_275, sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69")
    ].sortedByWhisperModelRank()

    public static func descriptor(fileName: String, sizeBytes: Int64, sha256: String? = nil, installState: WhisperModelInstallState = .remote) -> WhisperModelDescriptor {
        let id = fileName.replacingOccurrences(of: ".bin", with: "")
        let parsed = ParsedWhisperModelID(id: id)
        return WhisperModelDescriptor(
            id: id,
            fileName: fileName,
            displayName: parsed.displayName,
            family: parsed.family,
            quantization: parsed.quantization,
            language: parsed.language,
            sizeBytes: sizeBytes,
            sha256: sha256,
            installState: installState
        )
    }

    private static func descriptor(from entry: HuggingFaceTreeEntry) -> WhisperModelDescriptor? {
        guard entry.type == "file",
              entry.path.hasPrefix("ggml-"),
              entry.path.hasSuffix(".bin") else {
            return nil
        }
        return descriptor(
            fileName: entry.path,
            sizeBytes: Int64(entry.size),
            sha256: entry.lfs?.oid
        )
    }
}

public actor WhisperModelStore {
    private let fileManager: FileManager
    private let bundledModelID = "ggml-tiny-q5_1"

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func mergedCatalog(remoteModels: [WhisperModelDescriptor]) -> [WhisperModelDescriptor] {
        let downloadedIDs = Set(downloadedModelIDs())
        var modelsByID = Dictionary(uniqueKeysWithValues: remoteModels.map { ($0.id, $0) })

        for id in downloadedIDs where modelsByID[id] == nil {
            let fileName = "\(id).bin"
            let url = UserPaths.whisperModelsDirectory.appending(path: fileName)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            modelsByID[id] = WhisperModelCatalogService.descriptor(fileName: fileName, sizeBytes: size, installState: .downloaded)
        }

        return modelsByID.values.map { model in
            var value = model
            if model.id == bundledModelID {
                value.installState = .bundled
            } else if downloadedIDs.contains(model.id) {
                value.installState = .downloaded
            } else {
                value.installState = .remote
            }
            return value
        }
        .sortedByWhisperModelRank()
    }

    public func installedModelIDs() -> [String] {
        Array(Set([bundledModelID] + downloadedModelIDs())).sorted()
    }

    public func downloadedModelIDs() -> [String] {
        guard let urls = try? fileManager.contentsOfDirectory(at: UserPaths.whisperModelsDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        return urls
            .filter { $0.pathExtension == "bin" && $0.lastPathComponent.hasPrefix("ggml-") }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    public func modelURL(for modelID: String) -> URL? {
        if modelID == bundledModelID,
           let url = Bundle.module.url(forResource: modelID, withExtension: "bin", subdirectory: "Models") {
            return url
        }

        let downloadedURL = UserPaths.whisperModelsDirectory.appending(path: "\(modelID).bin")
        return fileManager.fileExists(atPath: downloadedURL.path) ? downloadedURL : nil
    }

    public func delete(modelID: String) throws {
        guard modelID != bundledModelID else {
            return
        }
        let url = UserPaths.whisperModelsDirectory.appending(path: "\(modelID).bin")
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }
}

public actor WhisperModelDownloadService {
    private let urlSession: URLSession
    private let fileManager: FileManager

    public init(urlSession: URLSession = .shared, fileManager: FileManager = .default) {
        self.urlSession = urlSession
        self.fileManager = fileManager
    }

    public func download(_ model: WhisperModelDescriptor) async throws {
        try fileManager.createDirectory(at: UserPaths.whisperModelsDirectory, withIntermediateDirectories: true)
        let targetURL = UserPaths.whisperModelsDirectory.appending(path: model.fileName)
        if fileManager.fileExists(atPath: targetURL.path),
           try verifyChecksumIfNeeded(url: targetURL, model: model) {
            return
        }

        let temporaryURL = targetURL.appendingPathExtension("download")
        try? fileManager.removeItem(at: temporaryURL)

        let (downloadedURL, response) = try await urlSession.download(from: model.downloadURL)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WhisperModelServiceError.modelUnavailable(model.id)
        }
        try? fileManager.removeItem(at: temporaryURL)
        try fileManager.moveItem(at: downloadedURL, to: temporaryURL)
        guard try verifyChecksumIfNeeded(url: temporaryURL, model: model) else {
            try? fileManager.removeItem(at: temporaryURL)
            throw WhisperModelServiceError.checksumMismatch(modelID: model.id)
        }
        try? fileManager.removeItem(at: targetURL)
        try fileManager.moveItem(at: temporaryURL, to: targetURL)
    }

    private func verifyChecksumIfNeeded(url: URL, model: WhisperModelDescriptor) throws -> Bool {
        guard let expected = model.sha256?.lowercased(), !expected.isEmpty else {
            return true
        }
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return digest == expected
    }
}

private struct HuggingFaceTreeEntry: Decodable {
    var type: String
    var size: Int
    var path: String
    var lfs: HuggingFaceLFS?
}

private struct HuggingFaceLFS: Decodable {
    var oid: String?
}

private struct ParsedWhisperModelID {
    var family: String
    var quantization: String
    var language: String

    init(id: String) {
        var parts = id.replacingOccurrences(of: "ggml-", with: "").split(separator: "-").map(String.init)
        language = parts.last == "en" ? "English" : "Multilingual"
        if language == "English" {
            parts.removeLast()
        }

        if let last = parts.last, last.hasPrefix("q") {
            quantization = last.uppercased()
            parts.removeLast()
        } else {
            quantization = "Full"
        }
        family = parts.joined(separator: "-")
    }

    var displayName: String {
        "\(family) \(quantization) · \(language)"
    }
}

private extension Array where Element == WhisperModelDescriptor {
    func sortedByWhisperModelRank() -> [WhisperModelDescriptor] {
        sorted {
            let left = ($0.family.modelRank, $0.language, $0.quantization.quantRank, $0.sizeBytes, $0.id)
            let right = ($1.family.modelRank, $1.language, $1.quantization.quantRank, $1.sizeBytes, $1.id)
            return left < right
        }
    }
}

private extension String {
    var modelRank: Int {
        if hasPrefix("tiny") { return 0 }
        if hasPrefix("base") { return 1 }
        if hasPrefix("small") { return 2 }
        if hasPrefix("medium") { return 3 }
        if hasPrefix("large-v3-turbo") { return 4 }
        if hasPrefix("large") { return 5 }
        return 9
    }

    var quantRank: Int {
        switch self {
        case "Q5_0", "Q5_1":
            return 0
        case "Q8_0":
            return 1
        case "Full":
            return 2
        default:
            return 3
        }
    }
}
