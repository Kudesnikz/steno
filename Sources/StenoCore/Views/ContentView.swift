import AppKit
import AVKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

public struct ContentView: View {
    @Bindable private var viewModel: AppViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showDeleteConfirmation = false

    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                currentContent(topInset: geometry.safeAreaInsets.top)
            }
        }
        .frame(minWidth: 920, minHeight: 620)
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
            viewModel.refreshPermissions()
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

    @ViewBuilder
    private func currentContent(topInset: CGFloat) -> some View {
        if viewModel.showSettings {
            SettingsView(viewModel: viewModel)
                .frame(minWidth: 760, idealWidth: 820, minHeight: 620, idealHeight: 680)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.showOnboarding {
            OnboardingView(viewModel: viewModel)
                .frame(width: 580, height: 560)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            mainApplicationContent(topInset: topInset)
        }
    }

    private func mainApplicationContent(topInset: CGFloat) -> some View {
        VStack(spacing: 0) {
            MainWindowToolbar(
                viewModel: viewModel,
                topInset: topInset
            )

            Divider()

            HSplitView {
                SidebarView(
                    viewModel: viewModel,
                    showDeleteConfirmation: $showDeleteConfirmation
                )
                    .frame(minWidth: 220, idealWidth: 280, maxWidth: 320, maxHeight: .infinity)

                DetailView(viewModel: viewModel)
                    .frame(minWidth: 640, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(maxHeight: .infinity)
        }
        .ignoresSafeArea(.container, edges: .top)
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
                    viewModel.toggleSystemAudioCapture()
                } label: {
                    Image(systemName: viewModel.config.systemAudioEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                }
                .tint(viewModel.config.systemAudioEnabled ? .accentColor : .secondary)
                .help(viewModel.config.systemAudioEnabled ? "Disable system audio" : "Enable system audio")
                .disabled(viewModel.isFinalizingRecording)

                Button {
                    viewModel.toggleMicrophoneCapture()
                } label: {
                    Image(systemName: viewModel.config.microphoneEnabled ? "mic.fill" : "mic.slash.fill")
                }
                .tint(viewModel.config.microphoneEnabled ? .accentColor : .secondary)
                .help(viewModel.config.microphoneEnabled ? "Disable microphone" : "Enable microphone")
                .disabled(viewModel.isFinalizingRecording)

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
    @State private var renamingFolderID: String?
    @State private var folderRenameText = ""
    @State private var showCreateFolder = false
    @State private var newFolderName = ""
    @State private var folderPendingDeletion: RecordingFolder?
    @State private var showImporter = false
    @State private var importTargetFolderID: String?
    @State private var isFileDropTarget = false

    var body: some View {
        List(selection: $viewModel.selectedSessionID) {
            Section {
                if viewModel.sessions.isEmpty && viewModel.folders.isEmpty {
                    SidebarPlaceholderRow()
                } else {
                    recordingGroup(title: "Без папки", systemImage: "tray", folderID: nil, sessions: rootSessions)
                    ForEach(viewModel.folders) { folder in
                        folderGroup(folder)
                    }
                }
            } header: {
                HStack {
                    Text("Recordings")
                    Spacer()
                    Menu {
                        Button("Новая папка", systemImage: "folder.badge.plus") {
                            newFolderName = ""
                            showCreateFolder = true
                        }
                        Button("Импорт записи", systemImage: "square.and.arrow.down") {
                            importTargetFolderID = nil
                            showImporter = true
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton)
                }
            }

            Section("Status") {
                SidebarStatusRow(viewModel: viewModel)
            }
        }
        .listStyle(.sidebar)
        .onDrop(of: [.fileURL], isTargeted: $isFileDropTarget) { providers in
            handleDrop(providers, folderID: nil)
        }
        .overlay {
            if isFileDropTarget {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.accentColor.opacity(0.12))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7]))
                    .overlay {
                        Label("Импортировать запись", systemImage: "square.and.arrow.down")
                            .font(.headline)
                            .padding(12)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: viewModel.sessions.map(\.id)) { _, sessionIDs in
            if let renamingSessionID, !sessionIDs.contains(renamingSessionID) {
                cancelRename()
            }
        }
        .onChange(of: viewModel.selectedSessionID) { _, selectedID in
            guard let selectedID,
                  let session = viewModel.sessions.first(where: { $0.id == selectedID }) else { return }
            viewModel.select(session)
        }
        .alert("Новая папка", isPresented: $showCreateFolder) {
            TextField("Название", text: $newFolderName)
            Button("Создать") { viewModel.createFolder(name: newFolderName) }
            Button("Отмена", role: .cancel) {}
        }
        .confirmationDialog(
            "Удалить папку «\(folderPendingDeletion?.name ?? "")»?",
            isPresented: Binding(
                get: { folderPendingDeletion != nil },
                set: { if !$0 { folderPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Удалить папку и записи", role: .destructive) {
                if let folderPendingDeletion { viewModel.deleteFolder(id: folderPendingDeletion.id, deleteRecordings: true) }
                folderPendingDeletion = nil
            }
            Button("Удалить только папку") {
                if let folderPendingDeletion { viewModel.deleteFolder(id: folderPendingDeletion.id, deleteRecordings: false) }
                folderPendingDeletion = nil
            }
            Button("Отмена", role: .cancel) { folderPendingDeletion = nil }
        } message: {
            Text("Записи можно удалить вместе с папкой или перенести в корень.")
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.movie], allowsMultipleSelection: false) { result in
            guard case let .success(urls) = result, let url = urls.first else {
                if case let .failure(error) = result { viewModel.errorMessage = "Import failed: \(error.localizedDescription)" }
                return
            }
            Task { await viewModel.importRecording(from: url, folderID: importTargetFolderID) }
        }
    }

    private var rootSessions: [MeetingSession] {
        viewModel.sessions.filter { $0.metadata.folderID == nil }
    }

    @ViewBuilder
    private func folderGroup(_ folder: RecordingFolder) -> some View {
        DisclosureGroup {
            let sessions = viewModel.sessions.filter { $0.metadata.folderID == folder.id }
            if sessions.isEmpty {
                Text("Пустая папка").font(.caption).foregroundStyle(.tertiary)
            } else {
                sessionRows(sessions)
            }
        } label: {
            HStack {
                Image(systemName: "folder")
                if renamingFolderID == folder.id {
                    TextField("Название папки", text: $folderRenameText)
                        .onSubmit { commitFolderRename(folder) }
                        .onExitCommand { cancelFolderRename() }
                } else {
                    Text(folder.name)
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .onDrop(of: [.text, .fileURL], isTargeted: nil) { providers in
                handleDrop(providers, folderID: folder.id)
            }
            .contextMenu {
                Button("Переименовать") { beginFolderRename(folder) }
                Button("Импортировать сюда") {
                    importTargetFolderID = folder.id
                    showImporter = true
                }
                Divider()
                Button("Удалить", role: .destructive) {
                    if viewModel.sessions.contains(where: { $0.metadata.folderID == folder.id }) {
                        folderPendingDeletion = folder
                    } else {
                        viewModel.deleteFolder(id: folder.id, deleteRecordings: false)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func recordingGroup(title: String, systemImage: String, folderID: String?, sessions: [MeetingSession]) -> some View {
        DisclosureGroup {
            if sessions.isEmpty {
                Text("Нет записей").font(.caption).foregroundStyle(.tertiary)
            } else {
                sessionRows(sessions)
            }
        } label: {
            Label(title, systemImage: systemImage)
                .contentShape(Rectangle())
                .onDrop(of: [.text, .fileURL], isTargeted: nil) { providers in
                    handleDrop(providers, folderID: folderID)
                }
        }
    }

    @ViewBuilder
    private func sessionRows(_ sessions: [MeetingSession]) -> some View {
        ForEach(sessions) { session in
            SessionRow(
                session: session,
                isRenaming: renamingSessionID == session.id,
                renameText: $renameText,
                onRenameButton: {
                    renamingSessionID == session.id ? commitRename(session) : beginRename(session)
                },
                onCommitRename: { commitRename(session) },
                onCancelRename: cancelRename,
                onDelete: { requestDelete(session) }
            )
            .tag(session.id)
            .onDrag { NSItemProvider(object: session.id as NSString) }
            .contextMenu {
                Button("Rename") { beginRename(session) }
                Button("Delete", role: .destructive) { requestDelete(session) }
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider], folderID: String?) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data,
                      let url = URL(dataRepresentation: data, relativeTo: nil),
                      url.isFileURL else { return }
                Task { @MainActor in
                    await viewModel.importRecording(from: url, folderID: folderID)
                }
            }
            return true
        }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let id = object as? String else { return }
            Task { @MainActor in viewModel.moveSession(id: id, toFolderID: folderID) }
        }
        return true
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

    private func beginFolderRename(_ folder: RecordingFolder) {
        renamingFolderID = folder.id
        folderRenameText = folder.name
    }

    private func commitFolderRename(_ folder: RecordingFolder) {
        viewModel.renameFolder(id: folder.id, to: folderRenameText)
        cancelFolderRename()
    }

    private func cancelFolderRename() {
        renamingFolderID = nil
        folderRenameText = ""
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
                    if !session.availableReports.isEmpty {
                        Text("Protocols").tag("reports")
                    }
                    Text("Player").tag("player")
                    Text("Info").tag("info")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .padding()

                switch viewModel.selectedTabID {
                case "player":
                    PlayerPane(session: session)
                case "info":
                    InfoPane(session: session)
                default:
                    if viewModel.selectedTabID == "reports" {
                        ReportPane(viewModel: viewModel)
                    } else {
                        PlayerPane(session: session)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            ContentUnavailableView("Select a Recording", systemImage: "sidebar.left", description: Text("Choose a recording in the sidebar."))
        }
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

private struct ReportPane: View {
    @Bindable var viewModel: AppViewModel

    var body: some View {
        if let session = viewModel.selectedSession, let report = viewModel.selectedReport {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Picker("Version", selection: Binding(
                        get: { viewModel.selectedReportID ?? report.id },
                        set: { viewModel.selectReport(id: $0) }
                    )) {
                        ForEach(session.availableReports) { item in
                            Text(reportTitle(item)).tag(item.id)
                        }
                    }
                    .frame(maxWidth: 360)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.bottom, 8)

                ChatPane(
                    viewModel: viewModel,
                    reportID: report.id,
                    reportText: viewModel.loadReportText(reportID: report.id)
                )
            }
        } else {
            ContentUnavailableView("No protocol", systemImage: "doc.text")
        }
    }

    private func reportTitle(_ report: ReportInfo) -> String {
        let agent = report.agentName.isEmpty ? report.agentID : report.agentName
        let date = ISO8601DateFormatter().date(from: report.createdAt)?.formatted(date: .abbreviated, time: .shortened)
            ?? report.createdAt
        return "\(agent) · \(date)"
    }
}

private struct ChatPane: View {
    @Bindable var viewModel: AppViewModel
    var reportID: String
    var reportText: String
    @State private var question = ""

    var body: some View {
        VStack(spacing: 0) {
            RemoteMediaStatusView(availability: viewModel.remoteMediaAvailability)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ProtocolMessageBubble(markdown: reportText) {
                            viewModel.copySelectedReport()
                        } save: { updatedText in
                            viewModel.saveSelectedReport(updatedText)
                        }
                        .id("protocol:\(reportID)")

                        HStack {
                            Text("Чат по записи")
                                .font(.headline)
                            Spacer()
                        }
                        .padding(.top, 8)

                        ForEach(viewModel.chatThread?.messages ?? []) { message in
                            ChatMessageBubble(message: message) {
                                viewModel.retryChatMessage(id: message.id)
                            }
                            .id(message.id)
                        }
                    }
                    .padding(20)
                }
                .onChange(of: viewModel.chatThread?.messages.count) { _, _ in
                    if let id = viewModel.chatThread?.messages.last?.id {
                        withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
            }

            Divider()
            if let blockedUntil = viewModel.geminiUsageSnapshot?.blockedUntil {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if blockedUntil > context.date {
                        Text("Gemini разрешит повтор через \(max(0, Int(blockedUntil.timeIntervalSince(context.date).rounded(.up)))) сек.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 14)
                            .padding(.top, 8)
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Задайте вопрос по записи…", text: $question, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                if viewModel.isSendingChatMessage {
                    Button("Cancel") { viewModel.cancelChatMessage() }
                } else {
                    Button(action: send) { Image(systemName: "paperplane.fill") }
                        .disabled(
                            question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                (viewModel.geminiUsageSnapshot?.blockedUntil ?? .distantPast) > Date()
                        )
                }
            }
            .padding(14)
        }
    }

    private func send() {
        let value = question
        question = ""
        viewModel.sendChatMessage(value)
    }
}

private struct RemoteMediaStatusView: View {
    var availability: RemoteMediaAvailability

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            indicator
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private var indicator: some View {
        switch availability {
        case .uploading:
            ProgressView().controlSize(.small)
        case .available:
            Image(systemName: "circle.fill").foregroundStyle(.green)
        case .expired:
            Image(systemName: "circle.fill").foregroundStyle(.yellow)
        case .failed:
            Image(systemName: "circle.fill").foregroundStyle(.red)
        case .notUploaded:
            Image(systemName: "circle.fill").foregroundStyle(.secondary)
        }
    }

    private var title: String {
        switch availability {
        case let .uploading(current, total): "Загрузка части \(current) из \(total)…"
        case let .available(until): "Видео загружено в Gemini до \(until.formatted(date: .abbreviated, time: .shortened))"
        case .expired: "Срок хранения видео истек"
        case let .failed(message): "Не удалось подготовить видео: \(message)"
        case .notUploaded: "Видео будет загружено перед первым вопросом"
        }
    }

    private var subtitle: String {
        switch availability {
        case .available: "Можно задавать вопросы без повторной загрузки. Запросы к модели продолжают расходовать токены."
        case .expired: "Steno автоматически загрузит запись перед следующим вопросом."
        case .uploading: "Не закрывайте приложение до завершения загрузки."
        case .failed: "Повторите отправку сообщения, чтобы попробовать снова."
        case .notUploaded: "После загрузки файл будет доступен Gemini до 48 часов."
        }
    }
}

private struct ChatMessageBubble: View {
    var message: ChatMessage
    var retry: () -> Void

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 80) }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Text(message.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    CopyTextButton(text: message.text)
                }
                if message.status == .sending {
                    ProgressView().controlSize(.small)
                } else if message.status == .failed {
                    HStack {
                        Text(message.error ?? "Ошибка").font(.caption).foregroundStyle(.red)
                        Button("Retry", action: retry).font(.caption)
                    }
                }
            }
            .padding(10)
            .background(message.role == .user ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            if message.role == .model { Spacer(minLength: 80) }
        }
    }
}

private struct ProtocolMessageBubble: View {
    var markdown: String
    var copy: () -> Void
    var save: (String) -> Bool
    @State private var isEditing = false
    @State private var draft = ""
    @State private var savedMarkdown: String?
    @FocusState private var isEditorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Протокол", systemImage: "doc.text.fill")
                    .font(.headline)
                Spacer()
                if isEditing {
                    Button("Cancel", role: .cancel, action: cancelEditing)
                        .keyboardShortcut(.cancelAction)
                    Button(action: saveChanges) {
                        Label("Save", systemImage: "checkmark")
                    }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(draft == displayedMarkdown)
                } else {
                    Button(action: copy) {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .help("Скопировать протокол")
                    Button(action: beginEditing) {
                        Label("Edit", systemImage: "pencil")
                    }
                    .help("Редактировать протокол")
                }
            }
            .buttonStyle(.borderless)

            if isEditing {
                TextEditor(text: $draft)
                    .font(.system(.body, design: .monospaced))
                    .focused($isEditorFocused)
                    .frame(minHeight: 320, idealHeight: 480)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.25))
                    }
            } else {
                MarkdownReportView(markdown: displayedMarkdown)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var displayedMarkdown: String {
        savedMarkdown ?? markdown
    }

    private func beginEditing() {
        draft = displayedMarkdown
        isEditing = true
        isEditorFocused = true
    }

    private func cancelEditing() {
        draft = displayedMarkdown
        isEditing = false
    }

    private func saveChanges() {
        guard save(draft) else { return }
        savedMarkdown = draft
        isEditing = false
    }
}

private struct CopyTextButton: View {
    var text: String

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help("Скопировать сообщение")
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
