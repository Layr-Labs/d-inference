import Darwin
import Foundation
import SandboxGuestProtocol
import SandboxRuntime

public protocol GuestCommandExecuting: Sendable {
    func execute(_ command: GuestCommand, id: UUID) async throws -> GuestResponse
}

/// The root supervisor only spawns its verified executable. That fresh process
/// irreversibly drops every group and UID before execve of tenant input.
public struct GuestTenantExecutor: GuestCommandExecuting {
    private let executable: URL
    private let configuration: GuestConfiguration

    public init(configuration: GuestConfiguration) throws {
        self.executable = try GuestConfiguration.signedExecutable()
        self.configuration = configuration
    }

    public func prepare() async throws {
        try await Self.quiesceTenant()
    }

    /// Used before the bootstrap shell touches the workspace mount. It is also
    /// repeated before native workspace preparation on every agent restart.
    public static func quiesceTenant() async throws {
        try GuestBootstrapDiagnostic.run(.virtualizedRoot) { try GuestConfiguration.requireVirtualizedRoot() }
        let executable = try GuestBootstrapDiagnostic.run(.guestIdentity) { try GuestConfiguration.signedExecutable() }
        try await GuestBootstrapDiagnostic.runAsync(.guestPolicy) { try await GuestBootstrapValidation.validate() }
        try await GuestTenantCleanup.run(executable: executable)
    }

    public func execute(_ command: GuestCommand, id: UUID) async throws -> GuestResponse {
        try command.validate()
        try GuestNumericIdentity.validate()
        let encoded = try GuestWorkerPayload.encode(command)
        let process = try SandboxProcessRunner().start(
            executable: executable,
            arguments: ["tenant-exec", configuration.workspacePath, encoded],
            environment: ["HOME": "/var/empty", "TMPDIR": "/var/empty"],
            maximumOutputBytes: GuestProtocolLimits.maximumOutputBytes)
        let timedOut = await withTaskCancellationHandler {
            await withTaskGroup(of: Bool.self) { group in
                group.addTask { _ = await process.wait(); return false }
                group.addTask {
                    do { try await Task.sleep(for: .seconds(command.timeoutSeconds)); return true }
                    catch { return false }
                }
                let timeout = await group.next() ?? false
                if timeout || Task.isCancelled {
                    _ = await process.stop(cooperativeGracePeriod: .zero, signalGracePeriod: .seconds(1))
                }
                group.cancelAll()
                while await group.next() != nil {}
                return timeout
            }
        } onCancel: {
            Task { _ = await process.stop(cooperativeGracePeriod: .zero, signalGracePeriod: .seconds(1)) }
        }
        let output = await process.wait()
        let cancelled = Task.isCancelled
        let executable = executable
        let clean = await Task.detached {
            await Self.cleanTenant(executable: executable)
        }.value
        var response = GuestResponse(id: id, success: !timedOut && !cancelled && clean)
        response.exitCode = output.exitCode
        response.standardOutput = output.standardOutput; response.standardError = output.standardError
        response.standardOutputTruncated = output.standardOutputTruncated
        response.standardErrorTruncated = output.standardErrorTruncated
        response.timedOut = timedOut; response.cancelled = cancelled
        response.requiresVMStop = !clean
        if !clean { response.errorCode = "tenant_cleanup_uncertain" }
        else if cancelled { response.errorCode = "command_cancelled" }
        else if timedOut { response.errorCode = "command_timeout" }
        return response
    }

    private static func cleanTenant(executable: URL) async -> Bool {
        // Signaling happens after setuid inside the helper: kernel permissions
        // cannot redirect a reused PID to a host/guest-root process.
        do { try await GuestTenantCleanup.run(executable: executable); return true }
        catch { return false }
    }
}

public enum GuestTenantWorker {
    /// Internal subprocess entry points. Root always uses fixed identity 2001;
    /// callers cannot select another account or pass environment to root code.
    public static func run(arguments: [String]) throws -> Never {
        guard getuid() == 0, geteuid() == 0, let action = arguments.first else {
            throw GuestProtocolError.invalidConfiguration
        }
        try GuestConfiguration.requireVirtualizedRoot()
        try GuestNumericIdentity.validate()
        if action == "tenant-cleanup", arguments.count == 1 {
            try dropIdentity()
            guard kill(-1, SIGKILL) == 0 || errno == ESRCH else {
                throw GuestProtocolError.cleanupUncertain
            }
            exit(0)
        }
        guard action == "tenant-exec", arguments.count == 3, arguments[1] == "/workspace" else {
            throw GuestProtocolError.invalidMessage
        }
        let command = try GuestWorkerPayload.decode(arguments[2])
        let workspace = try GuestWorkspace(path: arguments[1], tenantUID: 2001, tenantGID: 2001)
        let directory = try workspace.directoryDescriptor(command.workingDirectory)
        defer { close(directory) }
        // Resource limits bound guest-process exhaustion. CPU/RAM/disk remain
        // bounded by the host VM configuration and fixed-size workspace disk.
        for (resource, value) in [(RLIMIT_NOFILE, rlim_t(1024)), (RLIMIT_NPROC, rlim_t(256)), (RLIMIT_CORE, rlim_t(0))] {
            var limit = rlimit(rlim_cur: value, rlim_max: value)
            guard setrlimit(resource, &limit) == 0 else { throw GuestProtocolError.unavailable }
        }
        umask(0o077)
        try dropIdentity()
        guard fchdir(directory) == 0 else { throw GuestProtocolError.invalidPath }
        var environment = command.environment
        environment["HOME"] = "/workspace"
        environment["TMPDIR"] = "/workspace/.tmp"
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"
        environment["SHELL"] = "/bin/zsh"
        environment["LANG"] = "en_US.UTF-8"
        let argv = ([command.executable] + command.arguments).map { strdup($0) } + [nil]
        let envp = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        _ = argv.withUnsafeBufferPointer { args in
            envp.withUnsafeBufferPointer { env in execve(command.executable, args.baseAddress!, env.baseAddress!) }
        }
        exit(errno == ENOENT ? 127 : 126)
    }

    private static func dropIdentity() throws {
        guard setgroups(0, nil) == 0, setgid(2001) == 0, setuid(2001) == 0,
              getuid() == 2001, geteuid() == 2001, getgid() == 2001, getegid() == 2001,
              setuid(0) == -1 else { throw GuestProtocolError.invalidConfiguration }
    }
}
