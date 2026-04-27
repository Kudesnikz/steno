import AVKit
import SwiftUI

public struct ContentView: View {
    @Bindable private var viewModel: AppViewModel
    @State private var renameText = ""
    @State private var isRenaming = false
    @State private var showDeleteConfirmation = false

    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        HSplitView {
            SidebarView(viewModel: viewModel)
                .frame(minWidth: 220, idealWidth: 280, maxWidth: 320, maxHeight: .infinity)

            DetailView(
                viewModel: viewModel,
                renameText: $renameText,
                isRenaming: $isRenaming,
                showDeleteConfirmation: $showDeleteConfirmation
            )
            .frame(minWidth: 640, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 920, minHeight: 620)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if viewModel.isProcessing {
                    ProgressView()
                        .controlSize(.small)
                    Button("Cancel") {
                        viewModel.cancelGeneration()
                    }
                }

                Picker("Agent", selection: $viewModel.config.activeAgentID) {
                    ForEach(viewModel.config.agents) { agent in
                        Text(agent.name).tag(agent.id)
                    }
                }
                .frame(width: 190)

                Button {
                    if viewModel.isRecording {
                        Task { await viewModel.stopRecording() }
                    } else {
                        Task { await viewModel.startRecording() }
                    }
                } label: {
                    Label(viewModel.isRecording ? "Stop" : "Record", systemImage: viewModel.isRecording ? "stop.circle.fill" : "record.circle")
                }
                .tint(viewModel.isRecording ? .secondary : .red)

                Button {
                    viewModel.generateSelectedReport()
                } label: {
                    Label("Generate", systemImage: "bolt.fill")
                }
                .disabled(!viewModel.canGenerate)

                Button {
                    viewModel.showSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .sheet(isPresented: $viewModel.showSettings) {
            SettingsView(viewModel: viewModel)
                .frame(width: 740, height: 560)
        }
        .sheet(isPresented: $viewModel.showOnboarding) {
            OnboardingView(viewModel: viewModel)
                .frame(width: 560, height: 500)
        }
        .alert("Error", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .alert("Delete Recording?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                viewModel.deleteSelectedSession()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all files for the selected recording.")
        }
        .onAppear {
            AppLog.info("Main window appeared", category: .ui)
            viewModel.refreshPermissions()
        }
    }
}

private struct SidebarView: View {
    @Bindable var viewModel: AppViewModel

    var body: some View {
        List(selection: $viewModel.selectedSessionID) {
            Section("Recordings") {
                if viewModel.sessions.isEmpty {
                    SidebarPlaceholderRow()
                } else {
                    ForEach(viewModel.sessions) { session in
                        SessionRow(session: session)
                            .tag(session.id)
                            .contextMenu {
                                Button("Rename") {
                                    viewModel.selectedSessionID = session.id
                                }
                                Button("Delete", role: .destructive) {
                                    viewModel.selectedSessionID = session.id
                                    viewModel.deleteSelectedSession()
                                }
                            }
                    }
                }
            }

            Section("Status") {
                SidebarStatusRow(viewModel: viewModel)
            }
        }
        .listStyle(.sidebar)
    }
}

private struct SidebarPlaceholderRow: View {
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("No Recordings")
                    .foregroundStyle(.secondary)
                Text("Start a recording or choose an output folder.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        } icon: {
            Image(systemName: "video.slash")
                .foregroundStyle(.secondary)
                .frame(width: 16)
        }
    }
}

private struct SidebarStatusRow: View {
    var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if viewModel.isRecording {
                Label(StenoFormatters.duration(viewModel.recordingDuration), systemImage: "record.circle")
                    .foregroundStyle(.red)
            }

            Label {
                Text("Tokens: \(viewModel.config.usedTokens / 1000)k total")
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "number")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
            }

            Text("Last request: \(viewModel.config.lastRequestTokens / 1000)k")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.leading, 26)
                .lineLimit(1)
        }
    }
}

private struct SessionRow: View {
    var session: MeetingSession

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: session.reportURLsByAgentID.isEmpty ? "film" : "checkmark.square.fill")
                .foregroundStyle(session.reportURLsByAgentID.isEmpty ? Color.secondary : Color.green)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayName)
                    .lineLimit(1)
                Text(StenoFormatters.megabytes(session.totalSizeMB))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct DetailView: View {
    @Bindable var viewModel: AppViewModel
    @Binding var renameText: String
    @Binding var isRenaming: Bool
    @Binding var showDeleteConfirmation: Bool

    var body: some View {
        if let session = viewModel.selectedSession {
            VStack(spacing: 0) {
                header(session)
                Divider()
                Picker("Content", selection: $viewModel.selectedTabID) {
                    ForEach(session.sortedReportAgentIDs, id: \.self) { agentID in
                        Text(agentName(agentID)).tag("report:\(agentID)")
                    }
                    Text("Player").tag("player")
                    Text("Info").tag("info")
                }
                .pickerStyle(.segmented)
                .padding()

                switch viewModel.selectedTabID {
                case "player":
                    PlayerPane(session: session)
                case "info":
                    InfoPane(session: session)
                default:
                    if viewModel.selectedTabID.hasPrefix("report:") {
                        let agentID = String(viewModel.selectedTabID.dropFirst("report:".count))
                        ReportPane(viewModel: viewModel, agentID: agentID)
                    } else {
                        PlayerPane(session: session)
                    }
                }
            }
        } else {
            ContentUnavailableView("Select a Recording", systemImage: "sidebar.left", description: Text("Choose a recording in the sidebar."))
        }
    }

    @ViewBuilder
    private func header(_ session: MeetingSession) -> some View {
        HStack(spacing: 12) {
            if isRenaming {
                TextField("Recording name", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        viewModel.renameSelectedSession(to: renameText)
                        isRenaming = false
                    }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.displayName)
                        .font(.title2.weight(.semibold))
                    Text(session.videoURL.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            Button {
                renameText = session.displayName
                isRenaming.toggle()
                if !isRenaming {
                    viewModel.renameSelectedSession(to: renameText)
                }
            } label: {
                Label(isRenaming ? "Save" : "Rename", systemImage: isRenaming ? "checkmark" : "pencil")
            }

            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .padding()
        .background(.regularMaterial)
    }

    private func agentName(_ agentID: String) -> String {
        viewModel.config.agent(id: agentID)?.name ?? agentID
    }
}

private struct ReportPane: View {
    @Bindable var viewModel: AppViewModel
    var agentID: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button {
                    viewModel.copyReport(agentID: agentID)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)

            ScrollView {
                Text(markdown: viewModel.loadReportText(agentID: agentID))
                    .textSelection(.enabled)
                    .frame(maxWidth: 860, alignment: .leading)
                    .padding(.horizontal, 36)
                    .padding(.vertical, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct PlayerPane: View {
    var session: MeetingSession

    var body: some View {
        if FileManager.default.fileExists(atPath: session.videoURL.path) {
            AVPlayerViewBridge(url: session.videoURL)
        } else {
            ContentUnavailableView("Video Unavailable", systemImage: "video.slash")
        }
    }
}

private struct AVPlayerViewBridge: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.player = AVPlayer(url: url)
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        let currentURL = (nsView.player?.currentItem?.asset as? AVURLAsset)?.url
        guard currentURL != url else {
            return
        }
        nsView.player?.pause()
        nsView.player = AVPlayer(url: url)
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player?.pause()
        nsView.player = nil
    }
}

private struct InfoPane: View {
    var session: MeetingSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let recording = session.metadata.recording {
                    InfoSection(title: "Recording") {
                        InfoRow(label: "Duration", value: StenoFormatters.duration(recording.durationSeconds))
                        InfoRow(label: "Quality", value: recording.videoQuality)
                        InfoRow(label: "Video", value: recording.videoPath)
                        InfoRow(label: "Video size", value: StenoFormatters.megabytes(recording.videoSizeMB))
                    }
                }

                if let reports = session.metadata.reports, !reports.isEmpty {
                    InfoSection(title: "AI Reports") {
                        ForEach(reports) { report in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(report.agentName.isEmpty ? report.agentID : report.agentName)
                                    .font(.headline)
                                InfoRow(label: "Status", value: report.status)
                                InfoRow(label: "Model", value: report.model)
                                InfoRow(label: "Processing", value: StenoFormatters.shortDuration(report.processingDurationSeconds))
                                InfoRow(label: "Tokens", value: StenoFormatters.tokens(report.tokens.total))
                                if let error = report.error {
                                    InfoRow(label: "Error", value: error)
                                }
                            }
                            .padding(.vertical, 8)
                        }
                    }
                }

                if session.metadata.recording == nil && (session.metadata.reports ?? []).isEmpty {
                    ContentUnavailableView("No Metadata", systemImage: "info.circle")
                }
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
        }
    }
}

private struct InfoSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

private struct InfoRow: View {
    var label: String
    var value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

private extension Text {
    init(markdown: String) {
        if let attributed = try? AttributedString(markdown: markdown, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            self.init(attributed)
        } else {
            self.init(verbatim: markdown)
        }
    }
}
