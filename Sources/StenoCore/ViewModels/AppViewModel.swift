import AppKit
import Foundation
import Observation

/// User-visible result of the latest AI health check shown in Settings.
public struct AIConnectionCheckStatus: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case success
        case failure
    }

    public var outcome: Outcome
    public var providerName: String
    public var providerID: AIProviderID
    public var baseURL: String
    public var modelName: String
    public var responseText: String?
    public var message: String
    public var checkedAt: Date
    public var durationSeconds: Double

    public init(
        outcome: Outcome,
        providerName: String,
        providerID: AIProviderID,
        baseURL: String,
        modelName: String,
        responseText: String?,
        message: String,
        checkedAt: Date,
        durationSeconds: Double
    ) {
        self.outcome = outcome
        self.providerName = providerName
        self.providerID = providerID
        self.baseURL = baseURL
        self.modelName = modelName
        self.responseText = responseText
        self.message = message
        self.checkedAt = checkedAt
        self.durationSeconds = durationSeconds
    }

    public var isSuccess: Bool {
        outcome == .success
    }

    /// Returns false when the user changes provider, model, or endpoint after the check.
    public func matches(config: AppConfig) -> Bool {
        providerID == config.aiProvider &&
            modelName == config.modelName &&
            baseURL == config.baseURL(for: config.aiProvider)
    }

    /// Multiline text shown by macOS as the hover help for the status icon.
    public var tooltip: String {
        var lines = [
            isSuccess ? "Connection OK" : "Connection failed",
            "Provider: \(providerName)",
            "Model: \(modelName)",
            "Base URL: \(baseURL)"
        ]

        if let responseText, !responseText.isEmpty {
            lines.append("Response: \(responseText)")
        }

        lines.append("Details: \(message)")
        lines.append("Checked: \(checkedAt.formatted(date: .abbreviated, time: .standard))")
        lines.append(String(format: "Duration: %.2fs", durationSeconds))
        return lines.joined(separator: "\n")
    }
}

@MainActor
@Observable
public final class AppViewModel {
    public var config: AppConfig
    public var sessions: [MeetingSession] = []
    public var selectedSessionID: MeetingSession.ID?
    public var selectedTabID: String = "player"
    public var isRecording = false
    public var isFinalizingRecording = false
    public var isProcessing = false
    public var isCheckingAIConnection = false
    public var recordingDuration = 0
    public var statusMessage: String?
    public var errorMessage: String?
    public var aiConnectionCheckStatus: AIConnectionCheckStatus?
    public var availableAIModels: [AIModelReference] = AIModelCatalog.fallbackModels
    public var availableCaptureDisplays: [CaptureDisplay] = []
    public var isRefreshingAIModels = false
    public var isTranscribing = false
    public var liveTranscriptDocument: TranscriptDocument?
    public var transcriptionErrorMessage: String?
    public var transcriptionProgress: TranscriptionProgress = .idle
    public var availableSpeechLanguageOptions: [NativeSpeechLanguageOption] = []
    public var selectedSpeechLanguageStatus: NativeSpeechLanguageOption?
    public var isRefreshingSpeechLanguages = false
    public var showOnboarding = false
    public var showSettings = false
    public var permissionState = PermissionState(hasScreenCapture: false, hasMicrophone: false)

    @ObservationIgnored private let configStore: ConfigStore
    @ObservationIgnored private var sessionStore = SessionStore(saveDirectory: URL(fileURLWithPath: AppConfig.default.saveDirectory))
    @ObservationIgnored private let permissionsService: PermissionsService
    @ObservationIgnored private let captureDisplayService: CaptureDisplayService
    @ObservationIgnored private let aiClient: AIProcessingClient
    @ObservationIgnored private let modelCatalogService: AIModelCatalogService
    @ObservationIgnored private let speechAvailabilityService: NativeSpeechAvailabilityService
    @ObservationIgnored private var recorder: ScreenRecordingService?
    @ObservationIgnored private var transcriptionCoordinator: ContinuousSpeechCoordinator?
    @ObservationIgnored private var recordingTimerTask: Task<Void, Never>?
    @ObservationIgnored private var aiTask: Task<Void, Never>?
    @ObservationIgnored private var currentRecordingBaseName: String?
    @ObservationIgnored private var currentRecordingURL: URL?

    public init(
        configStore: ConfigStore = ConfigStore(),
        permissionsService: PermissionsService = PermissionsService(),
        captureDisplayService: CaptureDisplayService = CaptureDisplayService(),
        aiClient: AIProcessingClient = AIProcessingClient(),
        modelCatalogService: AIModelCatalogService = AIModelCatalogService(),
        speechAvailabilityService: NativeSpeechAvailabilityService = NativeSpeechAvailabilityService()
    ) {
        self.configStore = configStore
        self.permissionsService = permissionsService
        self.captureDisplayService = captureDisplayService
        self.aiClient = aiClient
        self.modelCatalogService = modelCatalogService
        self.speechAvailabilityService = speechAvailabilityService

        var loadedConfig = AppConfig.default
        var didFindExistingConfig = false
        var initialStatus: String?
        var initialError: String?

        do {
            let loadResult = try configStore.load()
            loadedConfig = loadResult.config
            let didMigrateTranscriptionDefaults = Self.migrateTranscriptionDefaultsIfNeeded(&loadedConfig)
            didFindExistingConfig = loadResult.didFindExistingConfig
            if loadResult.didMigrateLegacyConfig {
                initialStatus = "Legacy config migrated to ~/.steno/config.json"
            }
            if didMigrateTranscriptionDefaults {
                try? configStore.save(loadedConfig)
            }
        } catch {
            loadedConfig = .default
            didFindExistingConfig = false
            initialError = "Config load failed: \(error.localizedDescription)"
        }

        let initialPermissionState = permissionsService.currentState()
        config = loadedConfig
        showOnboarding = Self.requiresSetup(
            config: loadedConfig,
            didFindExistingConfig: didFindExistingConfig,
            permissionState: initialPermissionState
        )
        statusMessage = initialStatus
        errorMessage = initialError
        sessionStore = SessionStore(saveDirectory: URL(fileURLWithPath: loadedConfig.saveDirectory))
        permissionState = initialPermissionState
        refreshSessions()
        Task {
            await refreshCaptureDisplays()
        }
        Task {
            await refreshAIModels()
        }
        Task {
            await refreshSpeechLanguageOptions()
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

    public var shouldShowCaptureDisplayPicker: Bool {
        availableCaptureDisplays.count > 1
    }

    public var canGenerate: Bool {
        selectedSession != nil && !isProcessing && !isRecording && !isFinalizingRecording
    }

    public var recordingCommandTitle: String {
        if isFinalizingRecording {
            return "Finalizing Recording..."
        }
        return isRecording ? "Stop Recording" : "Start Recording"
    }

    public var shouldShowTranscriptionLagIndicator: Bool {
        isRecording && transcriptionProgress.hasRealtimeBacklog
    }

    public var shouldShowFinishingTranscriptionProgress: Bool {
        isFinalizingRecording && transcriptionProgress.isFinishing && transcriptionProgress.remainingWindowCount > 0
    }

    public static func requiresSetup(
        config: AppConfig,
        didFindExistingConfig: Bool,
        permissionState: PermissionState
    ) -> Bool {
        !didFindExistingConfig ||
        !hasRequiredPermissions(config: config, permissionState: permissionState) ||
        config.apiKey(for: config.aiProvider).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func hasRequiredPermissions(config: AppConfig, permissionState: PermissionState) -> Bool {
        permissionState.hasScreenCapture &&
            permissionState.hasMicrophone &&
            (!config.localTranscriptionEnabled || permissionState.hasSpeechRecognition)
    }

    public func refreshPermissions() {
        permissionState = permissionsService.currentState()
        if !Self.hasRequiredPermissions(config: config, permissionState: permissionState) {
            showOnboarding = true
        }
        AppLog.info(
            "Refreshed permissions screen=\(permissionState.hasScreenCapture) microphone=\(permissionState.hasMicrophone) speech=\(permissionState.hasSpeechRecognition)",
            category: .permissions
        )
    }

    public func refreshCaptureDisplays() async {
        let displays = await captureDisplayService.availableDisplays()
        guard displays != availableCaptureDisplays else {
            return
        }
        availableCaptureDisplays = displays
        normalizeCaptureDisplaySelection(shouldPersist: true)
        AppLog.info("Refreshed capture displays count=\(displays.count)", category: .recording)
    }

    public func selectCaptureDisplay(id: String) {
        guard let display = availableCaptureDisplays.first(where: { $0.id == id }) else {
            return
        }
        guard config.videoDeviceIndex != display.id || config.videoDeviceName != display.name else {
            return
        }
        config.videoDeviceIndex = display.id
        config.videoDeviceName = display.name
        persistCaptureDisplaySelection(display, updateStatus: true)
    }

    public func requestInitialPermissions() {
        permissionsService.requestScreenCaptureAccess()
        Task {
            _ = await permissionsService.requestMicrophoneAccess()
            _ = await permissionsService.requestSpeechRecognitionAccess()
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

    public func openSpeechRecognitionSettings() {
        permissionsService.openSpeechRecognitionSettings()
    }

    public func openDictationSettings() {
        permissionsService.openDictationSettings()
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

    public func quitApplication() {
        AppLog.info("Application quit requested", category: .ui)
        ApplicationLifecycleService.quit()
    }

    public func restartApplication() {
        AppLog.info("Application restart requested", category: .ui)
        ApplicationLifecycleService.restart()
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

    public func refreshSpeechLanguageOptions() async {
        guard !isRefreshingSpeechLanguages else {
            return
        }
        isRefreshingSpeechLanguages = true
        let options = await speechAvailabilityService.options()
        availableSpeechLanguageOptions = options
        selectedSpeechLanguageStatus = await speechAvailabilityService.option(for: config)
        isRefreshingSpeechLanguages = false
    }

    public func selectTranscriptionLanguage(_ languageCode: String) {
        config.localTranscriptionLanguage = NativeSpeechDefaults.normalizedLanguageCode(languageCode)
        Task {
            selectedSpeechLanguageStatus = await speechAvailabilityService.option(for: config)
        }
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
        guard !isRecording, !isFinalizingRecording, !isProcessing else {
            return
        }
        refreshPermissions()
        guard Self.hasRequiredPermissions(config: config, permissionState: permissionState) else {
            let missing = missingPermissionNames()
            errorMessage = "Recording blocked. Grant permissions: \(missing)."
            statusMessage = "Recording blocked by macOS permissions"
            showOnboarding = true
            AppLog.warning(
                "Recording blocked by permissions screen=\(permissionState.hasScreenCapture) microphone=\(permissionState.hasMicrophone) speech=\(permissionState.hasSpeechRecognition)",
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
        await refreshCaptureDisplays()

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
            liveTranscriptDocument = nil
            transcriptionErrorMessage = nil
            transcriptionProgress = .idle
            if config.localTranscriptionEnabled {
                let coordinator = ContinuousSpeechCoordinator(
                    baseName: baseName,
                    saveDirectory: saveURL,
                    config: config,
                    onUpdate: { [weak self] document in
                        Task { @MainActor in
                            self?.liveTranscriptDocument = document
                        }
                    },
                    onProgress: { [weak self] progress in
                        Task { @MainActor in
                            self?.transcriptionProgress = progress
                        }
                    }
                )
                try await coordinator.prepare()
                transcriptionCoordinator = coordinator
                isTranscribing = true
                liveTranscriptDocument = TranscriptDocument(
                    baseName: baseName,
                    modelName: NativeSpeechDefaults.engineDisplayName,
                    language: NativeSpeechDefaults.normalizedLanguageCode(config.localTranscriptionLanguage)
                )
            }
            AppLog.info(
                "Recording requested baseName=\(baseName) displayID=\(config.videoDeviceIndex) displayName=\(config.videoDeviceName)",
                category: .recording
            )

            let audioHandler = makeAudioHandler(coordinator: transcriptionCoordinator)

            try await recorder.start(
                outputURL: outputURL,
                preset: config.preset(),
                selectedDisplayID: config.videoDeviceIndex,
                audioHandler: audioHandler
            ) { [weak self] event in
                Task { @MainActor in
                    self?.handleRecorderEvent(event)
                }
            }
            try sessionStore.createInitialMetadata(baseName: baseName, displayName: timestamp.replacingOccurrences(of: "_", with: " "), createdAt: timestamp)
            if config.localTranscriptionEnabled {
                try sessionStore.updateTranscriptionMetadata(
                    baseName: baseName,
                    status: .running,
                    modelName: NativeSpeechDefaults.engineDisplayName,
                    language: NativeSpeechDefaults.normalizedLanguageCode(config.localTranscriptionLanguage),
                    segmentCount: 0
                )
            }
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
            transcriptionCoordinator = nil
            isTranscribing = false
            liveTranscriptDocument = nil
            transcriptionProgress = .idle
            try? FileManager.default.removeItem(at: outputURL)
            currentRecordingBaseName = nil
            currentRecordingURL = nil
            errorMessage = "Start recording failed: \(error.localizedDescription)"
            AppLog.error("Start recording failed: \(error.localizedDescription)", category: .recording)
            refreshSessions()
        }
    }

    public func stopRecording() async {
        guard isRecording, !isFinalizingRecording else {
            return
        }
        recordingTimerTask?.cancel()
        recordingTimerTask = nil
        isRecording = false
        isFinalizingRecording = true
        statusMessage = "Finalizing recording"

        do {
            try await recorder?.stop()
            if let baseName = currentRecordingBaseName, let url = currentRecordingURL {
                if await recordedFileExists(url) {
                    if let transcriptionCoordinator {
                        do {
                            let transcript = try await transcriptionCoordinator.finish()
                            liveTranscriptDocument = transcript
                            try sessionStore.updateTranscriptionMetadata(
                                baseName: baseName,
                                status: .completed,
                                modelName: transcript.modelName,
                                language: transcript.language,
                                segmentCount: transcript.segments.count
                            )
                            AppLog.info("Transcription completed for \(baseName), segments=\(transcript.segments.count)", category: .recording)
                        } catch {
                            handleTranscriptionError(error)
                            try? sessionStore.updateTranscriptionMetadata(
                                baseName: baseName,
                                status: .failed,
                                modelName: NativeSpeechDefaults.engineDisplayName,
                                language: NativeSpeechDefaults.normalizedLanguageCode(config.localTranscriptionLanguage),
                                segmentCount: liveTranscriptDocument?.segments.count ?? 0,
                                error: String(error.localizedDescription.prefix(200))
                            )
                        }
                    }
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
        transcriptionCoordinator = nil
        isTranscribing = false
        isFinalizingRecording = false
        transcriptionProgress = .idle
        currentRecordingBaseName = nil
        currentRecordingURL = nil
        refreshSessions()
    }

    public func checkAIConnection() {
        checkAIConnection(config: config)
    }

    public func checkGeminiConnection(apiKey: String) {
        var snapshotConfig = config
        snapshotConfig.aiProvider = .gemini
        snapshotConfig.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if AIModelCatalog.model(providerID: .gemini, modelID: snapshotConfig.modelName) == nil {
            snapshotConfig.modelName = AIModelCatalog.defaultModelID(for: .gemini)
        }
        checkAIConnection(config: snapshotConfig)
    }

    private func checkAIConnection(config snapshotConfig: AppConfig) {
        guard !isCheckingAIConnection else {
            return
        }

        isCheckingAIConnection = true
        aiConnectionCheckStatus = nil
        errorMessage = nil
        statusMessage = "Checking AI connection"
        let startedAt = Date()
        AppLog.info("AI connection check requested model=\(snapshotConfig.modelName)", category: .ai)
        Task { [weak self] in
            guard let self else {
                return
            }
            do {
                let result = try await self.aiClient.validateConfiguration(config: snapshotConfig)
                let message = "\(result.providerName) connection OK: \(result.modelName)"
                let finishedAt = Date()
                self.statusMessage = message
                self.errorMessage = nil
                self.aiConnectionCheckStatus = AIConnectionCheckStatus(
                    outcome: .success,
                    providerName: result.providerName,
                    providerID: snapshotConfig.aiProvider,
                    baseURL: result.baseURL,
                    modelName: result.modelName,
                    responseText: result.responseText,
                    message: message,
                    checkedAt: finishedAt,
                    durationSeconds: finishedAt.timeIntervalSince(startedAt)
                )
                AppLog.info("AI connection check completed baseURL=\(result.baseURL) model=\(result.modelName)", category: .ai)
            } catch {
                let safeMessage = self.masked(error.localizedDescription, config: snapshotConfig)
                let finishedAt = Date()
                self.statusMessage = "AI connection failed"
                self.aiConnectionCheckStatus = AIConnectionCheckStatus(
                    outcome: .failure,
                    providerName: snapshotConfig.aiProvider.displayName,
                    providerID: snapshotConfig.aiProvider,
                    baseURL: snapshotConfig.baseURL(for: snapshotConfig.aiProvider),
                    modelName: snapshotConfig.modelName,
                    responseText: nil,
                    message: safeMessage,
                    checkedAt: finishedAt,
                    durationSeconds: finishedAt.timeIntervalSince(startedAt)
                )
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
        let processingStartedAt = ISO8601DateFormatter().string(from: Date())
        let processingStartDate = Date()
        let initialReport = ReportInfo(
            agentID: agent.id,
            agentName: agent.name,
            model: snapshotConfig.modelName,
            createdAt: processingStartedAt,
            processingDurationSeconds: 0,
            tokens: ReportTokens(input: 0, output: 0, total: 0),
            outputPath: "",
            status: AIProcessingPhase.preparingMedia(provider: snapshotConfig.aiProvider.displayName).status
        )
        try? sessionStore.upsertReportMetadata(baseName: session.baseName, report: initialReport)
        refreshSessions()

        let progress: AIProgressHandler = { [weak self] phase in
            await MainActor.run {
                guard let self else {
                    return
                }
                self.statusMessage = phase.statusMessage
                let report = ReportInfo(
                    agentID: agent.id,
                    agentName: agent.name,
                    model: snapshotConfig.modelName,
                    createdAt: processingStartedAt,
                    processingDurationSeconds: Int(Date().timeIntervalSince(processingStartDate)),
                    tokens: ReportTokens(input: 0, output: 0, total: 0),
                    outputPath: "",
                    status: phase.status
                )
                try? self.sessionStore.upsertReportMetadata(baseName: session.baseName, report: report)
                self.refreshSessions()
                self.selectedSessionID = session.id
            }
        }

        aiTask = Task { [weak self] in
            guard let self else {
                return
            }
            do {
                let result = try await self.aiClient.generateReport(
                    videoURL: session.videoURL,
                    audioURLs: session.audioURLs,
                    transcript: self.transcriptContext(for: session, config: snapshotConfig),
                    config: snapshotConfig,
                    agent: agent,
                    progress: progress
                )
                await progress(.savingResult(fileName: "\(session.baseName)_protocol_\(agent.id).txt"))
                let outputURL = try self.sessionStore.saveReportText(result.text, baseName: session.baseName, agentID: agent.id)
                var metadata = result.metadata
                metadata.outputFileName = outputURL.lastPathComponent
                metadata.createdAt = processingStartedAt

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
                try self.sessionStore.upsertReportMetadata(baseName: session.baseName, report: report)

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
                let report = ReportInfo(
                    agentID: agent.id,
                    agentName: agent.name,
                    model: snapshotConfig.modelName,
                    createdAt: processingStartedAt,
                    processingDurationSeconds: Int(Date().timeIntervalSince(processingStartDate)),
                    tokens: ReportTokens(input: 0, output: 0, total: 0),
                    outputPath: "",
                    status: "cancelled"
                )
                try? self.sessionStore.upsertReportMetadata(baseName: session.baseName, report: report)
                AppLog.warning("AI processing cancelled", category: .ai)
            } catch {
                let safeMessage = self.masked(error.localizedDescription, config: snapshotConfig)
                let report = ReportInfo(
                    agentID: agent.id,
                    agentName: agent.name,
                    model: snapshotConfig.modelName,
                    createdAt: processingStartedAt,
                    processingDurationSeconds: Int(Date().timeIntervalSince(processingStartDate)),
                    tokens: ReportTokens(input: 0, output: 0, total: 0),
                    outputPath: "",
                    status: "error",
                    error: String(safeMessage.prefix(200))
                )
                try? self.sessionStore.upsertReportMetadata(baseName: session.baseName, report: report)
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

    public func transcriptDocument(for session: MeetingSession) -> TranscriptDocument? {
        if liveTranscriptDocument?.baseName == session.baseName {
            return liveTranscriptDocument
        }
        guard let url = session.transcriptURL else {
            return nil
        }
        return try? sessionStore.loadTranscript(url: url)
    }

    public func loadTranscriptMarkdown(for session: MeetingSession) -> String {
        if let liveTranscriptDocument, liveTranscriptDocument.baseName == session.baseName {
            return liveTranscriptDocument.timestampedMarkdown
        }
        if let url = session.transcriptMarkdownURL,
           let text = try? sessionStore.loadTranscriptMarkdown(url: url) {
            return text
        }
        if let document = transcriptDocument(for: session) {
            return document.timestampedMarkdown
        }
        return ""
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

    private static func migrateTranscriptionDefaultsIfNeeded(_ config: inout AppConfig) -> Bool {
        let previousRevision = config.localTranscriptionDefaultsRevision
        guard previousRevision < NativeSpeechDefaults.currentDefaultsRevision else {
            return false
        }

        config.localTranscriptionModel = NativeSpeechDefaults.engineID
        config.localTranscriptionLanguage = NativeSpeechDefaults.normalizedLanguageCode(config.localTranscriptionLanguage)
        config.localTranscriptionThreadCount = 1
        config.localTranscriptionUseGPU = false
        config.localTranscriptionDefaultsRevision = NativeSpeechDefaults.currentDefaultsRevision
        return true
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
        config.localTranscriptionModel = NativeSpeechDefaults.engineID
        config.localTranscriptionThreadCount = 1
        config.localTranscriptionUseGPU = false
        config.localTranscriptionLanguage = NativeSpeechDefaults.normalizedLanguageCode(config.localTranscriptionLanguage)
        normalizeCaptureDisplaySelection(shouldPersist: false)
        config.localTranscriptionDefaultsRevision = NativeSpeechDefaults.currentDefaultsRevision
    }

    private func normalizeCaptureDisplaySelection(shouldPersist: Bool) {
        guard let display = CaptureDisplaySelection.selectedDisplay(
            configuredID: config.videoDeviceIndex,
            displays: availableCaptureDisplays
        ) else {
            return
        }
        guard config.videoDeviceIndex != display.id || config.videoDeviceName != display.name else {
            return
        }
        config.videoDeviceIndex = display.id
        config.videoDeviceName = display.name
        if shouldPersist {
            persistCaptureDisplaySelection(display, updateStatus: false)
        }
    }

    private func persistCaptureDisplaySelection(_ display: CaptureDisplay, updateStatus: Bool) {
        do {
            try configStore.save(config)
            if updateStatus {
                statusMessage = "Monitor selected: \(display.name)"
            }
            AppLog.info("Selected capture display \(display.name) id=\(display.id)", category: .recording)
        } catch {
            errorMessage = "Monitor selection save failed: \(error.localizedDescription)"
            AppLog.error("Monitor selection save failed: \(error.localizedDescription)", category: .config)
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
            isFinalizingRecording = false
            recordingTimerTask?.cancel()
            recordingTimerTask = nil
            if let baseName = currentRecordingBaseName {
                try? sessionStore.deleteArtifacts(baseName: baseName)
            }
            recorder = nil
            transcriptionCoordinator = nil
            isTranscribing = false
            liveTranscriptDocument = nil
            transcriptionProgress = .idle
            currentRecordingBaseName = nil
            currentRecordingURL = nil
            refreshSessions()
            AppLog.error("Recorder event didFail: \(message)", category: .recording)
        }
    }

    private func handleTranscriptionError(_ error: any Error) {
        transcriptionErrorMessage = error.localizedDescription
        isTranscribing = false
        transcriptionProgress = .idle
        AppLog.warning("Transcription failed: \(error.localizedDescription)", category: .recording)
    }

    private func makeAudioHandler(coordinator: ContinuousSpeechCoordinator?) -> ScreenRecordingService.AudioHandler? {
        guard let coordinator else {
            return nil
        }
        return { [weak self] chunk in
            Task {
                do {
                    try await coordinator.accept(chunk)
                } catch {
                    await MainActor.run {
                        self?.handleTranscriptionError(error)
                    }
                }
            }
        }
    }

    private func transcriptContext(for session: MeetingSession, config: AppConfig) -> AITranscriptContext? {
        guard config.attachTranscriptToAI else {
            return nil
        }

        let text = loadTranscriptMarkdown(for: session).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return nil
        }
        return AITranscriptContext(
            text: text,
            fileName: session.transcriptMarkdownURL?.lastPathComponent ?? "\(session.baseName)_transcript.md"
        )
    }

    private func missingPermissionNames() -> String {
        var names: [String] = []
        if !permissionState.hasScreenCapture {
            names.append("Screen Recording")
        }
        if !permissionState.hasMicrophone {
            names.append("Microphone")
        }
        if config.localTranscriptionEnabled, !permissionState.hasSpeechRecognition {
            names.append("Speech Recognition")
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
