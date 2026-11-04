import ArgumentParser
import Foundation
import ProviderCore

/// `darkbloom update --rollback`: the operator's way back from a bad release on
/// one Mac. It restores the release kept for rollback through the watchdog's
/// journaled rollback (`SelfUpdater.rollBackToPredecessor`) and quarantines the
/// installed one, between the drain and restart `darkbloom update` uses: the
/// running provider drains first, the layout is swapped, then the provider
/// restarts.
///
/// Exclusion (R4-1729-A). The plan and the prompt run without any lock, so
/// once the command holds the update lease it decides everything again:
/// - The update lease (`SelfUpdater.beginUpdateSession`) is the one every
///   install mutation takes: a pair's coordinated update from its check
///   through its install (`ClusterPairUpdateCycle`, "cluster-auto-update") and
///   its candidate recovery, the watchdog, the in-process auto-update,
///   `darkbloom update`, and every `start`, `stop` and `restart` drain,
///   including the one that installs a cluster member job. A rollback and a
///   pair update never mutate the install at once.
/// - Before the drain, under the lease, every refusal leaves the Mac as it
///   was: this Mac serves in a pair (a running cluster service, a loaded
///   cluster service login agent, which also covers a pair cycle's restart
///   after it gave the lease back, or a cluster member job); a provider runs
///   outside its launchd service, also one that replaced the service while the
///   prompt was open (classified by process identity, `classify`); a provider
///   started since the plan; or the installed release changed since the plan.
/// - At the swap, the command decides again what the drain could have let
///   change, and holds it until the swap is done: the cluster service lock
///   (`ClusterService.holdStopped`; a cluster service starts without the
///   lease) and the provider instance lock (`ProcessLifecycle.holdStartsOut`;
///   a foreground start takes no lease). The instance lock may instead stay
///   with the drained service process itself; held by any other process, the
///   rollback is refused and that process is never signalled.
struct UpdateRollback {
    /// This Mac's provider service, injected so tests never reach launchd.
    enum Provider {
        /// The launchd provider service is loaded.
        case service
        /// A provider runs outside launchd (`darkbloom start --foreground`).
        case foreground
        case stopped
    }

    struct Host {
        /// A `darkbloom cluster` service runs or its login agent is loaded, or the provider job runs a cluster member.
        var servesInCluster: () -> Bool
        /// At the swap, under the update lease: holds this Mac's cluster service from starting until released, or nil
        /// when this Mac serves in a cluster pair (as `servesInCluster`).
        var holdClusterOut: () throws -> UpdateProcessLock?
        var provider: () -> Provider
        /// The launchd provider service's process, which the drain drains (nil when none runs).
        var serviceProcess: () -> ProcessIdentity?
        /// At the swap, under the update lease: one try at the provider instance lock, which keeps every provider
        /// start (launchd or foreground) out while held.
        var holdProviderStartsOut: () throws -> UpdateProcessLock.Attempt
        var canAsk: () -> Bool
        var readAnswer: () -> String?
        /// Drains the running provider service, whose process is `drained` (nil when none runs); any other running
        /// provider is refused before anything changes. Called while the command holds the update lease.
        var drain: (_ drained: ProcessIdentity?) async throws -> Void
        /// Relaunches the drained provider and rearms the watchdog. Only `drained` may be stopped. `startsHold`: the
        /// provider instance lock the command holds (no provider runs), released just before the relaunch.
        var restart: (_ drained: ProcessIdentity?, _ startsHold: UpdateProcessLock?) async throws -> Void
        /// Waits until the relaunched provider is freshly authorized.
        var waitForRestart: () async throws -> Void
    }

    /// A refusal or failure, printed as is (a runtime failure, not a usage mistake).
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    let updater: SelfUpdater
    let host: Host
    let say: (String) -> Void

    static let clusterRefusal = """
        This Mac serves in a two-Mac cluster, and `\(cli) update --rollback` does not change one Mac of a running \
        pair. Stop this Mac's cluster service (`\(cli) cluster stop --service`), run `\(cli) update --rollback`, then start \
        it again with `\(cli) cluster`: the other Mac follows the rollback to the same release. For a cluster \
        member service, stop it with `\(cli) stop` and roll back both Macs. Nothing was changed.
        """

    static let foregroundRefusal = """
        A provider runs outside its launchd service (`\(cli) start --foreground`), and the rollback cannot drain \
        and restart it. Stop it (Ctrl-C), then run `\(cli) update --rollback` again. Nothing was changed.
        """

    static let startedRefusal = """
        A provider started after the rollback was planned. Nothing was changed; run \
        `\(cli) update --rollback` again to drain and restart it.
        """

    fileprivate static var cli: String { BuildEnvironment.current.cliName }

    /// The update lease's operation, and the owner the cluster service and provider holds name.
    static let operation = "operator-rollback"

    func run(skipConfirmation: Bool) async throws {
        guard !host.servesInCluster() else { throw Failure(description: Self.clusterRefusal) }
        let provider = host.provider()
        guard provider != .foreground else { throw Failure(description: Self.foregroundRefusal) }
        let plan = try await refusingClearly { try updater.rollbackPlan() }
        let loaded = provider == .service
        Self.describe(plan, providerLoaded: loaded).forEach(say)
        if !skipConfirmation {
            guard host.canAsk() else {
                throw Failure(description: "Confirm in an interactive terminal, or pass --yes to roll back without a prompt.")
            }
            say("Roll back to v\(plan.to)? [y/N]")
            let answer = host.readAnswer()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            guard ["y", "yes"].contains(answer) else {
                say("Nothing changed.")
                return
            }
        }

        let session = try await refusingClearly {
            try updater.beginUpdateSession(operation: Self.operation, timeout: 0)
        }
        defer { session.release() }
        // Under the lease, before anything changes: every refusal here leaves the Mac as it was.
        guard !host.servesInCluster() else { throw Failure(description: Self.clusterRefusal) }
        let providerNow = host.provider()
        guard providerNow != .foreground else { throw Failure(description: Self.foregroundRefusal) }
        guard loaded || providerNow == .stopped else { throw Failure(description: Self.startedRefusal) }
        try await refusingClearly { try updater.confirmRollbackPlan(plan, session: session) }
        // A provider stopped since the plan is swapped without a restart.
        let restarts = providerNow == .service
        let drained = restarts ? host.serviceProcess() : nil
        if restarts { try await host.drain(drained) }

        // At the swap: what the drain let change is decided again and held until the swap is done. The provider
        // instance hold lasts until the relaunch, so no other provider starts and none is signalled.
        let outcome: Result<String, Error>
        var startsHold: UpdateProcessLock?
        do {
            let holds = try holdStartsOut(drained: drained, drainedService: restarts)
            defer { holds.cluster.release() }
            let swapped = Result { try updater.rollBackToPredecessor(session: session, plan: plan) }
            if let starts = holds.starts {
                startsHold = starts
            } else {
                do {
                    startsHold = try afterTheSwap(drained: drained, swapped: swapped)
                } catch let foreign as ForeignStart {
                    throw foreign
                } catch {
                    // The lock could not be opened: the restart still signals only the drained process.
                }
            }
            outcome = swapped
        } catch let refusal as ForeignStart {
            throw Failure(description: refusal.description)
        } catch let refusal where !restarts {
            // Nothing was drained: the refusal stands as it is.
            throw refusal
        } catch {
            outcome = .failure(error)
        }
        if !restarts { startsHold?.release() }
        // A drained provider restarts whether or not the rollback completed:
        // the layout is always one complete release (the journal guarantees it).
        var restartFailure: Error?
        if restarts {
            do { try await host.restart(drained, startsHold) } catch { restartFailure = error }
            startsHold?.release()
        }
        session.release()
        let notRestarted = restartFailure.map {
            " The provider did not restart: \($0). Run `\(Self.cli) restart`."
        } ?? ""

        let restored: String
        switch outcome {
        case .success(let version):
            restored = version
        case .failure(let error):
            let reason = "\(error)"
            throw Failure(description: "Rollback did not complete: \(reason)\(reason.hasSuffix(".") ? "" : ".")"
                + (restarts && restartFailure == nil ? " The provider restarted on the installed release." : notRestarted))
        }
        say("Rolled back: v\(plan.from) -> v\(restored).")
        say("v\(plan.from) is quarantined on this Mac: automatic updates skip it, and the next newer release installs "
            + "normally. To install v\(plan.from) again anyway: \(Self.cli) update --override-quarantine")
        if restartFailure != nil {
            throw Failure(description: "Rolled back to v\(restored)." + notRestarted)
        }
        if restarts {
            say("Provider relaunched on v\(restored); waiting for fresh authorization...")
            try await host.waitForRestart()
        } else {
            say("The provider is not running; `\(Self.cli) start` starts v\(restored).")
        }
    }

    static func describe(_ plan: SelfUpdater.RollbackPlan, providerLoaded: Bool) -> [String] {
        let installed = plan.fromIsCandidate ? "installed, not yet promoted" : "installed"
        return [
            "Roll back this Mac:",
            "  v\(plan.from) (\(installed)) -> v\(plan.to) (the release kept for rollback, install generation \(plan.toGeneration))",
            providerLoaded
                ? "  The provider finishes its accepted requests, stops, and restarts on v\(plan.to)."
                : "  The provider is not running; nothing is drained or restarted.",
            "  v\(plan.from) is quarantined: automatic updates skip it until a newer release is published.",
            "  This rollback is recorded as install generation \(plan.generation).",
        ]
    }

    /// Another process took the provider instance lock while the service drained, or during the swap. The drained
    /// service is not restarted: its restart would signal that process.
    struct ForeignStart: Error, CustomStringConvertible {
        let owner: String
        /// The swap's result when the other process was found after it; nil when found before it.
        var swapped: Result<String, Error>?
        var description: String {
            let what: String
            switch swapped {
            case nil:
                what = "\(owner) started outside the provider service while it drained. Nothing was swapped."
            case .success(let restored)?:
                what = "Rolled back to v\(restored), but \(owner.lowercased()) started outside the provider service "
                    + "during the swap."
            case .failure(let error)?:
                what = "\(owner) started outside the provider service during the swap, and the rollback did not "
                    + "complete: \(error)."
            }
            return what + " The service stays drained with automatic restart off; stop that process, then run "
                + "`\(UpdateRollback.cli) restart`" + (swapped == nil ? " or `\(UpdateRollback.cli) update --rollback` again." : ".")
        }
    }

    /// The drained service kept its instance lock over the swap. If it ended meanwhile, the lock is taken now and
    /// held until the relaunch; held by another process, that process is not signalled (`ForeignStart`).
    private func afterTheSwap(drained: ProcessIdentity?, swapped: Result<String, Error>) throws -> UpdateProcessLock? {
        switch try heldOrRefused({ try host.holdProviderStartsOut() }) {
        case .acquired(let hold):
            return hold
        case .busy(let owner):
            if let drained, owner?.processIdentity == drained { return nil }
            throw ForeignStart(owner: owner.map { "A provider (pid \($0.pid))" } ?? "A provider", swapped: swapped)
        }
    }

    /// At the swap, under the update lease: holds the cluster service lock and, unless the drained service process
    /// still holds it, the provider instance lock (`starts`, nil when the drained process keeps it).
    private func holdStartsOut(drained: ProcessIdentity?, drainedService: Bool)
        throws -> (cluster: UpdateProcessLock, starts: UpdateProcessLock?) {
        guard let cluster = try heldOrRefused({ try host.holdClusterOut() }) else {
            throw Failure(description: drainedService
                ? "This Mac started serving in a two-Mac cluster while the provider drained. Nothing was swapped."
                : Self.clusterRefusal)
        }
        let starts: UpdateProcessLock.Attempt
        do {
            starts = try heldOrRefused({ try host.holdProviderStartsOut() })
        } catch {
            cluster.release()
            throw error
        }
        switch starts {
        case .acquired(let hold):
            return (cluster, hold)
        case .busy(let owner):
            // The drained service still runs and holds its instance lock: no other provider can start either.
            if drainedService, let drained, owner?.processIdentity == drained { return (cluster, nil) }
            cluster.release()
            let holder = owner.map { "A provider (pid \($0.pid))" } ?? "A provider"
            if drainedService { throw ForeignStart(owner: holder) }
            throw Failure(description: "\(holder) holds the provider instance lock. Nothing was changed; stop it, then "
                + "run `\(Self.cli) update --rollback` again.")
        }
    }

    /// A hold that could not be taken for another reason than contention refuses before the swap.
    private func heldOrRefused<Value>(_ take: () throws -> Value) throws -> Value {
        do {
            return try take()
        } catch {
            throw Failure(description: "The rollback could not lock out a concurrent start (\(error)). Nothing was swapped.")
        }
    }

    /// The provider as the rollback treats it: a live process recorded in the daemon state that is not the launchd
    /// job's process runs in the foreground, even beside a loaded job (a crashed job stays loaded; `start
    /// --foreground` does not unload it). Otherwise a loaded job is the service, and nothing else runs.
    static func classify(loaded: Bool, recorded: ProcessIdentity?, launch: ProcessIdentity?) -> Provider {
        if let recorded, recorded != launch { return .foreground }
        return loaded ? .service : .stopped
    }

    /// Lease contention and every rollback refusal print as one plain line.
    private func refusingClearly<Value>(_ body: () async throws -> Value) async throws -> Value {
        do {
            return try await body()
        } catch let refusal as SelfUpdater.RollbackRefusal {
            throw Failure(description: refusal.description)
        } catch UpdateError.lockBusy(let reason, _) {
            throw Failure(description: SelfUpdater.RollbackRefusal.busy(reason).description)
        }
    }
}

extension UpdateRollback.Host {
    static func live(drain options: DrainOptions, configPath: String?) -> Self {
        let previous = LaunchAgent.launchSnapshot()?.process
        // Configured to serve in a pair even while its service is not running: `darkbloom cluster stop --service` unloads
        // the login agent, and the member job runs under the provider's own label.
        let configuredInCluster = {
            ClusterServiceAgent.installedLabels().contains { ClusterServiceAgent.isLoaded(label: $0) }
                || (LaunchAgent.isLoaded() && LaunchAgent.installedJobIsClusterMember())
        }
        return Self(
            servesInCluster: { ClusterService.running() || configuredInCluster() },
            holdClusterOut: {
                // The service lock first: once it is held, no service starts, so the configuration read after it holds.
                guard let hold = try ClusterService.holdStopped(operation: UpdateRollback.operation) else { return nil }
                guard !configuredInCluster() else { hold.release(); return nil }
                return hold
            },
            provider: {
                let recorded = DaemonStateFile.read()?.processIdentity.flatMap { $0.isCurrent() ? $0 : nil }
                return UpdateRollback.classify(loaded: LaunchAgent.isLoaded(), recorded: recorded,
                                               launch: LaunchAgent.launchSnapshot()?.process)
            },
            serviceProcess: { LaunchAgent.launchSnapshot()?.process },
            holdProviderStartsOut: { try ProcessLifecycle.holdStartsOut(operation: UpdateRollback.operation) },
            canAsk: { isatty(STDIN_FILENO) != 0 },
            readAnswer: { readLine() },
            drain: { drained in try await ServiceDrain.drain(options: options, accepts: { $0 == drained }) },
            restart: { drained, startsHold in
                // A held instance lock means no provider runs: there is nothing to stop.
                if startsHold == nil {
                    try await ServiceDrain.stopDrainedProvider(unloadService: false, accepts: { $0 == drained })
                }
                startsHold?.release()
                try LaunchAgent.restartAfterDrain()
                ServiceDrain.rearmWatchdog(explicitConfig: configPath)
            },
            waitForRestart: { try await ServiceDrain.waitForRestart(previous: previous, timeout: 180) })
    }
}
