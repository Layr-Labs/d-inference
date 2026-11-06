import DarkbloomClusterProtocol
import Foundation

/// The saved generation mode as worker arguments, beside the prefill schedule.
///
/// The pipeline is the absence of the argument, so a setup that names no mode
/// starts its workers with exactly the command line it always had. Any other
/// mode is passed to both ranks, and only when the pinned capability record
/// covers each member's worker and advertises the mode; the two ranks then
/// bind it into their load agreement themselves. The owner never passes a
/// qualification switch. MiMo's tensor parallel decodes in speculative rounds
/// on its trained heads wherever the pinned record declares them
/// (`ClusterMiMoTensorParallel`), so both ranks get the same depth.
enum DistributedInstalledGenerationSelection {
    static func workerArguments(configuration: ClusterConfiguration,
                                capability: ClusterRuntimeCapability) throws -> [String] {
        let mode = configuration.selectedGenerationMode
        try ClusterGenerationSelection.requireSupport(for: mode, peers: configuration.peers, capability: capability)
        let shares = configuration.tensorShares.map { ["--tensor-shares", $0.map(String.init).joined(separator: ":")] } ?? []
        var arguments = mode == .pipeline ? [] : ["--generation-mode", mode.rawValue] + (mode == .tensorParallel ? shares : [])
        if mimoTensorParallelRounds(mode: mode, capability: capability) {
            arguments += ClusterMiMoTensorParallel.workerArguments(runtimeModelID: capability.runtimeModelID, mode: mode)
        }
        if let assistant = configuration.tensorAssistant {
            try assistant.validate()
            guard mode == .tensorParallel, ClusterQwenTensorAssistantPolicy.runtimeModelIDs.contains(capability.runtimeModelID) else {
                throw ClusterConfigurationError.invalid("Tensor assistant launch differs from the saved Qwen TP policy")
            }
            arguments += ["--mtp-depth", String(assistant.depth),
                ClusterQwenTensorAssistantPolicy.inventoryArgument, assistant.inventorySHA256] + assistant.verificationArguments
        }
        if mode == .tensorParallel, let gemma = ClusterPublicModels.gemmaTensorAssistant(for: capability) {
            arguments += try gemmaAssistantArguments(gemma, locate: { SpecDecStore.publishedDirectory(aggregateSHA256: $0) })
        }
        return arguments
    }

    /// Gemma tensor parallel's rounds with the assistant this build declares
    /// public (`ClusterPublicModels.gemmaTensorAssistant`): both members launch
    /// with its depth and aggregate, each from its own verified copy of the
    /// catalog artifact. A member without the copy refuses to start, rather
    /// than start plain against a peer that speculates.
    static func gemmaAssistantArguments(_ assistant: ClusterPublicGemmaTensorAssistant,
                                        locate: (String) -> URL?) throws -> [String] {
        guard let directory = locate(assistant.aggregateSHA256) else {
            throw ClusterConfigurationError.invalid("Gemma's assistant (catalog artifact \(assistant.aggregateSHA256.prefix(12))) is not downloaded on this Mac yet")
        }
        return try ClusterGemmaTensorAssistant.workerArguments(depth: assistant.depth, directory: directory.path,
                                                               aggregateSHA256: assistant.aggregateSHA256)
    }

    /// MiMo tensor parallel's rounds, launched only where the worker's record declares them for the mode.
    static func mimoTensorParallelRounds(mode: ClusterGenerationMode, capability: ClusterRuntimeCapability) -> Bool {
        ClusterMiMoTensorParallel.decodesWithHead(runtimeModelID: capability.runtimeModelID, mode: mode)
            && capability.modeFeatures?[mode]?.speculativeRounds == true
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

    /// MiMo's tensor parallel also decodes with heads no mode names, launched with them where its record declares
    /// them (`DistributedInstalledGenerationSelection.mimoTensorParallelRounds`).
    init(configuration: ClusterConfiguration, capability: ClusterRuntimeCapability) {
        if DistributedInstalledGenerationSelection.mimoTensorParallelRounds(mode: configuration.selectedGenerationMode,
                                                                           capability: capability) {
            self.init(enabled: true, offReason: Self.enabledReason)
            return
        }
        if configuration.selectedGenerationMode == .tensorParallel,
           ClusterPublicModels.gemmaTensorAssistant(for: capability) != nil {
            self.init(enabled: true, offReason: Self.enabledReason)
            return
        }
        self.init(mode: configuration.selectedGenerationMode, runtimeModelID: capability.runtimeModelID,
            tensorAssistant: configuration.tensorAssistant != nil,
            everyMemberAdvertisesHead: configuration.peers.allSatisfy {
                ClusterGenerationSelection.supportedModes(for: $0, capability: capability).contains(.phaseSplitMTP)
            })
    }

    /// Two tensor-parallel placements decode with a head that no generation
    /// mode names: Qwen27's resident assistant (`tensorAssistant`, saved with
    /// the setup) and GLM-5.3-Flash's NextN head, which its runtime loads on
    /// every tensor-parallel load (`ClusterGLMTensorParallel`).
    init(mode: ClusterGenerationMode, runtimeModelID: String, tensorAssistant: Bool, everyMemberAdvertisesHead: Bool) {
        let assisted = tensorAssistant && mode == .tensorParallel
            && ClusterQwenTensorAssistantPolicy.runtimeModelIDs.contains(runtimeModelID)
        if assisted || ClusterGLMTensorParallel.decodesWithHead(runtimeModelID: runtimeModelID, mode: mode) {
            self.init(enabled: true, offReason: Self.enabledReason)
            return
        }
        self.init(mode: mode, everyMemberAdvertisesHead: everyMemberAdvertisesHead)
    }
}
