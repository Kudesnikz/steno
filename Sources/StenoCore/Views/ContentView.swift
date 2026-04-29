import AppKit
import AVKit
import Combine
import SwiftUI

public struct ContentView: View {
    @Bindable private var viewModel: AppViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showDeleteConfirmation = false

    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                MainWindowToolbar(
                    viewModel: viewModel,
                    topInset: geometry.safeAreaInsets.top
                )

                Divider()

                HSplitView {
                    SidebarView(
                        viewModel: viewModel,
                        showDeleteConfirmation: $showDeleteConfirmation
                    )
                        .frame(minWidth: 220, idealWidth: 280, maxWidth: 320, maxHeight: .infinity)

                    DetailView(viewModel: viewModel)
                        .frame(minWidth: 640, maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxHeight: .infinity)
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .frame(minWidth: 920, minHeight: 620)
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
            Task {
                await viewModel.refreshCaptureDisplays()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else {
                return
            }
            Task {
                await viewModel.refreshCaptureDisplays()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            Task {
                await viewModel.refreshCaptureDisplays()
            }
        }
    }
}

private struct MainWindowToolbar: View {
    @Bindable var viewModel: AppViewModel
    var topInset: CGFloat

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
                .allowsWindowActivationEvents(true)

            HStack(spacing: 8) {
                Spacer(minLength: 96)

                if viewModel.isProcessing || viewModel.isFinalizingRecording {
                    ProgressView()
                        .controlSize(.small)
                }
                if viewModel.isProcessing {
                    Button("Cancel") {
                        viewModel.cancelGeneration()
                    }
                }

                if viewModel.shouldShowCaptureDisplayPicker {
                    Picker("Monitor", selection: Binding(
                        get: { viewModel.config.videoDeviceIndex },
                        set: { viewModel.selectCaptureDisplay(id: $0) }
                    )) {
                        ForEach(viewModel.availableCaptureDisplays) { display in
                            Text(display.menuTitle).tag(display.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 190)
                    .help("Screen to record")
                }

                Picker("Agent", selection: $viewModel.config.activeAgentID) {
                    ForEach(viewModel.config.agents) { agent in
                        Text(agent.name).tag(agent.id)
                    }
                }
                .frame(width: 190)
                .help("Agent for AI report generation")

                Button {
                    toggleRecording()
                } label: {
                    ToolbarButtonLabel(title: recordingButtonTitle, systemImage: recordingButtonIcon)
                }
                .tint(viewModel.isRecording ? .secondary : .red)
                .disabled(viewModel.isFinalizingRecording || (viewModel.isProcessing && !viewModel.isRecording))

                Button {
                    viewModel.generateSelectedReport()
                } label: {
                    ToolbarButtonLabel(title: "Generate", systemImage: "bolt.fill")
                }
                .disabled(!viewModel.canGenerate)

                Button {
                    viewModel.showSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            .controlSize(.small)
            .padding(.leading, 88)
            .padding(.trailing, 12)
        }
        .frame(height: max(40, topInset))
        .background(.bar)
    }

    private var recordingButtonTitle: String {
        if viewModel.isFinalizingRecording {
            return "Saving"
        }
        return viewModel.isRecording ? "Stop" : "Record"
    }

    private var recordingButtonIcon: String {
        if viewModel.isFinalizingRecording {
            return "hourglass"
        }
        return viewModel.isRecording ? "stop.circle.fill" : "record.circle"
    }

    private func toggleRecording() {
        if viewModel.isRecording {
            Task { await viewModel.stopRecording() }
        } else {
            Task { await viewModel.startRecording() }
        }
    }
}

private struct ToolbarButtonLabel: View {
    var title: String
    var systemImage: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(title)
        }
    }
}

private struct SidebarView: View {
    @Bindable var viewModel: AppViewModel
    @Binding var showDeleteConfirmation: Bool
    @State private var renamingSessionID: MeetingSession.ID?
    @State private var renameText = ""

    var body: some View {
        List(selection: $viewModel.selectedSessionID) {
            Section("Recordings") {
                if viewModel.sessions.isEmpty {
                    SidebarPlaceholderRow()
                } else {
                    ForEach(viewModel.sessions) { session in
                        SessionRow(
                            session: session,
                            isRenaming: renamingSessionID == session.id,
                            renameText: $renameText,
                            onRenameButton: {
                                if renamingSessionID == session.id {
                                    commitRename(session)
                                } else {
                                    beginRename(session)
                                }
                            },
                            onCommitRename: {
                                commitRename(session)
                            },
                            onCancelRename: cancelRename,
                            onDelete: {
                                requestDelete(session)
                            }
                        )
                            .tag(session.id)
                            .contextMenu {
                                Button("Rename") {
                                    beginRename(session)
                                }
                                Button("Delete", role: .destructive) {
                                    requestDelete(session)
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
        .onChange(of: viewModel.sessions.map(\.id)) { _, sessionIDs in
            if let renamingSessionID, !sessionIDs.contains(renamingSessionID) {
                cancelRename()
            }
        }
    }

    private func beginRename(_ session: MeetingSession) {
        viewModel.selectedSessionID = session.id
        renamingSessionID = session.id
        renameText = session.displayName
    }

    private func commitRename(_ session: MeetingSession) {
        guard renamingSessionID == session.id else {
            return
        }

        let trimmedName = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty && trimmedName != session.displayName {
            viewModel.selectedSessionID = session.id
            viewModel.renameSelectedSession(to: trimmedName)
        }
        cancelRename()
    }

    private func cancelRename() {
        renamingSessionID = nil
        renameText = ""
    }

    private func requestDelete(_ session: MeetingSession) {
        viewModel.selectedSessionID = session.id
        showDeleteConfirmation = true
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
            } else if viewModel.isFinalizingRecording {
                Label("Finalizing recording", systemImage: "hourglass")
                    .foregroundStyle(.secondary)
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
    var isRenaming: Bool
    @Binding var renameText: String
    var onRenameButton: () -> Void
    var onCommitRename: () -> Void
    var onCancelRename: () -> Void
    var onDelete: () -> Void
    @FocusState private var isRenameFieldFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: session.reportURLsByAgentID.isEmpty ? "film" : "checkmark.square.fill")
                .foregroundStyle(session.reportURLsByAgentID.isEmpty ? Color.secondary : Color.green)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                if isRenaming {
                    TextField("Recording name", text: $renameText)
                        .textFieldStyle(.roundedBorder)
                        .focused($isRenameFieldFocused)
                        .lineLimit(1)
                        .onSubmit(onCommitRename)
                        .onExitCommand(perform: onCancelRename)
                        .onAppear {
                            isRenameFieldFocused = true
                        }
                } else {
                    Text(session.displayName)
                        .lineLimit(1)
                }
                Text(StenoFormatters.megabytes(session.totalSizeMB))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                SidebarActionIconButton(
                    systemImage: "pencil",
                    help: isRenaming ? "Save name" : "Rename",
                    action: onRenameButton
                )

                SidebarActionIconButton(
                    systemImage: "trash",
                    help: "Delete",
                    role: .destructive,
                    action: onDelete
                )
            }
        }
    }
}

private struct DetailView: View {
    @Bindable var viewModel: AppViewModel

    var body: some View {
        if let session = viewModel.selectedSession {
            VStack(spacing: 0) {
                Picker("Content", selection: $viewModel.selectedTabID) {
                    ForEach(session.sortedReportAgentIDs, id: \.self) { agentID in
                        Text(agentName(agentID)).tag("report:\(agentID)")
                    }
                    Text("Player").tag("player")
                    Text("Transcript").tag("transcript")
                    Text("Info").tag("info")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .padding()

                switch viewModel.selectedTabID {
                case "player":
                    PlayerPane(session: session)
                case "transcript":
                    TranscriptPane(viewModel: viewModel, session: session)
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

    private func agentName(_ agentID: String) -> String {
        viewModel.config.agent(id: agentID)?.name ?? agentID
    }
}

private struct SidebarActionIconButton: View {
    var systemImage: String
    var help: String
    var role: ButtonRole?
    var action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? .red : .secondary)
        .opacity(0.55)
        .help(help)
    }
}

private struct TranscriptPane: View {
    @Bindable var viewModel: AppViewModel
    var session: MeetingSession
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                let transcriptDocument = viewModel.transcriptDocument(for: session)

                if viewModel.isTranscribing, viewModel.liveTranscriptDocument?.baseName == session.baseName {
                    Label("Transcribing", systemImage: "waveform")
                        .foregroundStyle(.secondary)
                }
                if let error = viewModel.transcriptionErrorMessage, viewModel.liveTranscriptDocument?.baseName == session.baseName {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
                Spacer()
                if let transcriptDocument, !transcriptDocument.sortedSegments.isEmpty {
                    TextField("Search transcript", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(viewModel.loadTranscriptMarkdown(for: session), forType: .string)
                    viewModel.statusMessage = "Transcript copied"
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(viewModel.loadTranscriptMarkdown(for: session).isEmpty)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)

            if let document = viewModel.transcriptDocument(for: session), !document.sortedSegments.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(filteredSegments(document.sortedSegments)) { segment in
                            TranscriptSegmentRow(segment: segment)
                        }
                    }
                    .frame(maxWidth: 860, alignment: .leading)
                    .padding(.horizontal, 36)
                    .padding(.vertical, 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "Transcript Unavailable",
                    systemImage: "text.bubble",
                    description: Text(viewModel.config.localTranscriptionEnabled ? "Transcript will appear while recording audio is processed." : "Local Whisper transcription is disabled in Settings.")
                )
            }
        }
    }

    private func filteredSegments(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return segments
        }
        return segments.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }
}

private struct TranscriptSegmentRow: View {
    var segment: TranscriptSegment

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(timestamp)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(segment.source.displayName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 120, alignment: .leading)

            Text(segment.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }

    private var timestamp: String {
        let start = StenoFormatters.duration(Int(segment.startTimeSeconds.rounded(.down)))
        let end = StenoFormatters.duration(Int(segment.endTimeSeconds.rounded(.up)))
        return "\(start)-\(end)"
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
                MarkdownReportView(markdown: viewModel.loadReportText(agentID: agentID))
                    .frame(maxWidth: 860, alignment: .leading)
                    .padding(.horizontal, 36)
                    .padding(.vertical, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct MarkdownReportView: View {
    private let blocks: [MarkdownBlock]

    init(markdown: String) {
        blocks = MarkdownBlockParser.parse(markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            Text(markdown: text)
                .font(headingFont(level))
                .padding(.top, level == 1 ? 4 : 2)
        case let .paragraph(text):
            Text(markdown: text)
                .lineSpacing(3)
        case let .unorderedList(items):
            MarkdownListView(items: items, style: .unordered)
        case let .orderedList(items):
            MarkdownListView(items: items, style: .ordered)
        case let .codeBlock(language, code):
            MarkdownCodeBlockView(language: language, code: code)
        case let .blockquote(text):
            MarkdownBlockquoteView(text: text)
        case let .table(headers, rows):
            MarkdownTableView(headers: headers, rows: rows)
        case .divider:
            Divider()
                .padding(.vertical, 2)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1:
            .title2.weight(.semibold)
        case 2:
            .title3.weight(.semibold)
        case 3:
            .headline
        default:
            .subheadline.weight(.semibold)
        }
    }
}

private struct MarkdownListView: View {
    enum ListStyle {
        case unordered
        case ordered
    }

    var items: [String]
    var style: ListStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(marker(for: index))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .trailing)
                    Text(markdown: item)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func marker(for index: Int) -> String {
        switch style {
        case .unordered:
            "•"
        case .ordered:
            "\(index + 1)."
        }
    }
}

private struct MarkdownCodeBlockView: View {
    var language: String?
    var code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let language, !language.isEmpty {
                Text(language.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(code)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary)
        }
    }
}

private struct MarkdownBlockquoteView: View {
    var text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(.secondary)
                .frame(width: 3)
            Text(markdown: text)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }
}

private struct MarkdownTableView: View {
    var headers: [String]
    var rows: [[String]]

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(columnIndices, id: \.self) { index in
                        tableCell(headers[safe: index] ?? "", isHeader: true)
                    }
                }

                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(columnIndices, id: \.self) { index in
                            tableCell(row[safe: index] ?? "", isHeader: false)
                        }
                    }
                }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.quaternary)
            }
        }
    }

    private var columnIndices: Range<Int> {
        0..<max(headers.count, rows.map(\.count).max() ?? 0)
    }

    private func tableCell(_ text: String, isHeader: Bool) -> some View {
        Text(markdown: text)
            .font(isHeader ? .subheadline.weight(.semibold) : .body)
            .frame(minWidth: 120, maxWidth: 260, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isHeader ? Color.secondary.opacity(0.12) : Color.clear)
            .border(.quaternary, width: 0.5)
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

                if let transcription = session.metadata.transcription {
                    InfoSection(title: "Transcription") {
                        InfoRow(label: "Status", value: transcription.status.rawValue)
                        InfoRow(label: "Model", value: transcription.modelName)
                        InfoRow(label: "Language", value: transcription.language)
                        InfoRow(label: "Segments", value: "\(transcription.segmentCount)")
                        InfoRow(label: "Transcript", value: transcription.markdownPath)
                        if let error = transcription.error {
                            InfoRow(label: "Error", value: error)
                        }
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

                if session.metadata.recording == nil && session.metadata.transcription == nil && (session.metadata.reports ?? []).isEmpty {
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

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

#if DEBUG
#Preview("Main Window") {
    ContentView(viewModel: .previewMainWindow)
        .frame(width: 1100, height: 720)
}

@MainActor
private extension AppViewModel {
    static var previewMainWindow: AppViewModel {
        let viewModel = AppViewModel()
        var config = AppConfig.default
        config.videoDeviceIndex = "display-main"
        config.activeAgentID = "default"
        config.agents = [
            Agent(id: "default", name: "Default", prompt: "Create a concise meeting protocol."),
            Agent(id: "sales", name: "Sales Follow-up", prompt: "Extract objections, next steps, and owners.")
        ]
        config.usedTokens = 128_400
        config.lastRequestTokens = 9_240

        let baseURL = URL(filePath: "/tmp/steno-preview/Meet_28.04.2026_14:30:00")
        let session = MeetingSession(
            baseName: "Meet_28.04.2026_14:30:00",
            baseURL: baseURL,
            videoURL: baseURL.appendingPathExtension("mp4"),
            metadataURL: baseURL.appendingPathExtension("json"),
            transcriptURL: baseURL.appendingPathExtension("srt"),
            transcriptMarkdownURL: baseURL.appendingPathExtension("md"),
            audioURLs: [],
            reportURLsByAgentID: [:],
            metadata: SessionMetadata(
                name: "Design Review",
                createdAt: "2026-04-28T14:30:00Z",
                recording: RecordingInfo(
                    durationSeconds: 2_948,
                    videoQuality: "1920x1080 30 fps",
                    videoPath: baseURL.appendingPathExtension("mp4").path,
                    microphoneAudioPath: baseURL.appendingPathExtension("m4a").path,
                    videoSizeMB: 412.8,
                    microphoneSizeMB: 18.6
                )
            ),
            modifiedAt: Date(timeIntervalSinceReferenceDate: 798_472_800)
        )

        viewModel.config = config
        viewModel.sessions = [session]
        viewModel.selectedSessionID = session.id
        viewModel.selectedTabID = "info"
        viewModel.showOnboarding = false
        viewModel.permissionState = PermissionState(hasScreenCapture: true, hasMicrophone: true)
        viewModel.availableCaptureDisplays = [
            CaptureDisplay(displayID: "display-main", name: "Built-in Display", width: 3024, height: 1964, isMain: true),
            CaptureDisplay(displayID: "display-studio", name: "Studio Display", width: 5120, height: 2880, isMain: false)
        ]
        viewModel.statusMessage = "Preview"
        return viewModel
    }
}
#endif
