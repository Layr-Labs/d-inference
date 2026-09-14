import Foundation
import SandboxRuntime

extension LumeVirtualMachineRuntime {
    /// The daemon verifies the root permit and GUI identity before this call.
    /// This path never invokes legacy SSH readiness or mounts tenant media.
    package func runInstaller(_ request: LumeInstallerBootRequest) async throws -> LumeInstallerBootOutcome {
        guard capacityArbiter == nil, configuration.isolatedGuest == nil,
              let lease = configuration.hostRuntimeLease else {
            throw SandboxRuntimeError.unsupported("installer boot requires a dedicated base runtime and exclusive ownership")
        }
        try lease.validateExclusive()
        _ = try await validateRuntime()
        guard validatedRuntime?.files["lume"]?.sha256 == request.runtimeSHA256 else {
            throw SandboxRuntimeError.unsupported("installer runtime differs from the root permit")
        }
        let source = try LumeInstallerBootSource(storage: configuration.storageDirectory, request: request)
        let name = source.candidate.source.name
        let operation = try beginOperation("accountless-installer", name: name)
        defer { endOperation(name: name); withExtendedLifetime(operation) {}; withExtendedLifetime(source) {} }
        try source.validate(requireStagedSnapshot: false)
        if try LumeInstallerBootClaim.existsMatching(request, name: name, storage: configuration.storageDirectory) {
            // Even a claim left before spawn is consumed. Recovery only proves
            // stop; collection must decide whether the guest actually installed.
            try await stopInstallerIgnoringCancellation(name: name)
            try source.validate(requireStagedSnapshot: false)
            try source.requireObserved(await inspect(name: name), stopped: true)
            try Task.checkCancellation()
            return .init(replayed: true, observedRunning: false, nativeExitCode: nil, sourceStopped: true)
        }
        try source.requireObserved(await inspect(name: name), stopped: true)
        try source.validate(requireStagedSnapshot: true)
        try lease.validateExclusive()
        try Task.checkCancellation()
        try LumeInstallerBootClaim.publish(request, name: name, storage: configuration.storageDirectory)
        // From this point no error or cancellation makes the attempt reusable.
        let process: SandboxManagedProcess
        do {
            try Task.checkCancellation()
            try source.validate(requireStagedSnapshot: true)
            var environment = workspace.environment
            environment["DARKBLOOM_VM_PROFILE"] = "installer-v1"
            process = try lease.withInheritedDescriptor { descriptor in
                try processRunner.start(executable: configuration.executable,
                    arguments: storageArguments(["run", name, "--display", "none", "--vnc", "disabled"]),
                    environment: environment, cooperativeControl: LumeLifecycleControl.processControl,
                    runtimeAuthorityDescriptor: descriptor)
            }
        } catch {
            do { try await stopInstallerIgnoringCancellation(name: name) }
            catch let cleanup {
                throw SandboxRuntimeError.cleanupFailed(operation: "accountless installer", primary: String(describing: error),
                    cleanup: String(describing: cleanup))
            }
            throw error
        }
        runningProcesses[name] = process
        let result: SandboxProcessResult, observedRunning: Bool
        do {
            (result, observedRunning) = try await observeInstaller(process, source: source)
            guard result.exitCode == 0, !result.standardOutputTruncated, !result.standardErrorTruncated else {
                throw SandboxRuntimeError.commandFailed(command: "lume accountless installer", exitCode: result.exitCode,
                    stderr: String(decoding: result.standardError, as: UTF8.self))
            }
        } catch {
            do { try await stopInstallerIgnoringCancellation(name: name) }
            catch let cleanup {
                throw SandboxRuntimeError.cleanupFailed(operation: "accountless installer", primary: String(describing: error),
                    cleanup: String(describing: cleanup))
            }
            throw error
        }
        try await stopInstallerIgnoringCancellation(name: name)
        try source.validate(requireStagedSnapshot: false)
        try source.requireObserved(await inspect(name: name), stopped: true)
        try lease.validateExclusive()
        try Task.checkCancellation()
        return .init(replayed: false, observedRunning: observedRunning, nativeExitCode: result.exitCode, sourceStopped: true)
    }

    private func observeInstaller(_ process: SandboxManagedProcess, source: LumeInstallerBootSource) async throws
        -> (SandboxProcessResult, Bool) {
        let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .seconds(source.request.maximumBootSeconds))
        let name = source.candidate.source.name
        var observedRunning = false
        while process.isRunning {
            try Task.checkCancellation()
            guard clock.now < deadline else { throw SandboxRuntimeError.operationTimedOut("accountless installer boot") }
            let record = try await LumeGuestReadinessDeadline.run(clock: clock, deadline: deadline) {
                try await self.inspect(name: name)
            }
            try source.requireObserved(record, stopped: false)
            observedRunning = observedRunning || record?.state == .running
            try await clock.sleep(until: min(deadline, clock.now.advanced(by: .milliseconds(250))))
        }
        return (await process.wait(), observedRunning)
    }

    private func stopInstallerIgnoringCancellation(name: String) async throws {
        try await Task.detached { try await self.stopWithoutOperationFence(name: name, owner: .baseTemplate) }.value
    }
}
