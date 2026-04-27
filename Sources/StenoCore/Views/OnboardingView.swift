import AppKit
import SwiftUI

public struct OnboardingView: View {
    @Bindable private var viewModel: AppViewModel
    @State private var apiKey = ""
    @State private var didRequestPermissions = false

    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        _apiKey = State(initialValue: viewModel.config.apiKey)
    }

    public var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Image(systemName: "video.fill")
                    .font(.system(size: 46, weight: .semibold))
                    .foregroundStyle(.blue)
                Text("Настройка Steno")
                    .font(.title.weight(.semibold))
                Text("Для записи встреч нужны права macOS и AI API Key. По умолчанию используется Gemini; провайдера можно сменить в Settings.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                PermissionRow(
                    title: "Запись экрана",
                    isGranted: viewModel.permissionState.hasScreenCapture,
                    actionTitle: "Настройки",
                    action: viewModel.openScreenSettings
                )
                Divider()
                PermissionRow(
                    title: "Микрофон",
                    isGranted: viewModel.permissionState.hasMicrophone,
                    actionTitle: "Настройки",
                    action: viewModel.openMicrophoneSettings
                )
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Google Gemini API Key")
                        .font(.headline)
                    Spacer()
                    Link("Получить ключ", destination: URL(string: "https://aistudio.google.com/app/apikey")!)
                        .font(.caption)
                }
                SecureField("AIzaSy...", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))

            Spacer()

            HStack {
                Button("Выйти") {
                    AppLog.info("Onboarding quit selected", category: .ui)
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)

                Button("Refresh Permissions") {
                    viewModel.refreshPermissions()
                }
                Spacer()
                Button("Начать работу") {
                    viewModel.completeOnboarding(apiKey: apiKey)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canContinue)
            }
        }
        .padding(28)
        .onAppear {
            guard !didRequestPermissions else {
                return
            }
            didRequestPermissions = true
            viewModel.requestInitialPermissions()
        }
    }

    private var canContinue: Bool {
        viewModel.permissionState.hasScreenCapture &&
        viewModel.permissionState.hasMicrophone &&
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines).count > 5
    }
}

private struct PermissionRow: View {
    var title: String
    var isGranted: Bool
    var actionTitle: String
    var action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(isGranted ? .green : .red)
            Text(title)
                .font(.headline)
            Spacer()
            if !isGranted {
                Button(actionTitle, action: action)
            }
        }
    }
}
