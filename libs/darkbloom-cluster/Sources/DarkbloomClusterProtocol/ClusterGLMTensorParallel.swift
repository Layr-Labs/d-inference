import Foundation

/// What GLM-5.3-Flash's tensor-parallel runtime binds into every load, for a
/// provider that describes a placed pair from its saved setup without loading
/// it. The runtime (`GLM5NextTensorParallelResidentRuntime.mtpDepth`) decodes
/// with the artifact's own NextN (MTP) head at this depth on every load of
/// `tensor_parallel_v1`; no generation mode names that head, so a status read
/// from the setup alone would report the placement as decoding one token per
/// step.
public enum ClusterGLMTensorParallel {
    /// NextN proposals each greedy decode round verifies; 0 would load no NextN
    /// layer.
    public static let speculativeDepth = 2

    /// Whether a placement of `runtimeModelID` in `mode` decodes with the NextN
    /// head: tensor parallel of the registered GLM row. Its pipeline runs no
    /// head.
    public static func decodesWithHead(runtimeModelID: String, mode: ClusterGenerationMode) -> Bool {
        runtimeModelID == ClusterGLMImageCandidate.runtimeModelID && mode == .tensorParallel && speculativeDepth > 0
    }

    /// How many proposals each decode round verifies
    /// (`GLM5NextTensorParallelDecodePolicy`): `fixed` (the default) always
    /// `speculativeDepth`; `load` one when `loadLanesSwitch` or more lanes
    /// decode in the same step.
    public static let depthPolicySwitch = "DARKBLOOM_GLM_TP_MTP_DEPTH_POLICY"
    /// The `load` policy's lane count (2 through 8, default 3).
    public static let loadLanesSwitch = "DARKBLOOM_GLM_TP_MTP_LOAD_LANES"
    /// `1`: no target window has one row (a round of no proposal verifies a
    /// discarded padding row beside its token). The `load` policy implies it.
    public static let widthInvariantSwitch = "DARKBLOOM_GLM_TP_WIDTH_INVARIANT"

    /// The decode switches an owner passes to its GLM tensor-parallel worker,
    /// each with the values it may take. Both ranks bind them into their load
    /// agreement, so both Macs' owners must set the same values.
    public static let decodeSwitches: [String: Set<String>] = [
        depthPolicySwitch: ["fixed", "load"],
        loadLanesSwitch: Set((2...8).map(String.init)),
        widthInvariantSwitch: ["0", "1"],
    ]

    /// The decode switches `environment` sets to a value they take; any other
    /// value stays behind, and the worker then runs its default.
    public static func forwardedDecodeSwitches(_ environment: [String: String]) -> [String: String] {
        environment.filter { decodeSwitches[$0.key]?.contains($0.value) == true }
    }
}
