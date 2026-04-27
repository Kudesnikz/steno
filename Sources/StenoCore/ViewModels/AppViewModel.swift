import AppKit
import Foundation
import Observation

@MainActor
@Observable
public final class AppViewModel {
    public var config: AppConfig
    public var sessions: [MeetingSession] = []
    public var selectedSessionID: MeetingSession.ID?
    public var selectedTabID: String = "player"
    public var isRecording = false
    public var isProcessing = false
    public var isCheckingAIConnection = false
    public var recordingDuration = 0
    public var statusMessage: String?
    public var errorMessage: String?
    public var availableAIModels: [AIModelReference] = AIModelCatalog.fallbackModels
    public var isRefreshingAIModels = false
    public var showOnboarding = false
    public var showSettings = false
    public var permissionState = PermissionState(hasScreenCapture: false, hasMicrophone: false)

    @ObservationIgnored private let configStore: ConfigStore
    @ObservationIgnored private var sessionStore = SessionStore(saveDirectory: URL(fileURLWithPath: AppConfig.default.saveDirectory))
    @ObservationIgnored private let permissionsService: PermissionsService
    @ObservationIgnored private let aiClient: AIProcessingClient
    @ObservationIgnored private let modelCatalogService: AIModelCatalogService
    @ObservationIgnored private var recorder: ScreenRecordingService?
    @ObservationIgnored private var recordingTimerTask: Task<Void, Never>?
    @ObservationIgnored private var aiTask: Task<Void, Never>?
    @ObservationIgnored private var currentRecordingBaseName: String?
    @ObservationIgnored private var currentRecordingURL: URL?

    public init(
        configStore: ConfigStore = ConfigStore(),
        permissionsService: PermissionsService = PermissionsService(),
        aiClient: AIProcessingClient = AIProcessingClient(),
        modelCatalogService: AIModelCatalogService = AIModelCatalogService()
    ) {
        self.configStore = configStore
        self.permissionsService = permissionsService
        self.aiClient = aiClient
        self.modelCatalogService = modelCatalogService

        var loadedConfig = AppConfig.default
        var shouldShowOnboarding = true
        var initialStatus: String?
        var initialError: String?

        do {
            let loadResult = try configStore.load()
            loadedConfig = loadResult.config
            shouldShowOnboarding = !loadResult.didFindExistingConfig || loadedConfig.apiKey(for: loadedConfig.aiProvider).isEmpty
            if loadResult.didMigrateLegacyConfig {
                initialStatus = "Legacy config migrated to ~/.steno/config.json"
            }
        } catch {
            loadedConfig = .default
            shouldShowOnboarding = true
            initialError = "Config load failed: \(error.localizedDescription)"
        }

        config = loadedConfig
        showOnboarding = shouldShowOnboarding
        statusMessage = initialStatus
        errorMessage = initialError
        sessionStore = SessionStore(saveDirectory: URL(fileURLWithPath: loadedConfig.saveDirectory))
        permissionState = permissionsService.currentState()
        refreshSessions()
        Task {
            await refreshAIModels()
        }
        AppLog.info("AppViewModel initialized; onboarding=\(showOnboarding)", category: .app)
    }

    deinit {
        recordingTimerTask?.cancel()
        aiTask?.cancel()
    }

    public var selectedSession: MeetingSession? {
        sessions.first { $0.id == selectedSessionID }
    }

    public var activeAgent: Agent? {
        config.activeAgent ?? config.agents.first
    }

    public var canGenerate: Bool {
        selectedSession != nil && !isProcessing && !isRecording
    }

    public func refreshPermissions() {
        permissionState = permissionsService.currentState()
        AppLog.info("Refreshed permissions screen=\(permissionState.hasScreenCapture) microphone=\(permissionState.hasMicrophone)", category: .permissions)
    }

    public func requestInitialPermissions() {
        permissionsService.requestScreenCaptureAccess()
        Task {
            _ = await permissionsService.requestMicrophoneAccess()
            await MainActor.run {
                self.refreshPermissions()
            }
        }
    }

    public func openScreenSettings() {
        permissionsService.openScreenCaptureSettings()
    }

    public func openMicrophoneSettings() {
        permissionsService.openMicrophoneSettings()
    }

    public func saveConfig() {
        normalizeConfig()
        do {
            try configStore.save(config)
            sessionStore = SessionStore(saveDirectory: URL(fileURLWithPath: config.saveDirectory))
            refreshSessions()
            statusMessage = "Settings saved"
            AppLog.info("Settings saved from UI", category: .config)
        } catch {
            errorMessage = "Settings save failed: \(error.localizedDescription)"
            AppLog.error("Settings save failed: \(error.localizedDescription)", category: .config)
        }
    }

    public func completeOnboarding(apiKey: String) {
        config.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        config.aiProvider = .gemini
        saveConfig()
        showOnboarding = false
        AppLog.info("Onboarding completed", category: .ui)
    }

    public func selectAIProvider(_ providerID: String) {
        guard let provider = AIProviderID(rawValue: providerID) else {
            config.aiProvider = .gemini
            config.modelName = AIModelCatalog.defaultModelID(for: .gemini)
            return
        }

        config.aiProvider = provider
        if AIModelCatalog.model(providerID: provider, modelID: config.modelName) == nil {
            config.modelName = AIModelCatalog.defaultModelID(for: provider)
        }
        Task {
            await refreshAIModels()
        }
    }

    public func refreshAIModels() async {
        guard !isRefreshingAIModels else {
            return
        }
        isRefreshingAIModels = true
        let snapshot = config
        AppLog.info("Refreshing AI model catalog provider=\(snapshot.aiProvider.displayName)", category: .ai)
        let result = await modelCatalogService.refreshAvailableModels(config: snapshot)
        availableAIModels = result.models.isEmpty ? AIModelCatalog.fallbackModels : result.models
        if !availableAIModels.contains(where: { $0.providerID == config.aiProvider && $0.modelID == config.modelName }) {
            config.modelName = modelsForSelectedProvider.first?.modelID ?? AIModelCatalog.defaultModelID(for: config.aiProvider)
        }
        if result.warnings.isEmpty {
            statusMessage = "AI models refreshed"
        } else {
            statusMessage = "AI models refreshed with warnings"
            AppLog.warning("AI model refresh warnings: \(result.warnings.joined(separator: " | "))", category: .ai)
        }
        isRefreshingAIModels = false
    }

    public var modelsForSelectedProvider: [AIModelReference] {
        let models = availableAIModels.filter { $0.providerID == config.aiProvider }
        if models.isEmpty, config.aiProvider != .openRouter {
            return AIModelCatalog.providerModels(config.aiProvider)
        }
        return models
    }

    public func refreshSessions() {
        sessions = sessionStore.scanSessions()
        if selectedSessionID == nil || !sessions.contains(where: { $0.id == selectedSessionID }) {
            selectedSessionID = sessions.first?.id
        }
        AppLog.debug("Refreshed sessions count=\(sessions.count)", category: .sessions)
    }

    public func select(_ session: MeetingSession) {
        selectedSessionID = session.id
        selectedTabID = session.sortedReportAgentIDs.first.map { "report:\($0)" } ?? "player"
        AppLog.info("Selected session \(session.baseName)", category: .ui)
    }

    public func renameSelectedSession(to name: String) {
        guard let session = selectedSession else {
            return
        }
        do {
            try sessionStore.rename(session: session, to: name)
            refreshSessions()
        } catch {
            errorMessage = "Rename failed: \(error.localizedDescription)"
            AppLog.error("Rename failed: \(error.localizedDescription)", category: .sessions)
        }
    }

    public func deleteSelectedSession() {
        guard let session = selectedSession else {
            return
        }
        do {
            try sessionStore.delete(session: session)
            refreshSessions()
        } catch {
            errorMessage = "Delete failed: \(error.localizedDescription)"
            AppLog.error("Delete failed: \(error.localizedDescription)", category: .sessions)
        }
    }

    public func startRecording() async {
        guard !isRecording, !isProcessing else {
            return
        }
        refreshPermissions()
        guard permissionState.hasScreenCapture, permissionState.hasMicrophone else {
            let missing = missingPermissionNames()
            errorMessage = "Recording blocked. Grant permissions: \(missing)."
            statusMessage = "Recording blocked by macOS permissions"
            showOnboarding = true
            AppLog.warning(
                "Recording blocked by permissions screen=\(permissionState.hasScreenCapture) microphone=\(permissionState.hasMicrophone)",
                category: .recording
            )
            return
        }
        guard !config.apiKey(for: config.aiProvider).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Please set \(config.aiProvider.displayName) credentials in Settings"
            showSettings = true
            AppLog.warning("Recording blocked because API key is missing", category: .recording)
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy_HH:mm:ss"
        let timestamp = formatter.string(from: Date())
        let baseName = "Meet_\(timestamp)"
        let saveURL = URL(fileURLWithPath: config.saveDirectory)
        let outputURL = saveURL.appending(path: "\(baseName).mp4")

        do {
            try FileManager.default.createDirectory(at: saveURL, withIntermediateDirectories: true)

            let recorder = ScreenRecordingService()
            self.recorder = recorder
            currentRecordingBaseName = baseName
            currentRecordingURL = outputURL
            recordingDuration = 0
            AppLog.info("Recording requested baseName=\(baseName)", category: .recording)

            try await recorder.start(outputURL: outputURL, preset: config.preset()) { [weak self] event in
                Task { @MainActor in
                    self?.handleRecorderEvent(event)
                }
            }
            try sessionStore.createInitialMetadata(baseName: baseName, displayName: timestamp.replacingOccurrences(of: "_", with: " "), createdAt: timestamp)
            isRecording = true
            statusMessage = "Recording started"
            startRecordingTimer()
        } catch {
            recordingTimerTask?.cancel()
            recordingTimerTask = nil
            if let recorder {
                try? await recorder.stop()
            }
            isRecording = false
            recorder = nil
            try? FileManager.default.removeItem(at: outputURL)
            currentRecordingBaseName = nil
            currentRecordingURL = nil
            errorMessage = "Start recording failed: \(error.localizedDescription)"
            AppLog.error("Start recording failed: \(error.localizedDescription)", category: .recording)
            refreshSessions()
        }
    }

    public func stopRecording() async {
        guard isRecording else {
            return
        }
        recordingTimerTask?.cancel()
        recordingTimerTask = nil

        do {
            try await recorder?.stop()
            if let baseName = currentRecordingBaseName, let url = currentRecordingURL {
                if await recordedFileExists(url) {
                    try sessionStore.updateRecordingMetadata(
                        baseName: baseName,
                        duration: recordingDuration,
                        quality: config.videoQuality,
                        videoURL: url
                    )
                } else {
                    try? sessionStore.deleteArtifacts(baseName: baseName)
                    AppLog.warning("Recording stopped without output file; cleaned artifacts for \(baseName)", category: .recording)
                }
            }
            statusMessage = "Recording stopped"
            errorMessage = nil
            AppLog.info("Recording stop completed", category: .recording)
        } catch {
            errorMessage = "Stop recording failed: \(error.localizedDescription)"
            AppLog.error("Stop recording failed: \(error.localizedDescription)", category: .recording)
        }

        recorder = nil
        isRecording = false
        currentRecordingBaseName = nil
        currentRecordingURL = nil
        refreshSessions()
    }

    public func checkAIConnection() {
        guard !isCheckingAIConnection else {
            return
        }

        isCheckingAIConnection = true
        statusMessage = "Checking AI connection"
        let snapshotConfig = config
        AppLog.info("AI connection check requested model=\(snapshotConfig.modelName)", category: .ai)
        Task { [weak self] in
            guard let self else {
                return
            }
            do {
                let result = try await self.aiClient.validateConfiguration(config: snapshotConfig)
                self.statusMessage = "\(result.providerName) connection OK: \(result.modelName)"
                self.errorMessage = nil
                AppLog.info("AI connection check completed baseURL=\(result.baseURL) model=\(result.modelName)", category: .ai)
            } catch {
                let safeMessage = self.masked(error.localizedDescription, config: snapshotConfig)
                self.statusMessage = "AI connection failed"
                self.errorMessage = "AI check failed: \(safeMessage)"
                AppLog.error("AI connection check failed: \(safeMessage)", category: .ai)
            }
            self.isCheckingAIConnection = false
        }
    }

    public func generateSelectedReport() {
        guard let session = selectedSession, let agent = activeAgent, !isProcessing else {
            return
        }

        isProcessing = true
        errorMessage = nil
        statusMessage = "AI processing started"
        AppLog.info("AI processing requested session=\(session.baseName) agent=\(agent.id)", category: .ai)

        let snapshotConfig = config
        aiTask = Task { [weak self] in
            guard let self else {
                return
            }
            do {
                let result = try await self.aiClient.generateReport(
                    videoURL: session.videoURL,
                    audioURLs: session.audioURLs,
                    config: snapshotConfig,
                    agent: agent
                )
                let outputURL = try self.sessionStore.saveReportText(result.text, baseName: session.baseName, agentID: agent.id)
                var metadata = result.metadata
                metadata.outputFileName = outputURL.lastPathComponent

                let report = ReportInfo(
                    agentID: agent.id,
                    agentName: metadata.agentName,
                    model: metadata.model,
                    createdAt: metadata.createdAt,
                    processingDurationSeconds: metadata.durationSeconds,
                    tokens: ReportTokens(input: metadata.tokensInput, output: metadata.tokensOutput, total: metadata.tokensTotal),
                    outputPath: metadata.outputFileName,
                    status: "success"
                )
                try self.sessionStore.appendReportMetadata(baseName: session.baseName, report: report)

                self.config.usedTokens += metadata.tokensTotal
                self.config.lastRequestTokens = metadata.tokensTotal
                self.saveConfig()
                self.refreshSessions()
                self.selectedSessionID = session.id
                self.selectedTabID = "report:\(agent.id)"
                self.statusMessage = "Протокол сохранен: \(metadata.outputFileName)"
                AppLog.info("AI processing completed session=\(session.baseName) tokens=\(metadata.tokensTotal)", category: .ai)
            } catch is CancellationError {
                self.statusMessage = "AI processing cancelled"
                AppLog.warning("AI processing cancelled", category: .ai)
            } catch {
                let safeMessage = self.masked(error.localizedDescription, config: snapshotConfig)
                let report = ReportInfo(
                    agentID: agent.id,
                    agentName: agent.name,
                    model: snapshotConfig.modelName,
                    createdAt: ISO8601DateFormatter().string(from: Date()),
                    processingDurationSeconds: 0,
                    tokens: ReportTokens(input: 0, output: 0, total: 0),
                    outputPath: "",
                    status: "error",
                    error: String(safeMessage.prefix(200))
                )
                try? self.sessionStore.appendReportMetadata(baseName: session.baseName, report: report)
                self.errorMessage = "AI Ошибка: \(safeMessage)"
                AppLog.error("AI processing failed: \(safeMessage)", category: .ai)
                self.refreshSessions()
            }
            self.isProcessing = false
        }
    }

    public func cancelGeneration() {
        aiTask?.cancel()
        aiTask = nil
        isProcessing = false
        AppLog.warning("AI cancellation requested", category: .ai)
    }

    public func loadReportText(agentID: String) -> String {
        guard let url = selectedSession?.reportURLsByAgentID[agentID] else {
            return ""
        }
        return (try? sessionStore.loadReportText(url: url)) ?? ""
    }

    public func copyReport(agentID: String) {
        let text = loadReportText(agentID: agentID)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusMessage = "Copied"
        AppLog.info("Copied report for agent=\(agentID)", category: .ui)
    }

    public func openOutputFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: config.saveDirectory))
        AppLog.info("Opened output folder", category: .ui)
    }

    private func normalizeConfig() {
        if AIProviderID(rawValue: config.aiProviderID) == nil {
            config.aiProvider = .gemini
        }
        config.modelName = AIModelCatalog.normalizedModelID(config.modelName)
        if AIModelCatalog.model(providerID: config.aiProvider, modelID: config.modelName) == nil {
            config.modelName = AIModelCatalog.defaultModelID(for: config.aiProvider)
        }
        if config.agents.isEmpty {
            config.agents = AppConfig.defaultAgents
        }
        if !config.agents.contains(where: { $0.id == config.activeAgentID }) {
            config.activeAgentID = config.agents.first?.id ?? "default"
        }
    }

    private func startRecordingTimer() {
        recordingTimerTask?.cancel()
        recordingTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else {
                    return
                }
                await MainActor.run {
                    self?.recordingDuration += 1
                }
            }
        }
    }

    private func handleRecorderEvent(_ event: RecorderEvent) {
        switch event {
        case .didStart:
            isRecording = true
            AppLog.info("Recorder event didStart", category: .recording)
        case .didFinish:
            AppLog.info("Recorder event didFinish", category: .recording)
        case let .didFail(message):
            errorMessage = "Recording failed: \(message)"
            isRecording = false
            recordingTimerTask?.cancel()
            recordingTimerTask = nil
            if let baseName = currentRecordingBaseName {
                try? sessionStore.deleteArtifacts(baseName: baseName)
            }
            recorder = nil
            currentRecordingBaseName = nil
            currentRecordingURL = nil
            refreshSessions()
            AppLog.error("Recorder event didFail: \(message)", category: .recording)
        }
    }

    private func missingPermissionNames() -> String {
        var names: [String] = []
        if !permissionState.hasScreenCapture {
            names.append("Screen Recording")
        }
        if !permissionState.hasMicrophone {
            names.append("Microphone")
        }
        return names.joined(separator: ", ")
    }

    private func recordedFileExists(_ url: URL) async -> Bool {
        for _ in 0..<10 {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 {
                return true
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    private func masked(_ message: String, config: AppConfig) -> String {
        [
            config.apiKey,
            config.openRouterAPIKey,
            config.kimiAPIKey,
            config.qwenAPIKey,
            config.awsAccessKeyID,
            config.awsSecretAccessKey,
            config.awsSessionToken
        ]
        .filter { $0.count > 4 }
        .reduce(message) { result, token in
            result.replacingOccurrences(of: token, with: "***MASKED***")
        }
    }
}
