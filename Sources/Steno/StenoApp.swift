import AppKit
import StenoCore
import SwiftUI

@main
struct StenoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var viewModel = AppViewModel()

    var body: some Scene {
        Window("Steno", id: "main") {
            ContentView(viewModel: viewModel)
                .background {
                    StatusBarBridgeView(
                        viewModel: viewModel,
                        appDelegate: appDelegate
                    )
                }
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    AppLog.info("Command settings selected", category: .ui)
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    viewModel.showSettings = true
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandGroup(replacing: .appTermination) {
                Button("Quit Steno") {
                    AppLog.info("Command quit selected", category: .ui)
                    viewModel.quitApplication()
                }
                .keyboardShortcut("q", modifiers: .command)
            }

            CommandMenu("Recording") {
                Button(viewModel.recordingCommandTitle) {
                    AppLog.info("Command recording action selected", category: .ui)
                    if viewModel.isRecording {
                        Task { await viewModel.stopRecording() }
                    } else {
                        Task { await viewModel.startRecording() }
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(viewModel.isFinalizingRecording || viewModel.isProcessing)

                Button("Generate Report") {
                    AppLog.info("Command generate report selected", category: .ui)
                    viewModel.generateSelectedReport()
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(!viewModel.canGenerate)
            }
        }

        Settings {
            SettingsView(viewModel: viewModel)
                .frame(width: 740, height: 560)
        }
    }
}

private struct StatusBarBridgeView: View {
    @Bindable var viewModel: AppViewModel
    let appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                configureStatusBar()
            }
            .onChange(of: snapshot) { _, newSnapshot in
                appDelegate.statusBarController?.update(newSnapshot)
            }
    }

    private func configureStatusBar() {
        let controller = appDelegate.makeStatusBarController()
        controller.configure(
            viewModel: viewModel,
            showMainWindow: {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            },
            showSettings: {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
                viewModel.showSettings = true
            },
            quitApplication: {
                viewModel.quitApplication()
            }
        )
        controller.update(snapshot)
    }

    private var snapshot: StatusBarSnapshot {
        StatusBarSnapshot(
            isRecording: viewModel.isRecording,
            isFinalizingRecording: viewModel.isFinalizingRecording,
            isProcessing: viewModel.isProcessing,
            showRecordingTime: viewModel.config.showRecordingTime,
            recordingDuration: viewModel.recordingDuration,
            transcriptionProgress: viewModel.transcriptionProgress
        )
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var statusBarController: StatusBarController?

    func makeStatusBarController() -> StatusBarController {
        if let statusBarController {
            return statusBarController
        }

        let controller = StatusBarController()
        statusBarController = controller
        return controller
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.info("Application did finish launching", category: .app)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        AppLog.info("Last window closed; keeping app alive for menu bar", category: .app)
        NSApp.setActivationPolicy(.accessory)
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppLog.info("Application should terminate", category: .app)
        return .terminateNow
    }
}
