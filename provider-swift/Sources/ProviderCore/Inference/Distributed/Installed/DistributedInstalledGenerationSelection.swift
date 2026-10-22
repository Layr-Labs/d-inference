import DarkbloomClusterProtocol

/// The saved generation mode as worker arguments, beside the prefill schedule.
///
/// The pipeline is the absence of the argument, so a setup that names no mode
/// starts its workers with exactly the command line it always had. Any other
/// mode is passed to both ranks, and only when the pinned capability record
/// covers each member's worker and advertises the mode; the two ranks then
/// bind it into their load agreement themselves. The owner never passes a
/// qualification switch.
enum DistributedInstalledGenerationSelection {
    static func workerArguments(configuration: ClusterConfiguration,
                                capability: ClusterRuntimeCapability) throws -> [String] {
        let mode = configuration.selectedGenerationMode
        try ClusterGenerationSelection.requireSupport(for: mode, peers: configuration.peers, capability: capability)
        let shares = configuration.tensorShares.map { ["--tensor-shares", $0.map(String.init).joined(separator: ":")] } ?? []
        return mode == .pipeline ? [] : ["--generation-mode", mode.rawValue] + (mode == .tensorParallel ? shares : [])
    }
}

/// Whether an installed session decodes with the model's speculative (MTP)
/// head, and if not, why.
///
/// On by default, as on one Mac: the planner writes `phase_split_mtp_v1` into
/// a setup whenever both members' worker advertises it, which it does only for
/// a model whose artifact ships a head. Naming `phase_split_v1` in the setup
/// is the diagnostic off switch (the same split, no head). The saved setup is
/// the switch, not the environment, because the owner of each Mac reads only
/// its own saved setup and the two ranks must be told the same mode.
struct DistributedInstalledSpeculation: Equatable, Sendable {
    static let enabledReason = "none"
    /// Every value `mtpOffReason` may take.
    static let reasons: Set<String> = [enabledReason, "runtimeCapabilityDisablesSpeculation",
        "setupSelectsPhaseSplitWithoutHead", "generationModeRunsNoHead"]
    let enabled: Bool
    let offReason: String

    init(enabled: Bool, offReason: String) { self.enabled = enabled; self.offReason = offReason }

    init(mode: ClusterGenerationMode, everyMemberAdvertisesHead: Bool) {
        if mode.usesSpeculativeHead {
            enabled = true; offReason = Self.enabledReason
        } else if !everyMemberAdvertisesHead {
            enabled = false; offReason = "runtimeCapabilityDisablesSpeculation"
        } else if mode.isPhaseSplit {
            enabled = false; offReason = "setupSelectsPhaseSplitWithoutHead"
        } else {
            // The pipeline modes pass every token through both ranks; no
            // speculative round runs there.
            enabled = false; offReason = "generationModeRunsNoHead"
        }
    }

    init(configuration: ClusterConfiguration, capability: ClusterRuntimeCapability) {
        self.init(mode: configuration.selectedGenerationMode,
            everyMemberAdvertisesHead: configuration.peers.allSatisfy {
                ClusterGenerationSelection.supportedModes(for: $0, capability: capability).contains(.phaseSplitMTP)
            })
    }
}
