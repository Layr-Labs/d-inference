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

struct SandboxManagedProcessStopPolicy: Sendable {
    let cooperativeGracePeriod: Duration
    let signalGracePeriod: Duration

    static let deinitialization = SandboxManagedProcessStopPolicy(
        cooperativeGracePeriod: .seconds(30),
        signalGracePeriod: .seconds(2)
    )
}

public final class SandboxManagedProcess: @unchecked Sendable {
    private let execution: ProcessExecution
    private let deinitStopPolicy: SandboxManagedProcessStopPolicy

    init(
        execution: ProcessExecution,
        deinitStopPolicy: SandboxManagedProcessStopPolicy = .deinitialization
    ) {
        self.execution = execution
        self.deinitStopPolicy = deinitStopPolicy
    }

    deinit {
        let retainedExecution = execution
        _ = retainedExecution.requestCooperativeStop()
        let policy = deinitStopPolicy
        Task.detached(priority: .utility) {
            await retainedExecution.stop(
                cooperativeGracePeriod: policy.cooperativeGracePeriod,
                signalGracePeriod: policy.signalGracePeriod
            )
            retainedExecution.cleanup()
        }
    }

    public var isRunning: Bool {
        execution.isRunning
    }

    /// Returns a guest descriptor handed over by this process, or `nil` when
    /// none has arrived yet. Never blocks. Ownership transfers to the caller,
    /// which must close it.
    public func receiveGuestChannelDescriptor() throws -> Int32? {
        try execution.receiveGuestChannelDescriptor()
    }

    /// The host end of this VM's link-layer connection, when one was attached.
    ///
    /// Borrowed, not transferred: the execution closes it on teardown, so a
    /// gateway reading frames here stops when the VM does. That is what makes
    /// the network fail closed without anything having to notice the exit.
    public var networkGatewayDescriptor: Int32? {
        execution.networkGatewayDescriptor
    }

    public func wait() async -> SandboxProcessResult {
        await execution.waitUntilExit()
        return execution.result()
    }

    public func stop(
        cooperativeGracePeriod: Duration = .seconds(30),
        signalGracePeriod: Duration = .seconds(2)
    ) async
        -> SandboxProcessResult
    {
        await execution.stop(
            cooperativeGracePeriod: cooperativeGracePeriod,
            signalGracePeriod: signalGracePeriod
        )
        return execution.result()
    }
}

public struct SandboxProcessRunner: Sendable {
    public static let defaultMaximumOutputBytes = 4 * 1_048_576

    public init() {}

    public func start(
        executable: URL,
        arguments: [String],
        environment: [String: String] = [:],
        currentDirectory: URL? = nil,
        maximumOutputBytes: Int = defaultMaximumOutputBytes,
        cooperativeControl: SandboxCooperativeProcessControl? = nil,
        guestChannel: SandboxGuestChannelControl? = nil,
        networkGateway: SandboxNetworkGatewayControl? = nil
    ) throws -> SandboxManagedProcess {
        try validate(
            executable: executable,
            timeoutSeconds: nil,
            maximumOutputBytes: maximumOutputBytes
        )
        try validateInvocation(
            arguments: arguments,
            environment: environment,
            currentDirectory: currentDirectory,
            cooperativeControl: cooperativeControl,
            guestChannel: guestChannel,
            networkGateway: networkGateway
        )
        let execution = try ProcessExecution(
            executable: executable,
            arguments: arguments,
            environment: Self.environment(overrides: environment),
            currentDirectory: currentDirectory,
            maximumOutputBytes: maximumOutputBytes,
            cooperativeControl: cooperativeControl,
            guestChannel: guestChannel,
            networkGateway: networkGateway
        )
        do {
            try execution.start()
        } catch {
            execution.cleanup()
            throw error
        }
        return SandboxManagedProcess(execution: execution)
    }

    public func run(
        executable: URL,
        arguments: [String],
        environment: [String: String] = [:],
        currentDirectory: URL? = nil,
        timeoutSeconds: UInt32,
        maximumOutputBytes: Int = defaultMaximumOutputBytes
    ) async throws -> SandboxProcessResult {
        try validate(
            executable: executable,
            timeoutSeconds: timeoutSeconds,
            maximumOutputBytes: maximumOutputBytes
        )
        try validateInvocation(
            arguments: arguments,
            environment: environment,
            currentDirectory: currentDirectory,
            cooperativeControl: nil
        )

        let execution = try ProcessExecution(
            executable: executable,
            arguments: arguments,
            environment: Self.environment(overrides: environment),
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
            return execution.result(output: output)
        case .timedOut:
            throw SandboxRuntimeError.operationTimedOut(
                executable.lastPathComponent
            )
        case .cancelled:
            throw CancellationError()
        }
    }

    private func validate(
        executable: URL,
        timeoutSeconds: UInt32?,
        maximumOutputBytes: Int
    ) throws {
        guard executable.isFileURL,
              FileManager.default.isExecutableFile(atPath: executable.path)
        else {
            throw SandboxRuntimeError.executableNotFound(executable.path)
        }
        guard timeoutSeconds.map({ $0 > 0 }) ?? true,
              maximumOutputBytes > 0
        else {
            throw SandboxRuntimeError.unsupported(
                "process timeout and output limit must be positive"
            )
        }
    }

    private func validateInvocation(
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL?,
        cooperativeControl: SandboxCooperativeProcessControl?,
        guestChannel: SandboxGuestChannelControl? = nil,
        networkGateway: SandboxNetworkGatewayControl? = nil
    ) throws {
        guard arguments.allSatisfy({ !$0.contains("\0") }),
              environment.allSatisfy({
                  !$0.key.isEmpty
                      && !$0.key.contains("=")
                      && !$0.key.contains("\0")
                      && !$0.value.contains("\0")
              }),
              currentDirectory.map({
                  $0.isFileURL && $0.baseURL == nil
              }) ?? true,
              cooperativeControl.map({
                  Self.isValidEnvironmentVariable($0.environmentVariable)
                      && environment[$0.environmentVariable] == nil
              }) ?? true,
              guestChannel.map({
                  Self.isValidEnvironmentVariable(
                      $0.descriptorEnvironmentVariable
                  )
                      && Self.isValidEnvironmentVariable(
                          $0.portEnvironmentVariable
                      )
                      && $0.descriptorEnvironmentVariable
                          != $0.portEnvironmentVariable
                      && $0.descriptorEnvironmentVariable
                          != cooperativeControl?.environmentVariable
                      && $0.portEnvironmentVariable
                          != cooperativeControl?.environmentVariable
                      && environment[$0.descriptorEnvironmentVariable] == nil
                      && environment[$0.portEnvironmentVariable] == nil
                      && $0.port > 0
              }) ?? true,
              // Its own variable, distinct from every other channel's: two
              // channels sharing a name would silently overwrite one another.
              networkGateway.map({
                  Self.isValidEnvironmentVariable(
                      $0.descriptorEnvironmentVariable
                  )
                      && $0.descriptorEnvironmentVariable
                          != cooperativeControl?.environmentVariable
                      && $0.descriptorEnvironmentVariable
                          != guestChannel?.descriptorEnvironmentVariable
                      && $0.descriptorEnvironmentVariable
                          != guestChannel?.portEnvironmentVariable
                      && environment[$0.descriptorEnvironmentVariable] == nil
              }) ?? true
        else {
            throw SandboxRuntimeError.unsupported(
                "process arguments, environment, or working directory are invalid"
            )
        }
    }

    private static func isValidEnvironmentVariable(_ value: String) -> Bool {
        guard let first = value.utf8.first,
              first == 95 || (65...90).contains(first)
                  || (97...122).contains(first)
        else {
            return false
        }
        return value.utf8.dropFirst().allSatisfy {
            $0 == 95 || (65...90).contains($0)
                || (97...122).contains($0)
                || (48...57).contains($0)
        }
    }

    private static func environment(
        overrides: [String: String]
    ) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var environment: [String: String] = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "LANG": inherited["LANG"] ?? "en_US.UTF-8",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": NSTemporaryDirectory(),
        ]
        for (key, value) in overrides {
            environment[key] = value
        }
        return environment
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
                await execution.stop(
                    cooperativeGracePeriod: .zero,
                    signalGracePeriod: .seconds(2)
                )
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
