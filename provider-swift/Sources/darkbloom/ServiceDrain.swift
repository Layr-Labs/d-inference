import ArgumentParser
import Foundation
import ProviderCore

struct DrainOptions: ParsableArguments {
    @Option(help: "Seconds to wait for accepted requests and coordinator acknowledgement (0...3600). Timeout leaves the service draining.")
    var timeout: Int = 600
    @Flag(help: "Explicitly permit cancellation and interruption of unfinished requests.")
    var force = false

    mutating func validate() throws {
        guard (0...3600).contains(timeout) else { throw ValidationError("--timeout must be between 0 and 3600 seconds") }
    }
}

/// The CLI never initiates graceful stop with bootout/kickstart. The signed
/// daemon owns admission, accepted requests, terminal delivery and the barrier.
enum ServiceDrain {
    static func prepare(options: DrainOptions,
                        withConfigurationChange: (_ setup: () throws -> Void) throws -> Void = { try $0() }) async throws -> SelfUpdater.UpdateSession {
        let state = DaemonStateFile.read()
        let updater = SelfUpdater(coordinatorBaseURL: state?.coordinatorUrl ?? "https://api.darkbloom.dev")
        let session = try updater.beginUpdateSession(operation: "provider-lifecycle", timeout: 0)
        do {
            let identity = WatchdogProbe.providerIdentity(daemonState: state, launchSnapshotProcess: LaunchAgent.launchSnapshot()?.process)
            if let identity, identity.isCurrent(), !options.force {
                guard state?.processIdentity == identity, state?.lifecycle != nil else {
                    throw ValidationError("This running provider does not expose graceful-drain control. Upgrade it, or explicitly use --force to interrupt it.")
                }
            }
            let hasControl = identity?.isCurrent() == true && state?.processIdentity == identity && state?.lifecycle != nil
            if !hasControl && !options.force && LaunchAgent.launchSnapshot()?.process != nil {
                throw ValidationError("Cannot confirm the running provider identity. No process or recovery setting was changed.")
            }
            let request = identity.flatMap { hasControl ? ProviderDrainRequest(target: $0, timeoutSeconds: options.timeout, force: options.force) : nil }
            let mailbox = identity.map { LifecycleMailbox(identity: $0) }
            let recovery = try ServiceRecoverySnapshot.capture()
            try withConfigurationChange {
                try publishWithRecoveryRollback(disable: {
                    try WatchdogAgent.stop()
                    try LaunchAgent.disableAutomaticStartup()
                }, publish: {
                    if let request, let mailbox { try mailbox.writeRequest(request) }
                }, restore: { try recovery.restore() })
            }
            // Only a published request (or a confirmed stopped process) may
            // discard prior recovery history. Later drain timeouts stay fenced.
            try? FileManager.default.removeItem(at: WatchdogStateStore.path())

            if let request, let mailbox {
                print("Draining accepted requests (deadline: \(options.timeout)s). New work is refused by the running provider.")
                do {
                    let result = try await wait(request: request, mailbox: mailbox)
                    let confirmation = result.coordinatorAcknowledged ? "received" : (result.outcome == .drained ? "not needed (no coordinator connection)" : "unconfirmed")
                    print("Drain \(result.outcome.rawValue): \(result.remaining) unfinished request(s); coordinator acknowledgement: \(confirmation).")
                } catch {
                    guard options.force else { throw error }
                    print("Forced stop: drain acknowledgement unavailable; unfinished work will be interrupted.")
                }
            } else if options.force {
                print("Forced lifecycle requested: unfinished work may be interrupted; completion is unconfirmed.")

            }
            if options.force, let identity, identity.isCurrent() {
                guard ProcessLifecycle.terminate(identity, gracePeriod: 1) else {
                    throw ValidationError("Forced termination did not finish; the service remains disabled.")
                }
            }
            return session
        } catch {
            session.release()
            throw error
        }
    }

    /// Stop only a confirmed drained owner. A PID file alone never authorizes
    /// signalling a process, and ordinary replacement never escalates to SIGKILL.
    static func stopDrainedProvider(unloadService: Bool = true) async throws {
        let launchIdentity = LaunchAgent.launchSnapshot()?.process
        let identity = WatchdogProbe.providerIdentity(daemonState: DaemonStateFile.read(),
                                                      launchSnapshotProcess: LaunchAgent.launchSnapshot()?.process)
        // Restart must retain the loaded label until restartAfterDrain captures
        // its original plist (including installations under a legacy label).
        if !unloadService && identity == launchIdentity { return }
        if unloadService && launchIdentity?.pid != ProcessInfo.processInfo.processIdentifier {
            try LaunchAgent.stop()
        }
        guard let identity, identity.pid != ProcessInfo.processInfo.processIdentifier, identity.isCurrent() else { return }
        try ProcessLifecycle.requestTermination(identity)
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while identity.isCurrent(), ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard !identity.isCurrent() else {
            throw ValidationError("The drained provider is still shutting down. No replacement was started. Retry or explicitly use --force.")
        }
    }

    static func prepareForegroundReplacement(options: DrainOptions) async throws {
        guard let pid = ProcessLifecycle.existingPID(), pid != ProcessInfo.processInfo.processIdentifier,
              ProcessIdentity.read(pid: pid) != nil else { return }
        guard DaemonStateFile.read()?.processIdentity == ProcessIdentity.read(pid: pid) else {
            throw ValidationError("A live process owns the provider PID file, but its identity cannot be confirmed. No process was stopped.")
        }
        guard LaunchAgent.launchSnapshot()?.process?.pid != ProcessInfo.processInfo.processIdentifier else {
            throw ValidationError("The previous provider is still exiting. This launch did not replace or signal it; retry after it finishes.")
        }
        let session = try await prepare(options: options)
        defer { session.release() }
        try await stopDrainedProvider()
    }

    static func wait(request: ProviderDrainRequest, mailbox: LifecycleMailbox) async throws -> ProviderDrainStatus {
        let allowance = request.force ? 15 : request.timeoutSeconds + 10
        let deadline = ContinuousClock.now.advanced(by: .seconds(allowance))
        var lastRemaining: Int?
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if let status = mailbox.readStatus(), status.requestID == request.id {
                if lastRemaining != status.remaining {
                    if status.outcome == .draining && status.remaining == 0 && !status.coordinatorAcknowledged {
                        print("  Requests finished; waiting for coordinator usage acknowledgement")
                    } else {
                        print("  \(status.remaining) accepted request(s) remaining")
                    }
                    lastRemaining = status.remaining
                }
                switch status.outcome {
                case .drained, .forced: return status
                case .timedOut, .busy:
                    throw ValidationError("Drain did not complete: \(status.remaining) unfinished request(s), coordinator acknowledgement \(status.coordinatorAcknowledged). The service remains draining with automatic restart disabled. Repeat stop/restart to wait again, or explicitly pass --force.")
                case .serving, .draining: break
                }
            }
            guard request.target.isCurrent() else {
                throw ValidationError("Provider exited before confirming its drain. Completion is unconfirmed; no restart was issued.")
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw ValidationError("No completed drain acknowledgement before the deadline. Service remains disabled and may still be draining. Repeat stop/restart, or explicitly use --force.")
    }

    static func waitForRestart(previous: ProcessIdentity?, timeout: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if let state = DaemonStateFile.read(),
               restartReady(state: state, previous: previous, now: Date().timeIntervalSince1970) {
                print("Provider restarted and freshly authorized (\(state.trust?.authorization?.path ?? "unknown")).")
                return
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw ValidationError("Restart launched, but fresh authorization was not confirmed within \(timeout)s. The new service is still starting; inspect darkbloom status. No second restart was issued.")
    }
    static func restartReady(state: DaemonState, previous: ProcessIdentity?, now: Double,
                             isCurrent: (ProcessIdentity) -> Bool = { $0.isCurrent() }) -> Bool {
        guard !state.isStale(now: now), let identity = state.processIdentity,
              identity != previous, isCurrent(identity), let trust = state.trust,
              trust.receivedAt >= state.startedAt, trust.receivedAt <= now, now - trust.receivedAt <= 90,
              trust.status == "online" || trust.status == "serving", let auth = trust.authorization else { return false }
        return auth.hasCurrentAppAttestAuthorization(now: now) || ((auth.path == "legacy" || auth.path == "self_route") && !auth.sessionID.isEmpty)
    }

}
