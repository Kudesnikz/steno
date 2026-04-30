import AppKit
import SwiftUI

public struct SettingsView: View {
    @Bindable private var viewModel: AppViewModel
    @State private var selectedAgentID: String?
    @State private var isConnectionStatusPopoverPresented = false

    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        _selectedAgentID = State(initialValue: viewModel.config.activeAgentID)
    }

    public var body: some View {
        VStack(spacing: 0) {
            TabView {
                generalTab
                    .tabItem { Text("Общие") }
                transcriptionTab
                    .tabItem { Text("Транскрибация") }
                agentsTab
                    .tabItem { Text("Агенты") }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                Link("Version 0.2.0-native", destination: AppLinks.repository)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Open Steno on GitHub")
                Spacer()
                Button("Cancel") {
                    viewModel.showSettings = false
                }
                Button("Save") {
                    viewModel.saveConfig()
                    viewModel.showSettings = false
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
    }

    private var generalTab: some View {
        Form {
            Section("AI") {
                Picker("Провайдер", selection: $viewModel.config.aiProviderID) {
                    ForEach(AIProviderID.allCases) { provider in
                        Text(provider.displayName).tag(provider.rawValue)
                    }
                }
                .onChange(of: viewModel.config.aiProviderID) { _, newValue in
                    viewModel.selectAIProvider(newValue)
                }

                Picker("Модель", selection: $viewModel.config.modelName) {
                    if viewModel.modelsForSelectedProvider.isEmpty {
                        Text("Нет подтвержденных video-моделей").tag(viewModel.config.modelName)
                    } else {
                        ForEach(viewModel.modelsForSelectedProvider) { model in
                            Text(modelPickerTitle(model)).tag(model.modelID)
                        }
                    }
                }
                LabeledContent("Статус каталога") {
                    Text(viewModel.modelsForSelectedProvider.contains { $0.isDynamicallyVerified } ? "dynamic video-verified" : "documented allowlist")
                        .foregroundStyle(.secondary)
                }
                providerCredentialsFields
                HStack {
                    Button {
                        Task {
                            await viewModel.refreshAIModels()
                        }
                    } label: {
                        if viewModel.isRefreshingAIModels {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Обновить video-модели")
                        }
                    }
                    .disabled(viewModel.isRefreshingAIModels)

                    Button {
                        isConnectionStatusPopoverPresented = false
                        viewModel.checkAIConnection()
                    } label: {
                        Text("Проверить подключение")
                    }
                    .disabled(viewModel.isCheckingAIConnection)

                    connectionCheckIndicator
                }
                .onChange(of: viewModel.aiConnectionCheckStatus) { _, newStatus in
                    if let newStatus, newStatus.matches(config: viewModel.config) {
                        isConnectionStatusPopoverPresented = true
                    }
                }
            }

            Section("Permissions") {
                PermissionSettingsRow(
                    title: "Запись экрана",
                    isGranted: viewModel.permissionState.hasScreenCapture,
                    action: viewModel.openScreenSettings
                )
                PermissionSettingsRow(
                    title: "Микрофон",
                    isGranted: viewModel.permissionState.hasMicrophone,
                    action: viewModel.openMicrophoneSettings
                )
                PermissionSettingsRow(
                    title: "Распознавание речи",
                    isGranted: viewModel.permissionState.hasSpeechRecognition,
                    action: viewModel.openSpeechRecognitionSettings
                )
                Button("Refresh Permissions") {
                    viewModel.refreshPermissions()
                }
            }

            Section("Recording") {
                HStack {
                    TextField("Save Directory", text: $viewModel.config.saveDirectory)
                    Button("Обзор...") {
                        chooseDirectory()
                    }
                }
                Picker("Качество видео", selection: $viewModel.config.videoQuality) {
                    ForEach(AppConfig.qualityPresetOrder, id: \.self) { quality in
                        if let preset = AppConfig.qualityPresets[quality] {
                            Text("\(quality) (\(preset.resolutionDescription), \(preset.fps) fps)").tag(quality)
                        }
                    }
                }
                videoQualityDetails
                Toggle("Отображать время записи", isOn: $viewModel.config.showRecordingTime)
            }

            Section("Audio") {
                Toggle("Эхоподавление (legacy ffmpeg pipeline)", isOn: $viewModel.config.echoCancellationEnabled)
                Toggle("Шумоподавление DeepFilterNet (legacy binary)", isOn: $viewModel.config.noiseReductionEnabled)
                LabeledContent("System Volume") {
                    Slider(value: $viewModel.config.systemVolume, in: 0...2)
                        .frame(width: 220)
                }
                LabeledContent("Microphone Volume") {
                    Slider(value: $viewModel.config.microphoneVolume, in: 0...2)
                        .frame(width: 220)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var connectionCheckIndicator: some View {
        if viewModel.isCheckingAIConnection {
            ProgressView()
                .controlSize(.small)
                .frame(width: 18, height: 18)
                .help("Checking \(viewModel.config.aiProvider.displayName) connection...")
        } else if let status = viewModel.aiConnectionCheckStatus, status.matches(config: viewModel.config) {
            Button {
                isConnectionStatusPopoverPresented = true
            } label: {
                Image(systemName: status.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(status.isSuccess ? .green : .red)
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .onHover { isHovering in
                if isHovering {
                    isConnectionStatusPopoverPresented = true
                }
            }
            .popover(
                isPresented: $isConnectionStatusPopoverPresented,
                attachmentAnchor: .rect(.bounds),
                arrowEdge: .leading
            ) {
                ConnectionCheckPopover(status: status)
            }
            .frame(width: 18, height: 18)
            .accessibilityLabel(status.isSuccess ? "AI connection OK" : "AI connection failed")
        }
    }

    private struct ConnectionCheckPopover: View {
        var status: AIConnectionCheckStatus

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Label(status.isSuccess ? "Connection OK" : "Connection failed", systemImage: status.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(status.isSuccess ? .green : .red)
                    .font(.headline)

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    popoverRow("Provider", status.providerName)
                    popoverRow("Model", status.modelName)
                    popoverRow("Base URL", status.baseURL)
                    popoverRow("Duration", String(format: "%.2fs", status.durationSeconds))
                    popoverRow("Checked", status.checkedAt.formatted(date: .abbreviated, time: .standard))
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text(status.isSuccess ? "Response" : "Error")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ScrollView {
                        Text(detailText)
                            .font(.caption)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
            }
            .padding(12)
            .frame(width: 360, alignment: .leading)
        }

        private var detailText: String {
            if status.isSuccess {
                return status.responseText?.isEmpty == false ? status.responseText ?? "" : status.message
            }
            return status.message
        }

        private func popoverRow(_ label: String, _ value: String) -> some View {
            GridRow {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.caption)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }

    private var videoQualityDetails: some View {
        let preset = viewModel.config.preset()
        let sizePerMinute = StenoFormatters.approximateFileSize(megabytes: preset.estimatedMegabytes(durationSeconds: 60))
        let sizePerHour = StenoFormatters.approximateFileSize(megabytes: preset.estimatedMegabytes(durationSeconds: 3_600))

        return VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Параметры") {
                Text("\(preset.resolutionDescription) · \(preset.fps) fps · \(preset.bitrateDescription)")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Размер файла") {
                Text("примерно \(sizePerMinute)/мин · \(sizePerHour)/час")
                    .foregroundStyle(.secondary)
            }
            Text("Фактический размер H.264 зависит от движения на экране, звука и содержимого записи.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var providerCredentialsFields: some View {
        switch viewModel.config.aiProvider {
        case .gemini:
            SecureField("Google Gemini API Key", text: $viewModel.config.apiKey)
            TextField("Gemini Base URL", text: $viewModel.config.baseURL)
        case .kimi:
            SecureField("Moonshot API Key", text: $viewModel.config.kimiAPIKey)
            TextField("Kimi Base URL", text: $viewModel.config.kimiBaseURL)
        case .amazonBedrock:
            TextField("AWS Access Key ID", text: $viewModel.config.awsAccessKeyID)
            SecureField("AWS Secret Access Key", text: $viewModel.config.awsSecretAccessKey)
            SecureField("AWS Session Token", text: $viewModel.config.awsSessionToken)
            TextField("AWS Region", text: $viewModel.config.awsRegion)
        case .qwen:
            SecureField("DashScope API Key", text: $viewModel.config.qwenAPIKey)
            TextField("Qwen Base URL", text: $viewModel.config.qwenBaseURL)
        case .openRouter:
            SecureField("OpenRouter API Key", text: $viewModel.config.openRouterAPIKey)
            TextField("OpenRouter Base URL", text: $viewModel.config.openRouterBaseURL)
        }
    }

    private func modelPickerTitle(_ model: AIModelReference) -> String {
        let dynamicMarker = model.isDynamicallyVerified ? "video" : "allowlist"
        return "\(model.displayName) · \(model.tier.displayName) · \(dynamicMarker)"
    }

    private var transcriptionTab: some View {
        Form {
            Section("Local Transcription") {
                Toggle("Локальная транскрибация Apple Speech", isOn: $viewModel.config.localTranscriptionEnabled)
                Toggle("Передавать транскрипт в AI", isOn: $viewModel.config.attachTranscriptToAI)
                    .disabled(!viewModel.config.localTranscriptionEnabled)

                Picker("Язык распознавания", selection: Binding(
                    get: { viewModel.config.localTranscriptionLanguage },
                    set: { viewModel.selectTranscriptionLanguage($0) }
                )) {
                    ForEach(speechLanguageOptions) { option in
                        Text(option.displayName).tag(option.localeIdentifier)
                    }
                }
                .disabled(!viewModel.config.localTranscriptionEnabled)

                speechLanguageStatus

                HStack {
                    Button {
                        Task { await viewModel.refreshSpeechLanguageOptions() }
                    } label: {
                        if viewModel.isRefreshingSpeechLanguages {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Обновить языки", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(viewModel.isRefreshingSpeechLanguages)

                    Button {
                        viewModel.openDictationSettings()
                    } label: {
                        Label("Управлять языками диктовки", systemImage: "gearshape")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            await viewModel.refreshSpeechLanguageOptions()
        }
    }

    private var speechLanguageOptions: [NativeSpeechLanguageOption] {
        if viewModel.availableSpeechLanguageOptions.isEmpty {
            return [
                NativeSpeechLanguageOption(
                    id: NativeSpeechDefaults.systemLanguageCode,
                    localeIdentifier: NativeSpeechDefaults.systemLanguageCode,
                    resolvedLocaleIdentifier: NativeSpeechDefaults.systemLanguageCode,
                    displayName: "System Language",
                    isSystemSelection: true,
                    isSupported: true,
                    isRecognizerAvailable: true,
                    isOfflineAvailable: false
                )
            ]
        }
        return viewModel.availableSpeechLanguageOptions
    }

    @ViewBuilder
    private var speechLanguageStatus: some View {
        if let status = viewModel.selectedSpeechLanguageStatus {
            LabeledContent("Оффлайн-статус") {
                Label(status.statusText, systemImage: status.isOfflineAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(status.isOfflineAvailable ? .green : .orange)
            }
            Text("Steno использует только on-device recognition. Если язык не готов, установите его в настройках диктовки macOS и обновите список.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            LabeledContent("Оффлайн-статус") {
                Text("Not checked")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var agentsTab: some View {
        HStack(spacing: 0) {
            List(selection: $selectedAgentID) {
                ForEach(viewModel.config.agents) { agent in
                    Text(agent.name)
                        .tag(Optional(agent.id))
                }
            }
            .frame(width: 220)

            Divider()

            if let index = selectedAgentIndex {
                AgentEditor(agent: $viewModel.config.agents[index], isDefault: viewModel.config.agents[index].id == "default")
                    .padding()
            } else {
                ContentUnavailableView("Select an Agent", systemImage: "person.text.rectangle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    addAgent()
                } label: {
                    Label("Add", systemImage: "plus")
                }
                Button(role: .destructive) {
                    deleteSelectedAgent()
                } label: {
                    Label("Delete", systemImage: "minus")
                }
                .disabled(selectedAgentID == nil || selectedAgentID == "default")
                Spacer()
                Picker("Active Agent", selection: $viewModel.config.activeAgentID) {
                    ForEach(viewModel.config.agents) { agent in
                        Text(agent.name).tag(agent.id)
                    }
                }
                .frame(width: 240)
            }
            .padding(.top, 10)
        }
    }

    private var selectedAgentIndex: Int? {
        guard let selectedAgentID else {
            return nil
        }
        return viewModel.config.agents.firstIndex { $0.id == selectedAgentID }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: viewModel.config.saveDirectory)
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.config.saveDirectory = url.path
        }
    }

    private func addAgent() {
        var counter = viewModel.config.agents.count + 1
        var id = "agent_\(counter)"
        while viewModel.config.agents.contains(where: { $0.id == id }) {
            counter += 1
            id = "agent_\(counter)"
        }
        let agent = Agent(id: id, name: "Новый агент", prompt: "")
        viewModel.config.agents.append(agent)
        selectedAgentID = id
    }

    private func deleteSelectedAgent() {
        guard let selectedAgentID, selectedAgentID != "default" else {
            return
        }
        viewModel.config.agents.removeAll { $0.id == selectedAgentID }
        if viewModel.config.activeAgentID == selectedAgentID {
            viewModel.config.activeAgentID = viewModel.config.agents.first?.id ?? "default"
        }
        self.selectedAgentID = viewModel.config.activeAgentID
    }
}

private struct AgentEditor: View {
    @Binding var agent: Agent
    var isDefault: Bool

    var body: some View {
        Form {
            TextField("ID", text: $agent.id)
                .disabled(isDefault)
            TextField("Название", text: $agent.name)
            TextEditor(text: $agent.prompt)
                .font(.body.monospaced())
                .frame(minHeight: 300)
        }
        .formStyle(.grouped)
    }
}

private struct PermissionSettingsRow: View {
    var title: String
    var isGranted: Bool
    var action: () -> Void

    var body: some View {
        HStack {
            Label(title, systemImage: isGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(isGranted ? .green : .red)
            Spacer()
            if !isGranted {
                Button("Настройки", action: action)
            }
        }
    }
}
