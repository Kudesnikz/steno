import Foundation

public struct ConfigLoadResult: Sendable {
    public var config: AppConfig
    public var didFindExistingConfig: Bool
    public var didMigrateLegacyConfig: Bool

    public init(config: AppConfig, didFindExistingConfig: Bool, didMigrateLegacyConfig: Bool) {
        self.config = config
        self.didFindExistingConfig = didFindExistingConfig
        self.didMigrateLegacyConfig = didMigrateLegacyConfig
    }
}

public struct ConfigStore {
    public let fileManager: FileManager
    public let configDirectory: URL
    public let configURL: URL
    public let legacyConfigURL: URL
    public let logURL: URL
    private let migrationService: LegacyMigrationService

    public init(
        fileManager: FileManager = .default,
        homeDirectory: URL = UserPaths.homeDirectory
    ) {
        self.fileManager = fileManager
        configDirectory = homeDirectory.appending(path: ".steno", directoryHint: .isDirectory)
        configURL = configDirectory.appending(path: "config.json")
        legacyConfigURL = homeDirectory.appending(path: ".recorder_app_config.json")
        logURL = configDirectory.appending(path: "steno.log")
        migrationService = LegacyMigrationService(fileManager: fileManager)
    }

    public func load() throws -> ConfigLoadResult {
        let didMigrate = try migrationService.migrateConfigFileIfNeeded(
            configDirectory: configDirectory,
            configURL: configURL,
            legacyConfigURL: legacyConfigURL
        )
        if didMigrate {
            AppLog.info("Migrated legacy config file to ~/.steno/config.json", category: .config)
        }

        let didFindExisting = fileManager.fileExists(atPath: configURL.path)
        guard didFindExisting else {
            AppLog.info("Config file not found; using defaults", category: .config)
            return ConfigLoadResult(config: .default, didFindExistingConfig: false, didMigrateLegacyConfig: didMigrate)
        }

        let data = try Data(contentsOf: configURL)
        var config = try JSONDecoder().decode(AppConfig.self, from: migrationService.migrateConfigDataIfNeeded(data))
        if config.agents.isEmpty {
            config.agents = AppConfig.defaultAgents
        }
        if !config.agents.contains(where: { $0.id == config.activeAgentID }) {
            config.activeAgentID = config.agents.first?.id ?? "default"
        }
        AppLog.info("Loaded config with \(config.agents.count) agents", category: .config)
        return ConfigLoadResult(config: config, didFindExistingConfig: true, didMigrateLegacyConfig: didMigrate)
    }

    public func save(_ config: AppConfig) throws {
        try fileManager.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(config)
        try data.write(to: configURL, options: .atomic)
        AppLog.info("Saved config with \(config.agents.count) agents", category: .config)
    }
}
