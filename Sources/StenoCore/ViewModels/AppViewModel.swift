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
    public var folders: [RecordingFolder] = []
    public var selectedSessionID: MeetingSession.ID?
    public var selectedReportID: String?
    public var selectedTabID: String = "player"
    public var isRecording = false
    public var isFinalizingRecording = false
    public var isProcessing = false
    public var isCheckingAIConnection = false
    public var recordingDuration = 0
    public var recordingRemainingDuration: Int?
    public var statusMessage: String?
    public var errorMessage: String?
    public var aiConnectionCheckStatus: AIConnectionCheckStatus?
    public var availableAIModels: [AIModelReference] = AIModelCatalog.fallbackModels
    public var availableCaptureDisplays: [CaptureDisplay] = []
    public var isRefreshingAIModels = false
    public var showOnboarding = false
    public var showSettings = false
    public var permissionState = PermissionState(hasScreenCapture: false, hasMicrophone: false)
    public var microphoneInputVolumeState = SystemInputVolumeState()
    public var chatThread: ChatThread?
    public var isSendingChatMessage = false
    public var remoteMediaAvailability: RemoteMediaAvailability = .notUploaded
    public var geminiUsageSnapshot: GeminiUsageSnapshot?
    public var isImportingRecording = false

    @ObservationIgnored private let configStore: ConfigStore
    @ObservationIgnored private var sessionStore = SessionStore(saveDirectory: URL(fileURLWithPath: AppConfig.default.saveDirectory))
    @ObservationIgnored private let permissionsService: PermissionsService
    @ObservationIgnored private let captureDisplayService: CaptureDisplayService
    @ObservationIgnored private let aiClient: AIProcessingClient
    @ObservationIgnored private let modelCatalogService: AIModelCatalogService
    @ObservationIgnored private let inputVolumeService: SystemInputVolumeService
    @ObservationIgnored private let importService: RecordingImportService
    @ObservationIgnored private let remoteCleanupStore: RemoteCleanupStore
    @ObservationIgnored private var recorder: ScreenRecordingService?
    @ObservationIgnored private var segmentedRecorder: SegmentedScreenRecordingService?
    @ObservationIgnored private var recordingTimerTask: Task<Void, Never>?
    @ObservationIgnored private var aiTask: Task<Void, Never>?
    @ObservationIgnored private var chatTask: Task<Void, Never>?
    @ObservationIgnored private var currentRecordingBaseName: String?
    @ObservationIgnored private var currentRecordingURL: URL?
    @ObservationIgnored private var currentRecordingSegments: [RecordingSegment] = []
    @ObservationIgnored private var activeRecordingLimitProfile: SegmentedRecordingLimitProfile?
    @ObservationIgnored private var shouldQuitAfterRecordingFinalizes = false

    public init(
        configStore: ConfigStore = ConfigStore(),
        permissionsService: PermissionsService = PermissionsService(),
        captureDisplayService: CaptureDisplayService = CaptureDisplayService(),
        aiClient: AIProcessingClient = AIProcessingClient(),
        modelCatalogService: AIModelCatalogService = AIModelCatalogService(),
        inputVolumeService: SystemInputVolumeService = SystemInputVolumeService(),
        importService: RecordingImportService = RecordingImportService(),
        remoteCleanupStore: RemoteCleanupStore = RemoteCleanupStore()
    ) {
        self.configStore = configStore
        self.permissionsService = permissionsService
        self.captureDisplayService = captureDisplayService
        self.aiClient = aiClient
        self.modelCatalogService = modelCatalogService
        self.inputVolumeService = inputVolumeService
        self.importService = importService
        self.remoteCleanupStore = remoteCleanupStore

        var loadedConfig = AppConfig.default
        var didFindExistingConfig = false
        var initialStatus: String?
        var initialError: String?

        do {
            let loadResult = try configStore.load()
            loadedConfig = loadResult.config
            didFindExistingConfig = loadResult.didFindExistingConfig
            if loadResult.didMigrateLegacyConfig {
                initialStatus = "Legacy config migrated to ~/.steno/config.json"
            }
        } catch {
            loadedConfig = .default
            didFindExistingConfig = false
            initialError = "Config load failed: \(error.localizedDescription)"
        }

        let normalizedModel = AIModelCatalog.normalizedModelID(loadedConfig.modelName)
        if !ProviderAvailability.isActive(loadedConfig.aiProvider) ||
            AIModelCatalog.model(providerID: .gemini, modelID: normalizedModel) == nil {
            loadedConfig.aiProvider = .gemini
            loadedConfig.modelName = AIModelCatalog.defaultModelID(for: .gemini)
            try? configStore.save(loadedConfig)
        } else if normalizedModel != loadedConfig.modelName {
            loadedConfig.modelName = normalizedModel
            try? configStore.save(loadedConfig)
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
            await refreshGeminiUsage()
            await processRemoteCleanupQueue()
        }
        inputVolumeService.startMonitoring { [weak self] state in
            self?.microphoneInputVolumeState = state
        }
        AppLog.info("AppViewModel initialized; onboarding=\(showOnboarding)", category: .app)
    }

    deinit {
        recordingTimerTask?.cancel()
        aiTask?.cancel()
        chatTask?.cancel()
        inputVolumeService.stopMonitoring()
    }

    public var selectedSession: MeetingSession? {
        sessions.first { $0.id == selectedSessionID }
    }

    public var selectedReport: ReportInfo? {
        guard let selectedReportID else { return nil }
        return selectedSession?.metadata.reports?.first { $0.id == selectedReportID }
    }

    public var recordingAudioState: RecordingAudioState {
        RecordingAudioState(
            microphoneEnabled: config.microphoneEnabled,
            systemAudioEnabled: config.systemAudioEnabled
        )
    }

    public var activeAgent: Agent? {
        config.activeAgent ?? config.agents.first
    }

    public var shouldShowCaptureDisplayPicker: Bool {
        availableCaptureDisplays.count > 1
    }

    public var canGenerate: Bool {
        selectedSession != nil && !isProcessing && !isSendingChatMessage && !isRecording && !isFinalizingRecording
    }

    public var geminiRetryBlockedUntil: Date? {
        geminiUsageSnapshot?.blockedUntil.flatMap { $0 > Date() ? $0 : nil }
    }

    public var recordingCommandTitle: String {
        if isFinalizingRecording {
            return "Finalizing Recording..."
        }
        return isRecording ? "Stop Recording" : "Start Recording"
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
            permissionState.hasMicrophone
    }

    public func refreshPermissions() {
        permissionState = permissionsService.currentState()
        if !Self.hasRequiredPermissions(config: config, permissionState: permissionState) {
            showOnboarding = true
        }
        AppLog.info(
            "Refreshed permissions screen=\(permissionState.hasScreenCapture) microphone=\(permissionState.hasMicrophone)",
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

    public func setMicrophoneInputVolume(_ volume: Double) {
        let clamped = min(1, max(0, volume))
        microphoneInputVolumeState.volume = clamped
        do {
            try inputVolumeService.setVolume(clamped)
            microphoneInputVolumeState = inputVolumeService.currentState()
            AppLog.info(
                "System microphone input volume set to \(String(format: "%.2f", clamped))",
                category: .config
            )
        } catch {
            microphoneInputVolumeState = inputVolumeService.currentState()
            errorMessage = error.localizedDescription
            AppLog.warning("System microphone input volume update failed: \(error.localizedDescription)", category: .config)
        }
    }

    public func toggleMicrophoneCapture() {
        config.microphoneEnabled.toggle()
        recorder?.setMicrophoneEnabled(config.microphoneEnabled)
        segmentedRecorder?.setMicrophoneEnabled(config.microphoneEnabled)
        persistAudioCaptureState()
    }

    public func toggleSystemAudioCapture() {
        config.systemAudioEnabled.toggle()
        recorder?.setSystemAudioEnabled(config.systemAudioEnabled)
        segmentedRecorder?.setSystemAudioEnabled(config.systemAudioEnabled)
        persistAudioCaptureState()
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
        if isRecording || isFinalizingRecording {
            shouldQuitAfterRecordingFinalizes = true
            statusMessage = "Finalizing recording before quit"
            if isRecording {
                Task { [weak self] in
                    await self?.stopRecording(reason: .user)
                }
            }
            return
        }
        ApplicationLifecycleService.quit()
    }

    public func restartApplication() {
        AppLog.info("Application restart requested", category: .ui)
        ApplicationLifecycleService.restart()
    }

    public func selectAIProvider(_ providerID: String) {
        guard let provider = AIProviderID(rawValue: providerID), ProviderAvailability.isActive(provider) else {
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
        AppLog.info("Refreshing active Gemini alias catalog", category: .ai)
        availableAIModels = AIModelCatalog.providerModels(.gemini)
        if !availableAIModels.contains(where: { $0.providerID == config.aiProvider && $0.modelID == config.modelName }) {
            config.modelName = modelsForSelectedProvider.first?.modelID ?? AIModelCatalog.defaultModelID(for: config.aiProvider)
        }
        statusMessage = "Gemini model aliases refreshed"
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
        folders = sessionStore.loadFolders()
        if selectedSessionID == nil || !sessions.contains(where: { $0.id == selectedSessionID }) {
            selectedSessionID = sessions.first?.id
        }
        synchronizeSelectedReport()
        updateRemoteMediaAvailability()
        AppLog.debug("Refreshed sessions count=\(sessions.count)", category: .sessions)
    }

    public func select(_ session: MeetingSession) {
        selectedSessionID = session.id
        selectedReportID = session.availableReports.first?.id
        selectedTabID = selectedReportID == nil ? "player" : "reports"
        synchronizeSelectedReport()
        updateRemoteMediaAvailability()
        AppLog.info("Selected session \(session.baseName)", category: .ui)
    }

    public func selectReport(id: String) {
        guard selectedSession?.metadata.reports?.contains(where: { $0.id == id }) == true else { return }
        selectedReportID = id
        synchronizeSelectedReport()
    }

    public func createFolder(name: String) {
        do {
            _ = try sessionStore.createFolder(name: name)
            refreshSessions()
        } catch {
            errorMessage = "Folder creation failed: \(error.localizedDescription)"
        }
    }

    public func renameFolder(id: String, to name: String) {
        do {
            try sessionStore.renameFolder(id: id, to: name)
            refreshSessions()
        } catch {
            errorMessage = "Folder rename failed: \(error.localizedDescription)"
        }
    }

    public func moveSession(id: String, toFolderID folderID: String?) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        do {
            try sessionStore.move(session: session, toFolderID: folderID)
            refreshSessions()
            selectedSessionID = id
        } catch {
            errorMessage = "Move failed: \(error.localizedDescription)"
        }
    }

    public func deleteFolder(id: String, deleteRecordings: Bool) {
        let affected = sessions.filter { $0.metadata.folderID == id }
        if !deleteRecordings {
            do {
                try sessionStore.deleteFolder(id: id, moveSessionsToRoot: true)
                refreshSessions()
            } catch {
                errorMessage = "Folder deletion failed: \(error.localizedDescription)"
            }
            return
        }
        Task { [weak self] in
            guard let self else { return }
            for session in affected {
                await self.deleteSession(session)
            }
            do {
                try self.sessionStore.deleteFolder(id: id, moveSessionsToRoot: false)
                self.refreshSessions()
            } catch {
                self.errorMessage = "Folder deletion failed: \(error.localizedDescription)"
            }
        }
    }

    public func importRecording(from sourceURL: URL, folderID: String?) async {
        guard !isRecording, !isFinalizingRecording, !isProcessing, !isImportingRecording else { return }
        isImportingRecording = true
        statusMessage = "Importing \(sourceURL.lastPathComponent)"
        defer { isImportingRecording = false }
        do {
            let imported = try await importService.importVideo(
                from: sourceURL,
                saveDirectory: URL(fileURLWithPath: config.saveDirectory)
            )
            let createdAt = ISO8601DateFormatter().string(from: Date())
            try sessionStore.createInitialMetadata(
                baseName: imported.baseName,
                displayName: imported.displayName,
                createdAt: createdAt,
                folderID: folderID,
                source: .imported
            )
            try sessionStore.updateRecordingMetadata(
                baseName: imported.baseName,
                duration: imported.durationSeconds,
                quality: "Imported",
                videoURL: imported.videoURL
            )
            refreshSessions()
            selectedSessionID = imported.baseName
            selectedTabID = "player"
            statusMessage = "Recording imported"
        } catch {
            errorMessage = "Import failed: \(error.localizedDescription)"
            AppLog.error("Import failed: \(error.localizedDescription)", category: .sessions)
        }
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
        Task { [weak self] in
            await self?.deleteSession(session)
        }
    }

    private func deleteSession(_ session: MeetingSession) async {
        do {
            if let manifest = session.metadata.remoteMedia {
                try await remoteCleanupStore.enqueue(manifest)
            }
            try sessionStore.delete(session: session)
            refreshSessions()
            await processRemoteCleanupQueue()
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
        await refreshCaptureDisplays()

        let saveURL = URL(fileURLWithPath: config.saveDirectory)
        let identity = uniqueRecordingIdentity(in: saveURL)
        let timestamp = identity.timestamp
        let baseName = identity.baseName
        let outputURL = saveURL.appending(path: "\(baseName).mp4")
        let usesSegmentedRecording = config.experimentalSegmentedRecordingEnabled
        let limitProfile = config.segmentedRecordingLimitProfile

        do {
            try FileManager.default.createDirectory(at: saveURL, withIntermediateDirectories: true)
            currentRecordingBaseName = baseName
            currentRecordingURL = usesSegmentedRecording
                ? saveURL.appending(path: "\(baseName)_part_000.mp4")
                : outputURL
            currentRecordingSegments = []
            activeRecordingLimitProfile = usesSegmentedRecording ? limitProfile : nil
            recordingDuration = 0
            recordingRemainingDuration = usesSegmentedRecording ? limitProfile.maximumDurationSeconds : nil
            AppLog.info(
                "Recording requested baseName=\(baseName) segmented=\(usesSegmentedRecording) displayID=\(config.videoDeviceIndex) displayName=\(config.videoDeviceName)",
                category: .recording
            )
            try sessionStore.createInitialMetadata(
                baseName: baseName,
                displayName: timestamp.replacingOccurrences(of: "_", with: " "),
                createdAt: timestamp,
                folderID: nil,
                source: .captured
            )
            if usesSegmentedRecording {
                let segmentedRecorder = SegmentedScreenRecordingService()
                self.segmentedRecorder = segmentedRecorder
                try await segmentedRecorder.start(
                    outputDirectory: saveURL,
                    baseName: baseName,
                    preset: config.preset(),
                    profile: limitProfile,
                    selectedDisplayID: config.videoDeviceIndex,
                    audioState: recordingAudioState
                ) { [weak self] event in
                    Task { @MainActor in
                        self?.handleSegmentedRecorderEvent(event)
                    }
                }
            } else {
                let recorder = ScreenRecordingService()
                self.recorder = recorder
                try await recorder.start(
                    outputURL: outputURL,
                    preset: config.preset(),
                    selectedDisplayID: config.videoDeviceIndex,
                    audioState: recordingAudioState
                ) { [weak self] event in
                    Task { @MainActor in
                        self?.handleRecorderEvent(event)
                    }
                }
            }
            isRecording = true
            statusMessage = usesSegmentedRecording
                ? "Segmented recording started · \(limitProfile.settingsTitle)"
                : "Legacy recording started"
            startRecordingTimer()
        } catch {
            recordingTimerTask?.cancel()
            recordingTimerTask = nil
            if let recorder {
                try? await recorder.stop()
            }
            if let segmentedRecorder {
                _ = try? await segmentedRecorder.stop(reason: .failure)
            }
            isRecording = false
            recorder = nil
            segmentedRecorder = nil
            try? sessionStore.deleteArtifacts(baseName: baseName)
            currentRecordingBaseName = nil
            currentRecordingURL = nil
            currentRecordingSegments = []
            activeRecordingLimitProfile = nil
            recordingRemainingDuration = nil
            errorMessage = "Start recording failed: \(error.localizedDescription)"
            AppLog.error("Start recording failed: \(error.localizedDescription)", category: .recording)
            refreshSessions()
        }
    }

    public func stopRecording() async {
        await stopRecording(reason: .user)
    }

    private func stopRecording(reason: RecordingStopReason) async {
        guard isRecording, !isFinalizingRecording else {
            return
        }
        recordingTimerTask?.cancel()
        recordingTimerTask = nil
        isRecording = false
        isFinalizingRecording = true
        statusMessage = "Finalizing recording"

        do {
            if let segmentedRecorder,
               let baseName = currentRecordingBaseName,
               let profile = activeRecordingLimitProfile {
                let result = try await segmentedRecorder.stop(reason: reason)
                currentRecordingSegments = result.segments
                guard !result.segments.isEmpty else {
                    throw RecordingError.recordingFailed("Segmented recorder returned no completed parts.")
                }
                try sessionStore.updateSegmentedRecordingMetadata(
                    baseName: baseName,
                    update: SegmentedRecordingMetadataUpdate(
                        duration: Int(result.durationSeconds.rounded()),
                        quality: config.videoQuality,
                        profile: profile,
                        stopReason: result.stopReason,
                        segments: result.segments
                    )
                )
                recordingDuration = Int(result.durationSeconds.rounded())
            } else {
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
            }
            statusMessage = reason == .user ? "Recording stopped" : "Recording stopped at configured limit"
            if reason != .failure {
                errorMessage = nil
            }
            AppLog.info("Recording stop completed reason=\(reason.rawValue)", category: .recording)
        } catch {
            if let baseName = currentRecordingBaseName,
               let profile = activeRecordingLimitProfile,
               !currentRecordingSegments.isEmpty {
                try? sessionStore.updateSegmentedRecordingMetadata(
                    baseName: baseName,
                    update: SegmentedRecordingMetadataUpdate(
                        duration: recordingDuration,
                        quality: config.videoQuality,
                        profile: profile,
                        stopReason: .failure,
                        segments: currentRecordingSegments
                    )
                )
            }
            errorMessage = "Stop recording failed: \(error.localizedDescription)"
            AppLog.error("Stop recording failed: \(error.localizedDescription)", category: .recording)
        }

        recorder = nil
        segmentedRecorder = nil
        isFinalizingRecording = false
        currentRecordingBaseName = nil
        currentRecordingURL = nil
        currentRecordingSegments = []
        activeRecordingLimitProfile = nil
        recordingRemainingDuration = nil
        refreshSessions()
        if shouldQuitAfterRecordingFinalizes {
            shouldQuitAfterRecordingFinalizes = false
            ApplicationLifecycleService.quit()
        }
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
                await self.refreshGeminiUsage()
                await self.processRemoteCleanupQueue()
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
        if let blockedUntil = geminiRetryBlockedUntil {
            errorMessage = "Gemini quota is temporarily exhausted. Retry after \(blockedUntil.formatted(date: .omitted, time: .standard))."
            return
        }

        isProcessing = true
        errorMessage = nil
        statusMessage = "AI processing started"
        AppLog.info("AI processing requested session=\(session.baseName) agent=\(agent.id)", category: .ai)

        let snapshotConfig = config
        let reportID = UUID().uuidString
        let processingStartedAt = ISO8601DateFormatter().string(from: Date())
        let processingStartDate = Date()
        let initialReport = ReportInfo(
            id: reportID,
            agentID: agent.id,
            agentName: agent.name,
            model: snapshotConfig.modelName,
            providerID: AIProviderID.gemini.rawValue,
            promptSnapshot: agent.prompt,
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
                    id: reportID,
                    agentID: agent.id,
                    agentName: agent.name,
                    model: snapshotConfig.modelName,
                    providerID: AIProviderID.gemini.rawValue,
                    promptSnapshot: agent.prompt,
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
                    recordingSegments: session.isSegmentedRecording ? session.recordingSegments : [],
                    mediaDirectory: session.isSegmentedRecording ? session.baseURL.deletingLastPathComponent() : nil,
                    useLowMediaResolution: session.segmentedLimitProfile?.usesLowAIMediaResolution ?? false,
                    config: snapshotConfig,
                    agent: agent,
                    existingRemoteMedia: session.metadata.remoteMedia,
                    remoteMediaUpdate: { manifest in
                        let store = SessionStore(saveDirectory: session.baseURL.deletingLastPathComponent())
                        try? store.updateRemoteMedia(baseName: session.baseName, manifest: manifest)
                    },
                    progress: progress
                )
                await progress(.savingResult(fileName: "\(session.baseName)_protocol_\(agent.id)_\(reportID).txt"))
                let outputURL = try self.sessionStore.saveReportText(
                    result.text,
                    baseName: session.baseName,
                    agentID: agent.id,
                    reportID: reportID
                )
                var metadata = result.metadata
                metadata.outputFileName = outputURL.lastPathComponent
                metadata.createdAt = processingStartedAt

                let report = ReportInfo(
                    id: reportID,
                    agentID: agent.id,
                    agentName: metadata.agentName,
                    model: metadata.model,
                    modelVersion: metadata.modelVersion,
                    providerID: AIProviderID.gemini.rawValue,
                    promptSnapshot: agent.prompt,
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
                self.selectedReportID = reportID
                self.selectedTabID = "reports"
                self.synchronizeSelectedReport()
                await self.refreshGeminiUsage()
                self.statusMessage = "Протокол сохранен: \(metadata.outputFileName)"
                AppLog.info("AI processing completed session=\(session.baseName) tokens=\(metadata.tokensTotal)", category: .ai)
            } catch is CancellationError {
                self.statusMessage = "AI processing cancelled"
                let report = ReportInfo(
                    id: reportID,
                    agentID: agent.id,
                    agentName: agent.name,
                    model: snapshotConfig.modelName,
                    providerID: AIProviderID.gemini.rawValue,
                    promptSnapshot: agent.prompt,
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
                    id: reportID,
                    agentID: agent.id,
                    agentName: agent.name,
                    model: snapshotConfig.modelName,
                    providerID: AIProviderID.gemini.rawValue,
                    promptSnapshot: agent.prompt,
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

    public func loadReportText(reportID: String) -> String {
        guard let session = selectedSession else { return "" }
        guard let url = session.reportURLsByReportID[reportID] else { return "" }
        return (try? sessionStore.loadReportText(url: url)) ?? ""
    }

    public func copyReport(agentID: String) {
        let text = loadReportText(agentID: agentID)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusMessage = "Copied"
        AppLog.info("Copied report for agent=\(agentID)", category: .ui)
    }

    public func copySelectedReport() {
        guard let selectedReportID else { return }
        let text = loadReportText(reportID: selectedReportID)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusMessage = "Copied"
    }

    @discardableResult
    public func saveSelectedReport(_ text: String) -> Bool {
        guard let session = selectedSession,
              let reportID = selectedReportID,
              let url = session.reportURLsByReportID[reportID] else {
            errorMessage = "Не удалось найти файл выбранного протокола."
            return false
        }

        do {
            try sessionStore.overwriteReportText(text, url: url)
            statusMessage = "Протокол сохранён"
            AppLog.info("Updated report id=\(reportID)", category: .ui)
            return true
        } catch {
            errorMessage = "Не удалось сохранить протокол: \(error.localizedDescription)"
            AppLog.error("Report update failed: \(error.localizedDescription)", category: .sessions)
            return false
        }
    }

    public func sendChatMessage(_ rawQuestion: String) {
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty,
              !isSendingChatMessage,
              let session = selectedSession,
              let report = selectedReport else { return }
        if let blockedUntil = geminiRetryBlockedUntil {
            errorMessage = "Gemini quota is temporarily exhausted. Retry after \(blockedUntil.formatted(date: .omitted, time: .standard))."
            return
        }
        var snapshotConfig = config
        snapshotConfig.aiProvider = .gemini
        let normalizedReportModel = AIModelCatalog.normalizedModelID(report.model)
        snapshotConfig.modelName = AIModelCatalog.model(providerID: .gemini, modelID: normalizedReportModel) == nil
            ? AIModelCatalog.defaultModelID(for: .gemini)
            : normalizedReportModel
        let previousThread = chatThread ?? sessionStore.loadChat(
            baseName: session.baseName,
            reportID: report.id,
            modelAlias: snapshotConfig.modelName
        )
        let userMessage = ChatMessage(role: .user, text: question, status: .sending)
        var visibleThread = previousThread
        visibleThread.messages.append(userMessage)
        visibleThread.updatedAt = Date()
        chatThread = visibleThread
        try? sessionStore.saveChat(visibleThread, baseName: session.baseName)
        isSendingChatMessage = true
        errorMessage = nil

        let progress: AIProgressHandler = { [weak self] phase in
            await MainActor.run {
                guard let self else { return }
                self.statusMessage = phase.statusMessage
                if case let .uploadingMedia(_, _, fileIndex, totalFiles, _) = phase {
                    self.remoteMediaAvailability = .uploading(current: fileIndex, total: totalFiles)
                }
            }
        }
        chatTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.aiClient.sendChatMessage(
                    request: GeminiChatRequest(
                        videoURL: session.videoURL,
                        audioURLs: session.audioURLs,
                        report: report,
                        reportText: self.loadReportText(reportID: report.id),
                        thread: previousThread,
                        question: question,
                        config: snapshotConfig,
                        existingRemoteMedia: session.metadata.remoteMedia,
                        recordingSegments: session.isSegmentedRecording ? session.recordingSegments : [],
                        mediaDirectory: session.isSegmentedRecording ? session.baseURL.deletingLastPathComponent() : nil,
                        useLowMediaResolution: session.segmentedLimitProfile?.usesLowAIMediaResolution ?? false
                    ),
                    remoteMediaUpdate: { manifest in
                        let store = SessionStore(saveDirectory: session.baseURL.deletingLastPathComponent())
                        try? store.updateRemoteMedia(baseName: session.baseName, manifest: manifest)
                    },
                    progress: progress
                )
                var completed = self.chatThread ?? visibleThread
                if let index = completed.messages.firstIndex(where: { $0.id == userMessage.id }) {
                    completed.messages[index].status = .sent
                }
                completed.messages.append(
                    ChatMessage(role: .model, text: result.text, status: .sent, tokens: result.tokens)
                )
                completed.historySummary = result.historySummary
                completed.summarizedMessageCount = result.summarizedMessageCount
                completed.updatedAt = Date()
                self.chatThread = completed
                try self.sessionStore.saveChat(completed, baseName: session.baseName)
                self.config.usedTokens += result.tokens.total
                self.config.lastRequestTokens = result.tokens.total
                self.saveConfig()
                self.refreshSessions()
                self.selectedSessionID = session.id
                self.selectedReportID = report.id
                self.synchronizeSelectedReport()
                await self.refreshGeminiUsage()
                self.statusMessage = "Chat response received"
            } catch is CancellationError {
                self.statusMessage = "Chat request cancelled"
                var cancelled = self.chatThread ?? visibleThread
                if let index = cancelled.messages.firstIndex(where: { $0.id == userMessage.id }) {
                    cancelled.messages[index].status = .failed
                    cancelled.messages[index].error = "Запрос отменен"
                }
                self.chatThread = cancelled
                try? self.sessionStore.saveChat(cancelled, baseName: session.baseName)
            } catch {
                var failed = self.chatThread ?? visibleThread
                if let index = failed.messages.firstIndex(where: { $0.id == userMessage.id }) {
                    failed.messages[index].status = .failed
                    failed.messages[index].error = self.masked(error.localizedDescription, config: snapshotConfig)
                }
                self.chatThread = failed
                try? self.sessionStore.saveChat(failed, baseName: session.baseName)
                self.refreshSessions()
                self.selectedSessionID = session.id
                self.selectedReportID = report.id
                self.synchronizeSelectedReport()
                self.updateRemoteMediaAvailability()
                if case .notUploaded = self.remoteMediaAvailability {
                    self.remoteMediaAvailability = .failed(self.masked(error.localizedDescription, config: snapshotConfig))
                }
                self.errorMessage = "Chat error: \(self.masked(error.localizedDescription, config: snapshotConfig))"
                await self.refreshGeminiUsage()
            }
            self.isSendingChatMessage = false
        }
    }

    public func cancelChatMessage() {
        chatTask?.cancel()
        chatTask = nil
        isSendingChatMessage = false
    }

    public func retryChatMessage(id: String) {
        guard var thread = chatThread,
              let index = thread.messages.firstIndex(where: { $0.id == id && $0.role == .user }) else { return }
        let text = thread.messages[index].text
        thread.messages.remove(at: index)
        chatThread = thread
        if let session = selectedSession {
            try? sessionStore.saveChat(thread, baseName: session.baseName)
        }
        sendChatMessage(text)
    }

    public func openOutputFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: config.saveDirectory))
        AppLog.info("Opened output folder", category: .ui)
    }

    public func refreshGeminiUsage() async {
        geminiUsageSnapshot = await aiClient.usageSnapshot(apiKey: config.apiKey)
    }

    private func processRemoteCleanupQueue() async {
        try? await remoteCleanupStore.discardExpired()
        let entries = await remoteCleanupStore.pending(config: config)
        for entry in entries {
            guard await aiClient.deleteRemoteMedia(entry.manifest, config: config) else { continue }
            try? await remoteCleanupStore.markCompleted(id: entry.id)
        }
    }

    private func synchronizeSelectedReport() {
        guard let session = selectedSession else {
            selectedReportID = nil
            chatThread = nil
            return
        }
        let reports = session.availableReports
        if selectedReportID == nil || !reports.contains(where: { $0.id == selectedReportID }) {
            selectedReportID = reports.first?.id
        }
        guard let report = selectedReport else {
            chatThread = nil
            return
        }
        if chatThread?.reportID != report.id {
            chatThread = sessionStore.loadChat(
                baseName: session.baseName,
                reportID: report.id,
                modelAlias: chatModelAlias(for: report)
            )
        }
    }

    private func chatModelAlias(for report: ReportInfo) -> String {
        let normalized = AIModelCatalog.normalizedModelID(report.model)
        return AIModelCatalog.model(providerID: .gemini, modelID: normalized) == nil
            ? AIModelCatalog.defaultModelID(for: .gemini)
            : normalized
    }

    private func updateRemoteMediaAvailability(now: Date = Date()) {
        guard let manifest = selectedSession?.metadata.remoteMedia,
              manifest.isReadyForUse,
              let expiration = manifest.earliestExpiration else {
            remoteMediaAvailability = .notUploaded
            return
        }
        remoteMediaAvailability = expiration.timeIntervalSince(now) > 300
            ? .available(until: expiration)
            : .expired
    }

    private func normalizeConfig() {
        if AIProviderID(rawValue: config.aiProviderID) == nil || !ProviderAvailability.isActive(config.aiProvider) {
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
        if SegmentedRecordingLimitProfile(rawValue: config.segmentedRecordingLimitProfileID) == nil {
            config.segmentedRecordingLimitProfile = .standard
        }
        normalizeCaptureDisplaySelection(shouldPersist: false)
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

    private func persistAudioCaptureState() {
        do {
            try configStore.save(config)
            statusMessage = "Audio sources updated"
        } catch {
            errorMessage = "Audio source setting failed: \(error.localizedDescription)"
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
                    guard let self else { return }
                    self.recordingDuration += 1
                    if let profile = self.activeRecordingLimitProfile {
                        self.recordingRemainingDuration = max(0, profile.maximumDurationSeconds - self.recordingDuration)
                        if self.recordingDuration >= profile.maximumDurationSeconds {
                            Task { await self.stopRecording(reason: .durationLimit) }
                        }
                    }
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
            isFinalizingRecording = true
            recordingTimerTask?.cancel()
            recordingTimerTask = nil
            let failedRecorder = recorder
            Task { [weak self] in
                do {
                    try await failedRecorder?.stop()
                } catch {
                    self?.errorMessage = error.localizedDescription
                }
                self?.recorder = nil
                self?.isFinalizingRecording = false
                self?.currentRecordingBaseName = nil
                self?.currentRecordingURL = nil
                self?.refreshSessions()
            }
            AppLog.error("Recorder event didFail: \(message)", category: .recording)
        }
    }

    private func handleSegmentedRecorderEvent(_ event: SegmentedRecorderEvent) {
        switch event {
        case .didStart:
            isRecording = true
            AppLog.info("Segmented recorder event didStart", category: .recording)
        case let .didFinalizeSegment(segment):
            currentRecordingSegments.removeAll { $0.index == segment.index }
            currentRecordingSegments.append(segment)
            currentRecordingSegments.sort { $0.index < $1.index }
            if let baseName = currentRecordingBaseName, let profile = activeRecordingLimitProfile {
                try? sessionStore.updateSegmentedRecordingMetadata(
                    baseName: baseName,
                    update: SegmentedRecordingMetadataUpdate(
                        duration: recordingDuration,
                        quality: config.videoQuality,
                        profile: profile,
                        stopReason: nil,
                        segments: currentRecordingSegments
                    )
                )
            }
            AppLog.info("Segment finalized index=\(segment.index)", category: .recording)
        case let .didReachLimit(reason):
            AppLog.info("Segmented recording reached limit reason=\(reason.rawValue)", category: .recording)
            Task { [weak self] in
                await self?.stopRecording(reason: reason)
            }
        case let .didFail(message):
            errorMessage = "Recording failed: \(message)"
            AppLog.error("Segmented recorder failed: \(message)", category: .recording)
            Task { [weak self] in
                await self?.stopRecording(reason: .failure)
            }
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

    private func uniqueRecordingIdentity(in directory: URL) -> (baseName: String, timestamp: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy_HH:mm:ss"
        var date = Date()
        while true {
            let timestamp = formatter.string(from: date)
            let baseName = "Meet_\(timestamp)"
            let videoURL = directory.appending(path: "\(baseName).mp4")
            let firstSegmentURL = directory.appending(path: "\(baseName)_part_000.mp4")
            let metadataURL = directory.appending(path: "\(baseName).json")
            if !FileManager.default.fileExists(atPath: videoURL.path),
               !FileManager.default.fileExists(atPath: firstSegmentURL.path),
               !FileManager.default.fileExists(atPath: metadataURL.path) {
                return (baseName, timestamp)
            }
            date.addTimeInterval(1)
        }
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
