import Foundation

public struct ProcessResult: Sendable {
    public var terminationStatus: Int32
    public var standardOutput: Data
    public var standardError: Data

    public init(terminationStatus: Int32, standardOutput: Data, standardError: Data) {
        self.terminationStatus = terminationStatus
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public enum ProcessRunnerError: LocalizedError, Sendable {
    case nonZeroExit(status: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case let .nonZeroExit(status, stderr):
            "Process failed with status \(status): \(stderr)"
        }
    }
}

public actor ProcessRunner {
    public init() {}

    public func run(executableURL: URL, arguments: [String]) async throws -> ProcessResult {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                final class Box: @unchecked Sendable {
                    var didResume = false
                    let lock = NSLock()
                }
                let box = Box()

                process.terminationHandler = { terminatedProcess in
                    let stdout = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderr = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    box.lock.lock()
                    defer { box.lock.unlock() }
                    guard !box.didResume else {
                        return
                    }
                    box.didResume = true
                    continuation.resume(returning: ProcessResult(
                        terminationStatus: terminatedProcess.terminationStatus,
                        standardOutput: stdout,
                        standardError: stderr
                    ))
                }

                do {
                    try process.run()
                } catch {
                    box.lock.lock()
                    defer { box.lock.unlock() }
                    guard !box.didResume else {
                        return
                    }
                    box.didResume = true
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
    }

    public func runChecked(executableURL: URL, arguments: [String]) async throws -> ProcessResult {
        let result = try await run(executableURL: executableURL, arguments: arguments)
        guard result.terminationStatus == 0 else {
            let stderr = String(data: result.standardError, encoding: .utf8) ?? ""
            throw ProcessRunnerError.nonZeroExit(status: result.terminationStatus, stderr: stderr)
        }
        return result
    }
}
