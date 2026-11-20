import ArgumentParser
import Foundation
import ProviderCore

extension Start {
    /// Which network-serving start this is: what a refused one asks launchd for.
    enum ServiceLaunchRole: Equatable, Sendable {
        /// `start --foreground`: the provider's job.
        case provider
        /// `--cluster-member --supervise`: the always-on member's job.
        case memberSupervisor
        /// `--cluster-member`: a part its service starts; a refused one asks for nothing.
        case part
    }

    /// Tests stand in for the verdict and for launchd (`requireServiceLaunch`), as if enforced.
    struct ServiceLaunchTesting: Sendable {
        var verdict: ServiceLaunchCheck.Verdict
        var startService: @Sendable (ServiceLaunchRole) -> Bool
    }

    @TaskLocal static var serviceLaunchForTesting: ServiceLaunchTesting?

    /// What a refused start says, or nil when it may serve the network.
    static func serviceLaunchRefusal(_ verdict: ServiceLaunchCheck.Verdict) -> [String]? {
        guard case .refuse(let refusal) = verdict else { return nil }
        let cli = BuildEnvironment.current.cliName
        if refusal == .originalParentUnreported {
            return ["\(cli): this Mac does not serve the network before macOS 15.4.",
                    ProviderOnboardingPolicy.upgradeGuidance,
                    "To serve only this Mac in this terminal, run `\(cli) start --local --here`."]
        }
        return ["\(cli): this copy does not serve the network: only Darkbloom's background service does.",
                "Start the service with `\(cli) start`; to serve only this Mac in this terminal, run `\(cli) start --local --here`."]
    }

    /// First thing a network-serving start does (provider, always-on member supervisor, cluster member): a release
    /// build refuses unless Darkbloom's launchd service started this process (`ServiceLaunchCheck`), asks launchd to
    /// start the service instead (not for a part, which its service starts, nor for `.originalParentUnreported`, where
    /// the service would be refused too), and exits 1.
    static func requireServiceLaunch(_ role: ServiceLaunchRole) throws {
        if let testing = serviceLaunchForTesting {
            return try requireServiceLaunch(role, enforced: true, verdict: { testing.verdict },
                                            startService: testing.startService)
        }
        try requireServiceLaunch(role, enforced: ServiceLaunchCheck.enforcedInThisBuild,
                                 verdict: { ServiceLaunchCheck.live() },
                                 startService: { ServiceLaunchCheck.startProviderJob(clusterMember: $0 == .memberSupervisor) })
    }

    static func requireServiceLaunch(_ role: ServiceLaunchRole, enforced: Bool, verdict: () -> ServiceLaunchCheck.Verdict,
                                     startService: (ServiceLaunchRole) -> Bool) throws {
        guard enforced else { return }
        let decision = verdict()
        guard let lines = serviceLaunchRefusal(decision) else { return }
        for line in lines { printError(line) }
        if role != .part, decision != .refuse(.originalParentUnreported) {
            printError(startService(role)
                ? "Asked launchd to start Darkbloom's service if it isn't running."
                : "Darkbloom's service is not running; `\(BuildEnvironment.current.cliName) start` starts it.")
        }
        throw ExitCode.failure
    }
}
