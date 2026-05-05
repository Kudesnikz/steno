import Foundation
@preconcurrency import Speech

public protocol NativeSpeechReadinessChecking: Sendable {
    /// Verifies that Apple Speech can start an on-device recognition request for the selected language.
    func validateOfflineRecognitionReady(languageCode: String) async throws
}

extension NativeSpeechService: NativeSpeechReadinessChecking {
    public func validateOfflineRecognitionReady(languageCode: String) async throws {
        try await requestAuthorizationIfNeeded()
        let recognizer = try makeOfflineRecognizer(languageCode: languageCode)
        try await NativeSpeechReadinessProbe.validate(recognizer: recognizer)
    }
}

private enum NativeSpeechReadinessProbe {
    static func validate(recognizer: SFSpeechRecognizer) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let gate = NativeSpeechReadinessGate(continuation: continuation)
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = false
            request.addsPunctuation = false
            request.taskHint = .dictation

            let task = recognizer.recognitionTask(with: request) { _, error in
                guard let error else {
                    gate.resume()
                    return
                }

                if NativeSpeechTranscriptionError.isExpectedEmptyAudioPreflightError(error) {
                    gate.resume()
                } else {
                    gate.resume(throwing: NativeSpeechTranscriptionError.recognitionFailure(for: error))
                }
            }

            gate.install(task: task, request: request)
            request.endAudio()

            Task {
                try? await Task.sleep(for: .seconds(2))
                gate.resume(throwing: NativeSpeechTranscriptionError.recognitionValidationTimedOut)
            }
        }
    }
}

private final class NativeSpeechReadinessGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var task: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?

    init(continuation: CheckedContinuation<Void, any Error>) {
        self.continuation = continuation
    }

    func install(task: SFSpeechRecognitionTask, request: SFSpeechAudioBufferRecognitionRequest) {
        lock.withLock {
            guard continuation != nil else {
                task.cancel()
                return
            }
            self.task = task
            self.request = request
        }
    }

    func resume() {
        guard let (continuation, task) = take() else {
            return
        }
        task?.cancel()
        continuation.resume()
    }

    func resume(throwing error: any Error) {
        guard let (continuation, task) = take() else {
            return
        }
        task?.cancel()
        continuation.resume(throwing: error)
    }

    private func take() -> (CheckedContinuation<Void, any Error>, SFSpeechRecognitionTask?)? {
        lock.withLock {
            guard let continuation else {
                return nil
            }
            self.continuation = nil
            let task = self.task
            self.task = nil
            request = nil
            return (continuation, task)
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
