import AppKit
import StenoCore
import SwiftUI

@main
struct StenoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var viewModel = AppViewModel()
    @State private var statusBarController = StatusBarController()

    var body: some Scene {
        WindowGroup("Steno", id: "main") {
            ContentView(viewModel: viewModel)
                .background {
                    StatusBarBridgeView(
                        viewModel: viewModel,
                        controller: statusBarController
                    )
                }
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
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
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }

            CommandMenu("Recording") {
                Button(viewModel.isRecording ? "Stop Recording" : "Start Recording") {
                    AppLog.info("Command recording action selected", category: .ui)
                    if viewModel.isRecording {
                        Task { await viewModel.stopRecording() }
                    } else {
                        Task { await viewModel.startRecording() }
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

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
    let controller: StatusBarController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
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
                    }
                )
                controller.update(snapshot)
            }
            .onChange(of: snapshot) { _, newSnapshot in
                controller.update(newSnapshot)
            }
    }

    private var snapshot: StatusBarSnapshot {
        StatusBarSnapshot(
            isRecording: viewModel.isRecording,
            isProcessing: viewModel.isProcessing,
            showRecordingTime: viewModel.config.showRecordingTime,
            recordingDuration: viewModel.recordingDuration
        )
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.info("Application did finish launching", category: .app)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        AppLog.info("Last window closed; keeping app alive for menu bar", category: .app)
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppLog.info("Application should terminate", category: .app)
        return .terminateNow
    }
}
