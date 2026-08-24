import Foundation

public struct RemoteCleanupEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var manifest: RemoteMediaManifest
    public var enqueuedAt: Date

    public init(id: String = UUID().uuidString, manifest: RemoteMediaManifest, enqueuedAt: Date = Date()) {
        self.id = id
        self.manifest = manifest
        self.enqueuedAt = enqueuedAt
    }
}
public actor RemoteCleanupStore {
    private let url: URL
    private let fileManager: FileManager
    private var entries: [RemoteCleanupEntry]

    public init(
        url: URL = UserPaths.stenoDirectory.appending(path: "remote-cleanup.json"),
        fileManager: FileManager = .default
    ) {
        self.url = url
        self.fileManager = fileManager
        if let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode([RemoteCleanupEntry].self, from: data) {
            entries = stored
        } else {
            entries = []
        }
    }

    public func enqueue(_ manifest: RemoteMediaManifest) throws {
        entries.append(RemoteCleanupEntry(manifest: manifest))
        try persist()
    }

    public func pending(config: AppConfig) -> [RemoteCleanupEntry] {
        let credential = GeminiUsageStore.credentialFingerprint(config.apiKey)
        let baseURL = GeminiUsageStore.credentialFingerprint(normalizedBaseURL(config.baseURL))
        return entries.filter {
            $0.manifest.credentialFingerprint == credential && $0.manifest.baseURLFingerprint == baseURL
        }
    }

    public func markCompleted(id: String) throws {
        entries.removeAll { $0.id == id }
        try persist()
    }

    public func discardExpired(now: Date = Date()) throws {
        entries.removeAll { entry in
            entry.manifest.parts.allSatisfy { $0.expiresAt <= now }
        }
        try persist()
    }

    private func persist() throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(entries).write(to: url, options: .atomic)
    }

    private func normalizedBaseURL(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") ? trimmed : "https://\(trimmed)"
        return withScheme.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
