import AppKit
import SwiftUI

public struct SettingsView: View {
    @Bindable private var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedAgentID: String?

    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        _selectedAgentID = State(initialValue: viewModel.config.activeAgentID)
    }

    public var body: some View {
        VStack(spacing: 0) {
            TabView {
                generalTab
                    .tabItem { Text("Общие") }
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
            Section("Gemini") {
                SecureField("Google API Key", text: $viewModel.config.apiKey)
                TextField("Base URL", text: $viewModel.config.baseURL)
                Picker("AI Model", selection: $viewModel.config.modelName) {
                    ForEach(AppConfig.aiModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                Button {
                    viewModel.checkAIConnection()
                } label: {
                    if viewModel.isCheckingAIConnection {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Проверить Base URL и модель")
                    }
                }
                .disabled(viewModel.isCheckingAIConnection)
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
                    ForEach(AppConfig.qualityPresets.keys.sorted(), id: \.self) { quality in
                        Text(quality).tag(quality)
                    }
                }
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
