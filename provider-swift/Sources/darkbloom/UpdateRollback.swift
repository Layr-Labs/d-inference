import ArgumentParser
import Foundation
import ProviderCore

/// `darkbloom update --rollback`: the operator's way back from a bad release on
/// one Mac. It restores the release kept for rollback through the watchdog's
/// journaled rollback (`SelfUpdater.rollBackToPredecessor`) and quarantines the
/// installed one, between the drain and restart `darkbloom update` uses: the
/// running provider drains first (the drain holds the update lease), the
/// layout is swapped, then the provider restarts.
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
        /// A `darkbloom cluster` service runs, or the provider job runs a cluster member.
        var servesInCluster: () -> Bool
        var provider: () -> Provider
        var canAsk: () -> Bool
        var readAnswer: () -> String?
        /// Drains the running provider and returns the update lease the drain holds.
        var drain: () async throws -> SelfUpdater.UpdateSession
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
            if loaded { return try await host.drain() }
            return try updater.beginUpdateSession(operation: "operator-rollback", timeout: 0)
        }
        defer { session.release() }
        // The plan and prompt ran without the lease: a provider started since
        // is not swapped under, and one stopped since is not restarted.
        let providerNow = host.provider()
        guard loaded || providerNow == .stopped else { throw Failure(description: Self.startedRefusal) }
        let restarts = loaded && providerNow == .service
        let outcome = Result { try updater.rollBackToPredecessor(session: session, plan: plan) }
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
        return Self(
            servesInCluster: {
                ClusterService.running() || (LaunchAgent.isLoaded() && LaunchAgent.installedJobIsClusterMember())
            },
            provider: {
                if LaunchAgent.isLoaded() { return .service }
                return DaemonStateFile.read()?.processIdentity?.isCurrent() == true ? .foreground : .stopped
            },
            canAsk: { isatty(STDIN_FILENO) != 0 },
            readAnswer: { readLine() },
            drain: { try await ServiceDrain.prepare(options: options) },
            restart: {
                try await ServiceDrain.stopDrainedProvider(unloadService: false)
                try LaunchAgent.restartAfterDrain()
                ServiceDrain.rearmWatchdog(explicitConfig: configPath)
            },
            waitForRestart: { try await ServiceDrain.waitForRestart(previous: previous, timeout: 180) })
    }
}
