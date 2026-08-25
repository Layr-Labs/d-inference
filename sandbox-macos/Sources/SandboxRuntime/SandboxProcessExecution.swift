import Darwin
import Dispatch
import Foundation

final class ProcessExecution: @unchecked Sendable {
    private let executable: URL
    private let arguments: [String]
    private let environment: [String: String]
    private let currentDirectory: URL?
    private let exitSignal = ProcessExitSignal()
    private let standardOutput: BoundedProcessOutput
    private let standardError: BoundedProcessOutput
    private let cooperativeControl: ProcessControlChannel?
    private let testHooks: ProcessExecutionTestHooks
    private let lock = NSLock()
    private var started = false
    private var processIdentifier: pid_t = 0
    private var directChildExitObserved = false
    private var signalAttemptsEnabled = false
    private var exitCode: Int32?

    init(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL?,
        maximumOutputBytes: Int,
        cooperativeControl configuration:
            SandboxCooperativeProcessControl? = nil,
        testHooks: ProcessExecutionTestHooks = .none
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
        let cooperativeControl: ProcessControlChannel?
        do {
            cooperativeControl = try configuration.map { _ in
                try ProcessControlChannel()
            }
        } catch {
            _ = standardOutput.finish()
            _ = standardError.finish()
            throw error
        }
        var childEnvironment = environment
        if let configuration {
            childEnvironment[configuration.environmentVariable] =
                String(ProcessControlChannel.childDescriptor)
        }
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.cooperativeControl = cooperativeControl
        self.executable = executable
        self.arguments = arguments
        self.environment = childEnvironment
        self.currentDirectory = currentDirectory
        self.testHooks = testHooks
    }

    var terminationStatus: Int32 {
        lock.withLock { exitCode ?? -1 }
    }

    var isRunning: Bool {
        lock.withLock {
            started && !directChildExitObserved && exitCode == nil
        }
    }

    var processIdentifierForTesting: pid_t {
        lock.withLock { processIdentifier }
    }

    func start() throws {
        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            standardOutput.closeParentWriter()
            standardError.closeParentWriter()
            throw SandboxRuntimeError.unsupported(
                "failed to initialize process spawning"
            )
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        guard posix_spawnattr_init(&attributes) == 0 else {
            standardOutput.closeParentWriter()
            standardError.closeParentWriter()
            throw SandboxRuntimeError.unsupported(
                "failed to initialize process attributes"
            )
        }
        defer { posix_spawnattr_destroy(&attributes) }

        try addFileActions(&fileActions)
        var defaultSignals = sigset_t()
        var signalMask = sigset_t()
        let flags = Int16(
            POSIX_SPAWN_SETPGROUP
                | POSIX_SPAWN_CLOEXEC_DEFAULT
                | POSIX_SPAWN_SETSIGDEF
                | POSIX_SPAWN_SETSIGMASK
        )
        guard sigemptyset(&defaultSignals) == 0,
              sigaddset(&defaultSignals, SIGTERM) == 0,
              sigemptyset(&signalMask) == 0,
              posix_spawnattr_setsigdefault(
                  &attributes,
                  &defaultSignals
              ) == 0,
              posix_spawnattr_setsigmask(&attributes, &signalMask) == 0,
              posix_spawnattr_setflags(&attributes, flags) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0
        else {
            standardOutput.closeParentWriter()
            standardError.closeParentWriter()
            throw SandboxRuntimeError.unsupported(
                "failed to isolate spawned process group"
            )
        }

        var child: pid_t = 0
        let spawnStatus = try Self.withCStringArray(
            [executable.path] + arguments
        ) { argumentVector in
            try Self.withCStringArray(
                environment.sorted { $0.key < $1.key }.map {
                    "\($0.key)=\($0.value)"
                }
            ) { environmentVector in
                executable.path.withCString { executablePath in
                    posix_spawn(
                        &child,
                        executablePath,
                        &fileActions,
                        &attributes,
                        argumentVector,
                        environmentVector
                    )
                }
            }
        }
        cooperativeControl?.closeChildSourceEndpoint()
        standardOutput.closeParentWriter()
        standardError.closeParentWriter()
        guard spawnStatus == 0 else {
            throw POSIXError(
                POSIXErrorCode(rawValue: spawnStatus) ?? .EIO
            )
        }

        lock.withLock {
            started = true
            processIdentifier = child
            signalAttemptsEnabled = true
        }
        let spawnedChild = child
        DispatchQueue.global(qos: .utility).async { [self] in
            reap(processIdentifier: spawnedChild)
        }
    }

    func waitUntilExit() async {
        await exitSignal.wait()
    }

    func requestStop() {
        send(signal: SIGTERM)
    }

    @discardableResult
    func requestCooperativeStop() -> Bool {
        guard let cooperativeControl else {
            return false
        }
        cooperativeControl.closeParentEndpoint()
        return true
    }

    func forceStop() {
        send(signal: SIGKILL)
    }

    func stop(
        cooperativeGracePeriod: Duration,
        signalGracePeriod: Duration
    ) async {
        let cooperative = requestCooperativeStop()
        if !cooperative {
            requestStop()
        }
        await withTaskGroup(of: StopEvent.self) { group in
            group.addTask {
                await self.waitUntilExit()
                return .exited
            }
            group.addTask {
                try? await Task.sleep(
                    for: cooperative
                        ? cooperativeGracePeriod
                        : signalGracePeriod
                )
                return cooperative
                    ? .cooperativeDeadline
                    : .signalDeadline
            }
            while let event = await group.next() {
                switch event {
                case .exited:
                    group.cancelAll()
                    while await group.next() != nil {}
                    return
                case .cooperativeDeadline:
                    requestStop()
                    group.addTask {
                        try? await Task.sleep(for: signalGracePeriod)
                        return .signalDeadline
                    }
                case .signalDeadline:
                    forceStop()
                }
            }
        }
    }

    func finishOutputCapture() -> ProcessOutput {
        ProcessOutput(
            standardOutput: standardOutput.finish(),
            standardError: standardError.finish()
        )
    }

    func result(output: ProcessOutput? = nil) -> SandboxProcessResult {
        let output = output ?? finishOutputCapture()
        return SandboxProcessResult(
            exitCode: terminationStatus,
            standardOutput: output.standardOutput.data,
            standardError: output.standardError.data,
            standardOutputTruncated: output.standardOutput.truncated,
            standardErrorTruncated: output.standardError.truncated
        )
    }

    func cleanup() {
        cooperativeControl?.closeParentEndpoint()
        cooperativeControl?.closeChildSourceEndpoint()
        _ = finishOutputCapture()
    }

    private func addFileActions(
        _ actions: inout posix_spawn_file_actions_t?
    ) throws {
        let outputWriter = standardOutput.writer.fileDescriptor
        let errorWriter = standardError.writer.fileDescriptor
        let operations: [Int32] = [
            posix_spawn_file_actions_addopen(
                &actions,
                STDIN_FILENO,
                "/dev/null",
                O_RDONLY,
                0
            ),
            posix_spawn_file_actions_adddup2(
                &actions,
                outputWriter,
                STDOUT_FILENO
            ),
            posix_spawn_file_actions_adddup2(
                &actions,
                errorWriter,
                STDERR_FILENO
            ),
            posix_spawn_file_actions_addclose(
                &actions,
                standardOutput.readerFileDescriptor
            ),
            posix_spawn_file_actions_addclose(
                &actions,
                standardError.readerFileDescriptor
            ),
        ]
        guard operations.allSatisfy({ $0 == 0 }) else {
            throw SandboxRuntimeError.unsupported(
                "failed to configure spawned process streams"
            )
        }
        if outputWriter != STDOUT_FILENO {
            guard posix_spawn_file_actions_addclose(
                &actions,
                outputWriter
            ) == 0 else {
                throw SandboxRuntimeError.unsupported(
                    "failed to close spawned process output descriptor"
                )
            }
        }
        if errorWriter != STDERR_FILENO {
            guard posix_spawn_file_actions_addclose(
                &actions,
                errorWriter
            ) == 0 else {
                throw SandboxRuntimeError.unsupported(
                    "failed to close spawned process error descriptor"
                )
            }
        }
        if let currentDirectory {
            let status = currentDirectory.path.withCString {
                posix_spawn_file_actions_addchdir_np(&actions, $0)
            }
            guard status == 0 else {
                throw SandboxRuntimeError.unsupported(
                    "failed to configure spawned process working directory"
                )
            }
        }
        if let cooperativeControl {
            let sourceDescriptor =
                cooperativeControl.inheritedSourceDescriptor
            guard sourceDescriptor >= 0,
                  posix_spawn_file_actions_adddup2(
                      &actions,
                      sourceDescriptor,
                      ProcessControlChannel.childDescriptor
                  ) == 0,
                  sourceDescriptor
                      == ProcessControlChannel.childDescriptor
                      || posix_spawn_file_actions_addclose(
                          &actions,
                          sourceDescriptor
                      ) == 0
            else {
                throw SandboxRuntimeError.unsupported(
                    "failed to inherit cooperative process control channel"
                )
            }
        }
    }

    private func send(signal: Int32) {
        lock.lock()
        defer { lock.unlock() }
        let pid =
            started && signalAttemptsEnabled && exitCode == nil
                ? processIdentifier
                : 0
        guard pid > 0 else {
            return
        }
        signalProcessGroupLocked(pid, signal: signal)
    }

    private func reap(processIdentifier: pid_t) {
        var information = siginfo_t()
        var observationResult: Int32
        repeat {
            observationResult = waitid(
                P_PID,
                id_t(processIdentifier),
                &information,
                WEXITED | WNOWAIT
            )
        } while observationResult < 0 && errno == EINTR

        let observedDirectChildExit = observationResult == 0
        if observedDirectChildExit {
            testHooks.didObserveDirectChildExit?()
        }

        lock.lock()
        directChildExitObserved = observedDirectChildExit
        signalAttemptsEnabled = false
        testHooks.didDisableSignalAttempts?()
        if observedDirectChildExit {
            terminateRemainingProcessGroupLocked(processIdentifier)
        }

        var status: Int32 = 0
        var result: pid_t
        repeat {
            result = waitpid(processIdentifier, &status, 0)
        } while result < 0 && errno == EINTR

        let code: Int32
        if result == processIdentifier {
            let signal = status & 0x7f
            code = signal == 0
                ? (status >> 8) & 0xff
                : 128 + signal
        } else {
            code = 255
        }
        directChildExitObserved = true
        exitCode = code
        lock.unlock()

        cooperativeControl?.closeParentEndpoint()
        cooperativeControl?.closeChildSourceEndpoint()
        exitSignal.signal()
    }

    private func terminateRemainingProcessGroupLocked(_ group: pid_t) {
        signalProcessGroupLocked(group, signal: SIGTERM)
        signalProcessGroupLocked(group, signal: SIGKILL)
    }

    private func signalProcessGroupLocked(_ group: pid_t, signal: Int32) {
        testHooks.willSignalProcessGroup?(group, signal)
        _ = Darwin.kill(-group, signal)
    }

    private static func withCStringArray<T>(
        _ strings: [String],
        operation: (
            UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
        ) throws -> T
    ) throws -> T {
        var pointers: [UnsafeMutablePointer<CChar>?] = []
        pointers.reserveCapacity(strings.count + 1)
        for string in strings {
            guard let pointer = strdup(string) else {
                for allocated in pointers {
                    free(allocated)
                }
                throw POSIXError(.ENOMEM)
            }
            pointers.append(pointer)
        }
        pointers.append(nil)
        defer {
            for pointer in pointers {
                free(pointer)
            }
        }
        return try pointers.withUnsafeMutableBufferPointer {
            try operation($0.baseAddress!)
        }
    }

    struct ProcessOutput {
        let standardOutput: BoundedProcessOutputSnapshot
        let standardError: BoundedProcessOutputSnapshot
    }

    private enum StopEvent: Sendable {
        case exited
        case cooperativeDeadline
        case signalDeadline
    }
}

struct ProcessExecutionTestHooks: @unchecked Sendable {
    let didObserveDirectChildExit: (@Sendable () -> Void)?
    let didDisableSignalAttempts: (@Sendable () -> Void)?
    let willSignalProcessGroup: (@Sendable (pid_t, Int32) -> Void)?

    init(
        didObserveDirectChildExit: (@Sendable () -> Void)? = nil,
        didDisableSignalAttempts: (@Sendable () -> Void)? = nil,
        willSignalProcessGroup:
            (@Sendable (pid_t, Int32) -> Void)? = nil
    ) {
        self.didObserveDirectChildExit = didObserveDirectChildExit
        self.didDisableSignalAttempts = didDisableSignalAttempts
        self.willSignalProcessGroup = willSignalProcessGroup
    }

    static let none = ProcessExecutionTestHooks()
}

private final class ProcessExitSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var exited = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock {
                if exited {
                    return true
                }
                continuations.append(continuation)
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    func signal() {
        let continuations = lock.withLock {
            exited = true
            defer { self.continuations.removeAll(keepingCapacity: false) }
            return self.continuations
        }
        for continuation in continuations {
            continuation.resume()
        }
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T {
        lock()
        defer { unlock() }
        return operation()
    }
}
