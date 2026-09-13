import Darwin
import Foundation
import SandboxCore
import SandboxGuestProtocol
import SandboxRuntime

extension LumeVirtualMachineRuntime {
    func prepareIsolatedGuest(name: String, instanceID: UUID,
                              workspaceBytes: UInt64, stopped: Bool) async throws {
        guard let settings = configuration.isolatedGuest else { return }
        guard let hostLease = configuration.hostRuntimeLease else {
            throw SandboxRuntimeError.unsupported("isolated VM requires exclusive host ownership")
        }
        try hostLease.validate()
        try await SandboxStorageEncryption.requireEncryptedAPFS(at: configuration.storageDirectory, runner: processRunner)
        let directory = configuration.storageDirectory.appendingPathComponent(name)
        let material: LumeGuestMaterials
        if stopped {
            material = try await settings.prepare(in: directory, instanceID: instanceID,
                                                 workspaceBytes: workspaceBytes, runner: processRunner)
            // Stopped proof precedes replacement of the previous owner's endpoint.
            guestEndpoints[name] = try LumeGuestEndpoint()
        } else {
            material = try settings.load(in: directory, instanceID: instanceID, workspaceBytes: workspaceBytes)
            guard guestEndpoints[name] != nil else {
                throw SandboxRuntimeError.unsupported("running VM has no authenticated broker channel; reconcile it before reuse")
            }
        }
        isolatedGuests[name] = material
    }

    func isolatedStartArguments(name: String) throws -> [String] {
        guard configuration.isolatedGuest != nil else { return [] }
        guard let material = isolatedGuests[name], guestEndpoints[name] != nil else {
            throw SandboxRuntimeError.unsupported("isolated guest material is unavailable")
        }
        return ["--mount", material.controlDisk.path, "--disk", material.workspaceDisk.path]
    }

    func startManagedRun(name: String, scope: SandboxOperationScope?) throws -> SandboxManagedProcess {
        let arguments = storageArguments(["run", name, "--display", "none", "--vnc", "disabled"]
            + (try isolatedStartArguments(name: name)) + (try baseImageShareArguments(scope: scope)))
        let environment = try isolatedStartEnvironment(name: name)
        func launch(_ descriptor: Int32?) throws -> SandboxManagedProcess {
            try processRunner.start(executable: configuration.executable, arguments: arguments,
                environment: environment, cooperativeControl: LumeLifecycleControl.processControl,
                runtimeAuthorityDescriptor: descriptor)
        }
        if configuration.isolatedGuest != nil, let lease = configuration.hostRuntimeLease {
            return try lease.withInheritedDescriptor { try launch($0) }
        }
        guard configuration.isolatedGuest == nil else {
            throw SandboxRuntimeError.unsupported("isolated VM requires exclusive host ownership")
        }
        return try launch(nil)
    }

    func isolatedStartEnvironment(name: String) throws -> [String: String] {
        var environment = workspace.environment
        guard configuration.isolatedGuest != nil else { return environment }
        guard let endpoint = guestEndpoints[name] else {
            throw SandboxRuntimeError.unsupported("isolated guest endpoint is unavailable")
        }
        environment["DARKBLOOM_VM_PROFILE"] = "isolated-v1"
        environment["DARKBLOOM_GUEST_SOCKET"] = endpoint.socketURL.path
        return environment
    }

    func isolatedGuestClient(name: String) throws -> LumeGuestClient {
        guard let material = isolatedGuests[name], let endpoint = guestEndpoints[name] else {
            throw SandboxRuntimeError.unsupported("isolated guest endpoint is unavailable")
        }
        return try LumeGuestClient(socketURL: endpoint.socketURL, instanceID: material.instanceID,
                                   credential: material.credential)
    }

    func waitForIsolatedGuest(name: String, timeoutSeconds: UInt32) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeoutSeconds))
        repeat {
            try Task.checkCancellation()
            if let process = runningProcesses[name], !process.isRunning {
                throw SandboxRuntimeError.unsupported("VM owner exited before guest readiness")
            }
            do {
                let client = try isolatedGuestClient(name: name)
                let result = try await client.request(GuestRequest(operation: .ping), timeoutSeconds: 2)
                guard result.success, result.requiresVMStop != true else {
                    throw SandboxRuntimeError.unsupported("guest rejected readiness")
                }
                return
            } catch is CancellationError { throw CancellationError() }
            catch { /* A booting guest does not yet accept connections. */ }
            try await clock.sleep(until: min(deadline, clock.now.advanced(by: .milliseconds(250))))
        } while clock.now < deadline
        throw SandboxRuntimeError.operationTimedOut("\(name) authenticated guest readiness")
    }

    func runIsolatedGuestCommand(name: String, request: SandboxGuestCommandRequest) async throws -> Data {
        let relative: String
        if request.workingDirectory == "/workspace" { relative = "" }
        else if request.workingDirectory.hasPrefix("/workspace/") {
            relative = String(request.workingDirectory.dropFirst("/workspace/".count))
        } else { throw GuestProtocolError.invalidPath }
        let command = GuestCommand(executable: request.executable, arguments: request.arguments,
                                   environment: request.environment, workingDirectory: relative,
                                   timeoutSeconds: request.timeoutSeconds)
        try command.validate()
        let response = try await isolatedGuestClient(name: name).request(
            GuestRequest(id: request.idempotencyKey, operation: .execute, command: command),
            timeoutSeconds: request.timeoutSeconds + 15)
        try Task.checkCancellation()
        return try LumeIsolatedGuestResult.envelope(response)
    }
}

enum LumeIsolatedGuestResult {
    /// A completed timeout has a failed execution status but still contains a
    /// valid result. Preserve it so the durable journal and existing timeout
    /// cleanup path can classify and replay it consistently.
    static func envelope(_ response: GuestResponse) throws -> Data {
        guard response.requiresVMStop == false, response.cancelled == false,
              let exitCode = response.exitCode, let stdout = response.standardOutput,
              let stderr = response.standardError,
              let stdoutTruncated = response.standardOutputTruncated,
              let stderrTruncated = response.standardErrorTruncated,
              let timedOut = response.timedOut,
              response.success || timedOut else {
            throw SandboxRuntimeError.unsupported("guest execution or descendant cleanup was not proven")
        }
        return try LumeGuestCommandResultDecoder.encode(SandboxGuestCommandResult(
            // The journal contract uses 124 for timeout, independently of the
            // terminating signal observed by the guest process supervisor.
            exitCode: timedOut ? 124 : exitCode, standardOutput: stdout, standardError: stderr,
            standardOutputTruncated: stdoutTruncated, standardErrorTruncated: stderrTruncated,
            timedOut: timedOut))
    }
}

/// Each VM owner receives a unique short socket path. The directory is private
/// and allocated atomically; it is not a persistent lease or ownership record.
final class LumeGuestEndpoint: @unchecked Sendable {
    let directory: URL
    let socketURL: URL
    private let identity: stat

    init() throws {
        var template = Array("/private/tmp/dbsb.XXXXXXXXXXXX".utf8CString)
        guard mkdtemp(&template) != nil else { throw GuestProtocolError.unavailable }
        directory = URL(fileURLWithPath: String(cString: template))
        socketURL = directory.appendingPathComponent("guest.sock")
        var metadata = stat()
        guard lstat(directory.path, &metadata) == 0 else { throw GuestProtocolError.unavailable }
        identity = metadata
    }

    deinit {
        var current = stat()
        guard lstat(directory.path, &current) == 0,
              current.st_dev == identity.st_dev, current.st_ino == identity.st_ino,
              current.st_uid == geteuid() else { return }
        // The VM's bridge normally removes this entry. Never recurse over a
        // directory if an unexpected entry has appeared.
        var socket = stat()
        if lstat(socketURL.path, &socket) == 0, socket.st_mode & S_IFMT == S_IFSOCK,
           socket.st_uid == geteuid() { _ = unlink(socketURL.path) }
        _ = rmdir(directory.path)
    }
}
