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
/// everything they checked is decided again once the command holds the update
/// lease, before anything changes, and stays true until the swap is done:
/// - The update lease (`SelfUpdater.beginUpdateSession`) is the one every
///   install mutation takes: a pair's coordinated update for its whole cycle
///   (`ClusterPairUpdateCycle`, "cluster-auto-update") and its candidate
///   recovery, the watchdog, the in-process auto-update, `darkbloom update`,
///   and every `start`, `stop` and `restart` drain, including the one that
///   installs a cluster member job. A rollback and a pair update never
///   interleave: whichever takes the lease second is refused or waits for the
///   next update slot.
/// - A cluster service starts without the update lease, so under the lease the
///   command also holds the cluster service lock (`ClusterService.holdStopped`)
///   until the swap is done, and refuses when this Mac serves in a pair.
/// - The provider is read again under the lease. One started since the plan,
///   or replaced by a foreground provider (service to foreground), is refused
///   before the drain. A provider that is not running is kept from starting
///   until the swap is done (`ProcessLifecycle.holdStartsOut`); a foreground
///   start takes no update lease.
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
        /// Called under the update lease: holds this Mac's cluster service from starting until released, or nil when
        /// this Mac serves in a cluster pair (as `servesInCluster`).
        var holdClusterOut: () throws -> UpdateProcessLock?
        var provider: () -> Provider
        /// Called under the update lease for a provider that is not running: holds every provider start (launchd or
        /// foreground) out until released, or nil when a provider holds its instance lock.
        var holdProviderStartsOut: () throws -> UpdateProcessLock?
        var canAsk: () -> Bool
        var readAnswer: () -> String?
        /// Drains the running provider service. Called while the command holds the update lease.
        var drain: () async throws -> Void
        /// Relaunches the drained provider and rearms the watchdog.
        var restart: () async throws -> Void
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
        This Mac serves in a two-Mac cluster. Both Macs of a pair run one release, so `\(cli) update --rollback` \
        does not roll back one Mac of a pair. Stop the pair first (`\(cli) cluster stop`, or `\(cli) stop` for a \
        cluster member service), run `\(cli) update --rollback` on each Mac, then start the pair again with \
        `\(cli) cluster`. Nothing was changed.
        """

    static let foregroundRefusal = """
        A provider runs outside its launchd service (`\(cli) start --foreground`), and the rollback cannot drain \
        and restart it. Stop it (Ctrl-C), then run `\(cli) update --rollback` again. Nothing was changed.
        """

    static let startedRefusal = """
        A provider started after the rollback was planned. Nothing was changed; run \
        `\(cli) update --rollback` again to drain and restart it.
        """

    private static var cli: String { BuildEnvironment.current.cliName }

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
        // Under the lease, before anything changes: the plan and the prompt ran
        // without it. Each hold lasts until the swap is done.
        guard let clusterHold = try heldOrRefused({ try host.holdClusterOut() }) else {
            throw Failure(description: Self.clusterRefusal)
        }
        defer { clusterHold.release() }
        let providerNow = host.provider()
        guard providerNow != .foreground else { throw Failure(description: Self.foregroundRefusal) }
        guard loaded || providerNow == .stopped else { throw Failure(description: Self.startedRefusal) }
        // A provider stopped since the plan is swapped without a restart.
        let restarts = providerNow == .service
        var startsHold: UpdateProcessLock?
        if restarts {
            try await host.drain()
        } else {
            guard let hold = try heldOrRefused({ try host.holdProviderStartsOut() }) else {
                throw Failure(description: Self.startedRefusal)
            }
            startsHold = hold
        }
        let outcome = Result { try updater.rollBackToPredecessor(session: session, plan: plan) }
        startsHold?.release()
        clusterHold.release()
        // A drained provider restarts whether or not the rollback completed:
        // the layout is always one complete release (the journal guarantees it).
        var restartFailure: Error?
        if restarts {
            do { try await host.restart() } catch { restartFailure = error }
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

    /// A hold that could not be taken for another reason than contention refuses with nothing changed.
    private func heldOrRefused(_ take: () throws -> UpdateProcessLock?) throws -> UpdateProcessLock? {
        do {
            return try take()
        } catch {
            throw Failure(description: "The rollback could not lock out a concurrent start (\(error)). Nothing was changed.")
        }
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
        // Configured to serve in a pair even while its service is not running: `darkbloom cluster stop` unloads
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
                if LaunchAgent.isLoaded() { return .service }
                return DaemonStateFile.read()?.processIdentity?.isCurrent() == true ? .foreground : .stopped
            },
            holdProviderStartsOut: { try ProcessLifecycle.holdStartsOut(operation: UpdateRollback.operation) },
            canAsk: { isatty(STDIN_FILENO) != 0 },
            readAnswer: { readLine() },
            drain: { try await ServiceDrain.drain(options: options) },
            restart: {
                try await ServiceDrain.stopDrainedProvider(unloadService: false)
                try LaunchAgent.restartAfterDrain()
                ServiceDrain.rearmWatchdog(explicitConfig: configPath)
            },
            waitForRestart: { try await ServiceDrain.waitForRestart(previous: previous, timeout: 180) })
    }
}
