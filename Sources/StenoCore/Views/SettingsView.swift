import AppKit
import SwiftUI

public struct SettingsView: View {
    @Bindable private var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedAgentID: String?
    @State private var selectedWhisperModelIDs = Set<String>()

    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        _selectedAgentID = State(initialValue: viewModel.config.activeAgentID)
    }

    public var body: some View {
        VStack(spacing: 0) {
            TabView {
                generalTab
                    .tabItem { Text("Общие") }
                whisperModelsTab
                    .tabItem { Text("Whisper") }
                agentsTab
                    .tabItem { Text("Агенты") }
            }
            .padding()

            Divider()

            HStack {
                Text("Version 0.2.0-native")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Save") {
                    viewModel.saveConfig()
                    dismiss()
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
                        viewModel.checkAIConnection()
                    } label: {
                        if viewModel.isCheckingAIConnection {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Проверить подключение")
                        }
                    }
                    .disabled(viewModel.isCheckingAIConnection)
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

    private var whisperModelsTab: some View {
        VStack(spacing: 12) {
            Form {
                Section("Realtime Transcription") {
                    Toggle("Локальная транскрибация Whisper", isOn: $viewModel.config.localTranscriptionEnabled)
                    Toggle("Передавать транскрипт в AI", isOn: $viewModel.config.attachTranscriptToAI)
                        .disabled(!viewModel.config.localTranscriptionEnabled)

                    Picker("Активная модель", selection: $viewModel.config.localTranscriptionModel) {
                        if viewModel.installedWhisperModels.isEmpty {
                            Text(viewModel.config.localTranscriptionModel).tag(viewModel.config.localTranscriptionModel)
                        } else {
                            ForEach(viewModel.installedWhisperModels) { model in
                                Text("\(model.displayName) · \(model.installState.displayName)").tag(model.id)
                            }
                        }
                    }
                    .disabled(!viewModel.config.localTranscriptionEnabled)

                    Picker("Язык", selection: $viewModel.config.localTranscriptionLanguage) {
                        Text("Auto").tag("auto")
                        Text("Русский").tag("ru")
                        Text("English").tag("en")
                    }
                    .disabled(!viewModel.config.localTranscriptionEnabled)

                    Stepper(value: $viewModel.config.localTranscriptionThreadCount, in: 1...4) {
                        Text("Потоки CPU: \(viewModel.config.localTranscriptionThreadCount)")
                    }
                    .disabled(!viewModel.config.localTranscriptionEnabled)
                }
            }
            .formStyle(.grouped)
            .frame(height: 185)

            HStack {
                Button {
                    Task { await viewModel.refreshWhisperModels() }
                } label: {
                    if viewModel.isRefreshingWhisperModels {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Обновить каталог", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(viewModel.isRefreshingWhisperModels || viewModel.whisperDownloadState.isDownloading)

                Button {
                    Task { await viewModel.downloadWhisperModels(ids: selectedWhisperModelIDs) }
                } label: {
                    if viewModel.whisperDownloadState.isDownloading {
                        Text("Скачивается...")
                    } else {
                        Label("Скачать", systemImage: "arrow.down.circle")
                    }
                }
                .disabled(selectedDownloadableModelIDs.isEmpty || viewModel.whisperDownloadState.isDownloading)

                Button(role: .destructive) {
                    Task { await viewModel.deleteWhisperModels(ids: selectedWhisperModelIDs) }
                } label: {
                    Label("Удалить", systemImage: "trash")
                }
                .disabled(selectedDeletableModelIDs.isEmpty || viewModel.whisperDownloadState.isDownloading)

                Button {
                    if let id = selectedSingleInstalledModelID {
                        viewModel.config.localTranscriptionModel = id
                    }
                } label: {
                    Label("Использовать", systemImage: "checkmark.circle")
                }
                .disabled(selectedSingleInstalledModelID == nil)

                Spacer()

                Button {
                    Task { await viewModel.runWhisperVoiceTest(modelID: selectedSingleInstalledModelID) }
                } label: {
                    if viewModel.isTestingWhisperModel {
                        Text("Идет тест...")
                    } else {
                        Label("Тест 5 сек", systemImage: "mic")
                    }
                }
                .disabled(viewModel.isTestingWhisperModel || viewModel.whisperDownloadState.isDownloading || testModelID == nil)
            }

            List(selection: $selectedWhisperModelIDs) {
                ForEach(viewModel.availableWhisperModels) { model in
                    WhisperModelRow(model: model, isActive: model.id == viewModel.config.localTranscriptionModel)
                        .tag(model.id)
                }
            }
            .frame(minHeight: 180)

            GroupBox("Результат теста") {
                if viewModel.isTestingWhisperModel {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Говорите в микрофон. Запись идет 5 секунд.")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                } else if let error = viewModel.whisperTestErrorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if let result = viewModel.whisperTestResult {
                    ScrollView {
                        Text(result)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 90)
                } else {
                    Text("Выберите установленную модель или используйте активную, затем запустите тест.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .task {
            await viewModel.refreshWhisperModels()
        }
    }

    private var selectedModels: [WhisperModelDescriptor] {
        viewModel.availableWhisperModels.filter { selectedWhisperModelIDs.contains($0.id) }
    }

    private var selectedDownloadableModelIDs: Set<String> {
        Set(selectedModels.filter { !$0.isInstalled }.map(\.id))
    }

    private var selectedDeletableModelIDs: Set<String> {
        Set(selectedModels.filter(\.canDelete).map(\.id))
    }

    private var selectedSingleInstalledModelID: String? {
        guard selectedWhisperModelIDs.count == 1 else {
            return nil
        }
        let installed = selectedModels.filter(\.isInstalled)
        return installed.count == 1 ? installed[0].id : nil
    }

    private var testModelID: String? {
        selectedSingleInstalledModelID ?? viewModel.activeWhisperModel?.id
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

private struct WhisperModelRow: View {
    var model: WhisperModelDescriptor
    var isActive: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.displayName)
                        .lineLimit(1)
                    if isActive {
                        Text("active")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }
                Text("\(model.fileName) · \(model.sizeDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(model.installState.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }

    private var iconName: String {
        switch model.installState {
        case .bundled:
            "shippingbox.fill"
        case .downloaded:
            "checkmark.circle.fill"
        case .remote:
            "icloud.and.arrow.down"
        }
    }

    private var iconColor: Color {
        switch model.installState {
        case .bundled, .downloaded:
            .green
        case .remote:
            .secondary
        }
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
