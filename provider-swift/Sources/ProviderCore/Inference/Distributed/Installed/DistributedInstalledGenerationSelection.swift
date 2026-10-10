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
        return mode == .pipeline ? [] : ["--generation-mode", mode.rawValue]
    }
}
