import Darwin
import Foundation

public struct SandboxProcessResult: Sendable {
    public let exitCode: Int32
    public let standardOutput: Data
    public let standardError: Data
    public let standardOutputTruncated: Bool
    public let standardErrorTruncated: Bool

    public init(
        exitCode: Int32,
        standardOutput: Data,
        standardError: Data,
        standardOutputTruncated: Bool,
        standardErrorTruncated: Bool
    ) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.standardOutputTruncated = standardOutputTruncated
        self.standardErrorTruncated = standardErrorTruncated
    }
}

public struct SandboxProcessRunner: Sendable {
    public static let defaultMaximumOutputBytes = 4 * 1_048_576

    public init() {}

    public func run(
        executable: URL,
        arguments: [String],
        environment: [String: String] = [:],
        currentDirectory: URL? = nil,
        timeoutSeconds: UInt32,
        maximumOutputBytes: Int = defaultMaximumOutputBytes
    ) async throws -> SandboxProcessResult {
        guard executable.isFileURL,
              FileManager.default.isExecutableFile(atPath: executable.path)
        else {
            throw SandboxRuntimeError.executableNotFound(executable.path)
        }
        guard timeoutSeconds > 0, maximumOutputBytes > 0 else {
            throw SandboxRuntimeError.unsupported(
                "process timeout and output limit must be positive"
            )
        }

        let execution = try ProcessExecution(
            executable: executable,
            arguments: arguments,
            environment: environment,
            currentDirectory: currentDirectory,
            maximumOutputBytes: maximumOutputBytes
        )
        defer { execution.cleanup() }

        try execution.start()
        let outcome = try await withTaskCancellationHandler {
            try await wait(
                for: execution,
                timeoutSeconds: timeoutSeconds
            )
        } onCancel: {
            execution.forceStop()
        }
        try Task.checkCancellation()

        let output = execution.finishOutputCapture()

        switch outcome {
        case .exited:
            return SandboxProcessResult(
                exitCode: execution.terminationStatus,
                standardOutput: output.standardOutput.data,
                standardError: output.standardError.data,
                standardOutputTruncated: output.standardOutput.truncated,
                standardErrorTruncated: output.standardError.truncated
            )
        case .timedOut:
            throw SandboxRuntimeError.operationTimedOut(
                executable.lastPathComponent
            )
        case .cancelled:
            throw CancellationError()
        }
    }

    private func wait(
        for execution: ProcessExecution,
        timeoutSeconds: UInt32
    ) async throws -> WaitOutcome {
        let outcome = await withTaskGroup(of: WaitOutcome.self) { group in
            group.addTask {
                await execution.waitUntilExit()
                return .exited
            }
            group.addTask {
                do {
                    try await Task.sleep(for: .seconds(timeoutSeconds))
                    return .timedOut
                } catch {
                    return .cancelled
                }
            }

            let first = await group.next() ?? .cancelled
            if first == .timedOut {
                execution.requestStop()
                try? await Task.sleep(for: .seconds(2))
                execution.forceStop()
            }
            group.cancelAll()
            while await group.next() != nil {}
            return first
        }
        if outcome == .cancelled {
            throw CancellationError()
        }
        return outcome
    }

    private enum WaitOutcome: Equatable, Sendable {
        case exited
        case timedOut
        case cancelled
    }
}

private final class ProcessExecution: @unchecked Sendable {
    private let process: Process
    private let exitSignal = ProcessExitSignal()
    private let standardOutput: BoundedProcessOutput
    private let standardError: BoundedProcessOutput
    private let lock = NSLock()
    private var started = false

    init(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL?,
        maximumOutputBytes: Int
    ) throws {
        let standardOutput = try BoundedProcessOutput(
            maximumBytes: maximumOutputBytes
        )
        let standardError: BoundedProcessOutput
        do {
            standardError = try BoundedProcessOutput(
                maximumBytes: maximumOutputBytes
            )
        } catch {
            _ = standardOutput.finish()
            throw error
        }
        self.standardOutput = standardOutput
        self.standardError = standardError

        process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        var mergedEnvironment = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            mergedEnvironment[key] = value
        }
        process.environment = mergedEnvironment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = standardOutput.writer
        process.standardError = standardError.writer
        process.terminationHandler = { [exitSignal] _ in
            exitSignal.signal()
        }
    }

    var terminationStatus: Int32 {
        process.terminationStatus
    }

    func start() throws {
        do {
            try process.run()
        } catch {
            standardOutput.closeParentWriter()
            standardError.closeParentWriter()
            throw error
        }
        lock.withLock {
            started = true
        }
        standardOutput.closeParentWriter()
        standardError.closeParentWriter()
    }

    func waitUntilExit() async {
        await exitSignal.wait()
    }

    func requestStop() {
        let shouldStop = lock.withLock { started && process.isRunning }
        if shouldStop {
            process.terminate()
        }
    }

    func forceStop() {
        let pid = lock.withLock {
            started && process.isRunning ? process.processIdentifier : 0
        }
        if pid > 0 {
            _ = Darwin.kill(pid, SIGKILL)
        }
    }

    func finishOutputCapture() -> ProcessOutput {
        ProcessOutput(
            standardOutput: standardOutput.finish(),
            standardError: standardError.finish()
        )
    }

    func cleanup() {
        _ = finishOutputCapture()
    }

    struct ProcessOutput {
        let standardOutput: BoundedProcessOutputSnapshot
        let standardError: BoundedProcessOutputSnapshot
    }
}

private final class ProcessExitSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var exited = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock {
                if exited {
                    return true
                }
                self.continuation = continuation
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    func signal() {
        let continuation = lock.withLock {
            exited = true
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume()
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T {
        lock()
        defer { unlock() }
        return operation()
    }
}
