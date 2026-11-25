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

    /// Tests stand in for the verdicts and for launchd (`requireServiceLaunch`), as if enforced.
    struct ServiceLaunchTesting: Sendable {
        var verdict: ServiceLaunchCheck.Verdict
        var startService: @Sendable (ServiceLaunchRole) -> Bool
        var volumeVerdict: ServingVolumeCheck.Verdict = .serve
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

    /// What a start says when this copy runs from a volume other than the Mac's internal disk, or nil when it may
    /// serve the network.
    static func servingVolumeRefusal(_ verdict: ServingVolumeCheck.Verdict) -> [String]? {
        guard case .refuse(let path, let mountPoint, let placement) = verdict else { return nil }
        let cli = BuildEnvironment.current.cliName
        let volume = mountPoint.map { " (\($0))" } ?? ""
        let place = switch placement {
        case .networkVolume: "a network volume"
        case .diskImage: "a disk image"
        case .removableMedia: "removable media"
        case .externalDisk: "an external disk"
        case .unknown: "a volume Darkbloom can't identify"
        }
        return ["\(cli): this copy does not serve the network: Darkbloom serves only from this Mac's internal disk, "
                    + "and \(path) is on \(place)\(volume).",
                "Install Darkbloom in /Applications on the internal disk, then start the service with `\(cli) start`."]
    }

    /// First thing a network-serving start does (provider, always-on member supervisor, cluster member): a release
    /// build refuses unless Darkbloom's launchd service started this process (`ServiceLaunchCheck`), asks launchd to
    /// start the service instead (not for a part, which its service starts, nor for `.originalParentUnreported`, where
    /// the service would be refused too), and exits 1. When refusing off the internal disk is on
    /// (`ServingVolumeCheck.refuses`), it then refuses, and exits 1, when this copy runs from anywhere but the Mac's
    /// internal disk.
    static func requireServiceLaunch(_ role: ServiceLaunchRole) throws {
        if let testing = serviceLaunchForTesting {
            return try requireServiceLaunch(role, enforced: true, verdict: { testing.verdict },
                                            volumeVerdict: { testing.volumeVerdict },
                                            startService: testing.startService)
        }
        try requireServiceLaunch(role, enforced: ServiceLaunchCheck.enforcedInThisBuild,
                                 verdict: { ServiceLaunchCheck.live() },
                                 volumeVerdict: { ServingVolumeCheck.refuses() ? ServingVolumeCheck.liveAtStart : .serve },
                                 startService: { ServiceLaunchCheck.startProviderJob(clusterMember: $0 == .memberSupervisor) })
    }

    static func requireServiceLaunch(_ role: ServiceLaunchRole, enforced: Bool, verdict: () -> ServiceLaunchCheck.Verdict,
                                     volumeVerdict: () -> ServingVolumeCheck.Verdict = { .serve },
                                     startService: (ServiceLaunchRole) -> Bool) throws {
        guard enforced else { return }
        let decision = verdict()
        if let lines = serviceLaunchRefusal(decision) {
            for line in lines { printError(line) }
            if role != .part, decision != .refuse(.originalParentUnreported) {
                printError(startService(role)
                    ? "Asked launchd to start Darkbloom's service if it isn't running."
                    : "Darkbloom's service is not running; `\(BuildEnvironment.current.cliName) start` starts it.")
            }
            throw ExitCode.failure
        }
        if let lines = servingVolumeRefusal(volumeVerdict()) {
            for line in lines { printError(line) }
            throw ExitCode.failure
        }
    }
}
