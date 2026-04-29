import AppKit
import Foundation

/// Snapshot of app state that controls the menu bar status item presentation.
public struct StatusBarSnapshot: Equatable, Sendable {
    public var isRecording: Bool
    public var isFinalizingRecording: Bool
    public var isProcessing: Bool
    public var showRecordingTime: Bool
    public var recordingDuration: Int
    public var transcriptionProgress: TranscriptionProgress

    public init(
        isRecording: Bool,
        isFinalizingRecording: Bool,
        isProcessing: Bool,
        showRecordingTime: Bool,
        recordingDuration: Int,
        transcriptionProgress: TranscriptionProgress = .idle
    ) {
        self.isRecording = isRecording
        self.isFinalizingRecording = isFinalizingRecording
        self.isProcessing = isProcessing
        self.showRecordingTime = showRecordingTime
        self.recordingDuration = recordingDuration
        self.transcriptionProgress = transcriptionProgress
    }
}

/// Owns Steno's native macOS menu bar status item.
///
/// SwiftUI's `MenuBarExtra` is reliable for SF Symbols, but AppKit's
/// `NSStatusItem` gives deterministic control over template PNG assets.
@MainActor
public final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    private weak var viewModel: AppViewModel?
    private var showMainWindow: (() -> Void)?
    private var showSettings: (() -> Void)?
    private var quitApplication: (() -> Void)?
    private var snapshot = StatusBarSnapshot(
        isRecording: false,
        isFinalizingRecording: false,
        isProcessing: false,
        showRecordingTime: true,
        recordingDuration: 0,
        transcriptionProgress: .idle
    )

    public override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        statusItem.menu = menu
        menu.showsStateColumn = false
        configureButton()
        rebuildMenu()
        update(snapshot)
    }

    /// Connects the status item to app state and window-opening actions.
    public func configure(
        viewModel: AppViewModel,
        showMainWindow: @escaping () -> Void,
        showSettings: @escaping () -> Void,
        quitApplication: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.showMainWindow = showMainWindow
        self.showSettings = showSettings
        self.quitApplication = quitApplication
        rebuildMenu()
    }

    /// Applies the latest app state to the status item image, title, tooltip, and menu.
    public func update(_ snapshot: StatusBarSnapshot) {
        self.snapshot = snapshot

        guard let button = statusItem.button else {
            return
        }

        button.image = image(for: snapshot)
        button.imagePosition = snapshot.title.isEmpty ? .imageOnly : .imageLeft
        button.title = snapshot.title
        button.toolTip = snapshot.tooltip
        rebuildMenu()
    }

    private func configureButton() {
        guard let button = statusItem.button else {
            return
        }
        button.imageScaling = .scaleProportionallyDown
        button.imagePosition = .imageOnly
        button.title = ""
        button.toolTip = "Steno"
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let recordingTitle: String
        if snapshot.isFinalizingRecording {
            recordingTitle = "Finalizing Recording..."
        } else {
            recordingTitle = snapshot.isRecording ? "Stop Recording" : "Start Recording"
        }
        menu.addItem(item(title: recordingTitle, action: #selector(toggleRecording)))

        if snapshot.isProcessing {
            menu.addItem(item(title: "Cancel AI Processing", action: #selector(cancelProcessing)))
        }

        menu.addItem(.separator())
        menu.addItem(item(title: "Show UI", action: #selector(showUI)))
        menu.addItem(item(title: "Settings...", action: #selector(openSettings)))
        menu.addItem(item(title: "Open Output Folder", action: #selector(openOutputFolder)))
        menu.addItem(.separator())
        menu.addItem(item(title: "Made by Sergey Galay", action: #selector(openRepository)))
        menu.addItem(item(title: "Quit", action: #selector(quit)))

        menu.item(withTitle: recordingTitle)?.isEnabled = !snapshot.isProcessing && !snapshot.isFinalizingRecording
    }

    private func item(title: String, action: Selector) -> NSMenuItem {
        let item = IconlessMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func image(for snapshot: StatusBarSnapshot) -> NSImage {
        if snapshot.isRecording {
            return loadTemplateImage(named: "menu_recordingTemplate", fallbackSymbol: "record.circle.fill")
        }
        if snapshot.isProcessing || snapshot.isFinalizingRecording {
            return loadTemplateImage(named: "menu_processingTemplate", fallbackSymbol: "bolt.fill")
        }
        return loadTemplateImage(named: "menu_idleTemplate", fallbackSymbol: "video.fill")
    }

    private func loadTemplateImage(named name: String, fallbackSymbol: String) -> NSImage {
        let image = Bundle.main
            .url(forResource: name, withExtension: "png", subdirectory: "assets")
            .flatMap(NSImage.init(contentsOf:))
            ?? NSImage(systemSymbolName: fallbackSymbol, accessibilityDescription: nil)
            ?? NSImage(size: NSSize(width: 18, height: 18))

        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }

    @objc private func toggleRecording() {
        guard !snapshot.isFinalizingRecording else {
            return
        }
        guard let viewModel else {
            return
        }
        if snapshot.isRecording {
            Task { await viewModel.stopRecording() }
        } else {
            Task { await viewModel.startRecording() }
        }
    }

    @objc private func cancelProcessing() {
        viewModel?.cancelGeneration()
    }

    @objc private func showUI() {
        showMainWindow?()
    }

    @objc private func openSettings() {
        showSettings?()
    }

    @objc private func openOutputFolder() {
        viewModel?.openOutputFolder()
    }

    @objc private func openRepository() {
        NSWorkspace.shared.open(AppLinks.repository)
    }

    @objc private func quit() {
        if let quitApplication {
            quitApplication()
        } else {
            ApplicationLifecycleService.quit()
        }
    }
}

private final class IconlessMenuItem: NSMenuItem {
    override var image: NSImage? {
        get { nil }
        set {}
    }
}

private extension StatusBarSnapshot {
    var title: String {
        guard isRecording, showRecordingTime else {
            return ""
        }
        return StenoFormatters.duration(recordingDuration)
    }

    var tooltip: String {
        if isRecording {
            if transcriptionProgress.hasRealtimeBacklog {
                return "Steno is recording\nTranscription backlog: \(transcriptionProgress.remainingWindowCount) chunks"
            }
            return "Steno is recording"
        }
        if isFinalizingRecording {
            if transcriptionProgress.remainingWindowCount > 0 {
                return "Steno is finalizing recording\nTranscription chunks remaining: \(transcriptionProgress.remainingWindowCount)"
            }
            return "Steno is finalizing recording"
        }
        if isProcessing {
            return "Steno is processing"
        }
        return "Steno"
    }
}
