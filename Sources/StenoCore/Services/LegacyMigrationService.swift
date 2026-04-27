import Foundation

public struct LegacyMigrationService {
    public let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    @discardableResult
    public func migrateConfigFileIfNeeded(configDirectory: URL, configURL: URL, legacyConfigURL: URL) throws -> Bool {
        guard !fileManager.fileExists(atPath: configURL.path),
              fileManager.fileExists(atPath: legacyConfigURL.path) else {
            return false
        }

        try fileManager.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try fileManager.moveItem(at: legacyConfigURL, to: configURL)
        return true
    }

    public func migrateConfigDataIfNeeded(_ data: Data) throws -> Data {
        var json = try JSONSerialization.jsonObject(with: data)
        guard var dictionary = json as? [String: Any] else {
            return data
        }

        if dictionary["agents"] == nil, let prompt = dictionary.removeValue(forKey: "prompt") as? String {
            dictionary["agents"] = [
                [
                    "id": "default",
                    "name": "Стандартный протокол",
                    "prompt": prompt
                ]
            ]
            dictionary["active_agent_id"] = "default"
            json = dictionary
            return try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        }

        return data
    }
}
