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
            currentDirectory: currentDirectory
        )
        defer { execution.removeTemporaryFiles() }

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

        execution.closeOutputHandles()
        let standardOutput = try execution.readStandardOutput(
            maximumBytes: maximumOutputBytes
        )
        let standardError = try execution.readStandardError(
            maximumBytes: maximumOutputBytes
        )

        switch outcome {
        case .exited:
            return SandboxProcessResult(
                exitCode: execution.terminationStatus,
                standardOutput: standardOutput.data,
                standardError: standardError.data,
                standardOutputTruncated: standardOutput.truncated,
                standardErrorTruncated: standardError.truncated
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
                execution.waitUntilExit()
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
    private let temporaryDirectory: URL
    private let standardOutputURL: URL
    private let standardErrorURL: URL
    private let standardOutputHandle: FileHandle
    private let standardErrorHandle: FileHandle
    private let lock = NSLock()
    private var started = false
    private var handlesClosed = false

    init(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL?
    ) throws {
        let fileManager = FileManager.default
        temporaryDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            "darkbloom-sandbox-process-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        standardOutputURL = temporaryDirectory.appendingPathComponent("stdout")
        standardErrorURL = temporaryDirectory.appendingPathComponent("stderr")
        guard fileManager.createFile(
            atPath: standardOutputURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ),
        fileManager.createFile(
            atPath: standardErrorURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        )
        else {
            try? fileManager.removeItem(at: temporaryDirectory)
            throw SandboxRuntimeError.unsupported(
                "failed to create bounded process output files"
            )
        }

        do {
            standardOutputHandle = try FileHandle(forWritingTo: standardOutputURL)
            standardErrorHandle = try FileHandle(forWritingTo: standardErrorURL)
        } catch {
            try? fileManager.removeItem(at: temporaryDirectory)
            throw error
        }

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
        process.standardOutput = standardOutputHandle
        process.standardError = standardErrorHandle
    }

    var terminationStatus: Int32 {
        process.terminationStatus
    }

    func start() throws {
        try process.run()
        lock.withLock {
            started = true
        }
    }

    func waitUntilExit() {
        process.waitUntilExit()
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

    func closeOutputHandles() {
        let shouldClose = lock.withLock {
            guard !handlesClosed else {
                return false
            }
            handlesClosed = true
            return true
        }
        guard shouldClose else {
            return
        }
        try? standardOutputHandle.close()
        try? standardErrorHandle.close()
    }

    func readStandardOutput(maximumBytes: Int) throws -> BoundedData {
        try read(url: standardOutputURL, maximumBytes: maximumBytes)
    }

    func readStandardError(maximumBytes: Int) throws -> BoundedData {
        try read(url: standardErrorURL, maximumBytes: maximumBytes)
    }

    func removeTemporaryFiles() {
        closeOutputHandles()
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    private func read(url: URL, maximumBytes: Int) throws -> BoundedData {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        if data.count > maximumBytes {
            return BoundedData(
                data: Data(data.prefix(maximumBytes)),
                truncated: true
            )
        }
        return BoundedData(data: data, truncated: false)
    }

    struct BoundedData {
        let data: Data
        let truncated: Bool
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T {
        lock()
        defer { unlock() }
        return operation()
    }
}
