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
                Divider()
                PermissionRow(
                    title: "Распознавание речи",
                    isGranted: viewModel.permissionState.hasSpeechRecognition,
                    actionTitle: "Настройки",
                    action: viewModel.openSpeechRecognitionSettings
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

                HStack(spacing: 8) {
                    Button {
                        viewModel.checkGeminiConnection(apiKey: apiKey)
                    } label: {
                        if viewModel.isCheckingAIConnection {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Проверить подключение")
                        }
                    }
                    .disabled(viewModel.isCheckingAIConnection || trimmedAPIKey.isEmpty)

                    if let status = geminiConnectionStatus {
                        Label(
                            status.isSuccess ? "Подключение работает" : "Ошибка подключения",
                            systemImage: status.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(status.isSuccess ? .green : .red)
                        .help(status.tooltip)
                    }
                }
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))

            Spacer()

            HStack {
                Button("Выйти") {
                    AppLog.info("Onboarding quit selected", category: .ui)
                    viewModel.quitApplication()
                }
                .keyboardShortcut("q", modifiers: .command)

                Button("Перезапустить") {
                    viewModel.restartApplication()
                }

                Button("Обновить права") {
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
        .onChange(of: apiKey) { _, _ in
            viewModel.aiConnectionCheckStatus = nil
        }
    }

    private var trimmedAPIKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var geminiConnectionStatus: AIConnectionCheckStatus? {
        guard let status = viewModel.aiConnectionCheckStatus, status.providerID == .gemini else {
            return nil
        }
        return status
    }

    private var canContinue: Bool {
        viewModel.permissionState.hasScreenCapture &&
        viewModel.permissionState.hasMicrophone &&
        (!viewModel.config.localTranscriptionEnabled || viewModel.permissionState.hasSpeechRecognition) &&
        trimmedAPIKey.count > 5
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
