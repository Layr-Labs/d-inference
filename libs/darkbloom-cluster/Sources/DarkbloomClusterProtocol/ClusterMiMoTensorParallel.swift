import Foundation

/// How MiMo V2.6 Flash's tensor parallel decodes, for the owner that launches
/// it and the worker that declares it: every rank holds the artifact's three
/// trained next-N heads whole and decodes in speculative rounds
/// (`MiMoTensorParallelResidentRuntime`, `--mtp-depth`). No generation mode
/// names those heads, so the owner passes the depth to both ranks, and both
/// bind it into their load agreement.
public enum ClusterMiMoTensorParallel {
    /// Drafts each round verifies: the depth MiMo's speculative pipeline
    /// measured fastest (`MiMoMTPTerms.standard`), which the tensor-parallel
    /// plan recommends too.
    public static let speculativeDepth = 2

    /// Whether a placement of `runtimeModelID` in `mode` decodes with the
    /// heads: tensor parallel of the registered MiMo text row.
    public static func decodesWithHead(runtimeModelID: String, mode: ClusterGenerationMode) -> Bool {
        runtimeModelID == ClusterMiMoImageCandidate.runtimeModelID && mode == .tensorParallel && speculativeDepth > 0
    }

    /// The worker arguments that turn the rounds on; none for any other placement.
    public static func workerArguments(runtimeModelID: String, mode: ClusterGenerationMode) -> [String] {
        decodesWithHead(runtimeModelID: runtimeModelID, mode: mode) ? ["--mtp-depth", String(speculativeDepth)] : []
    }
}
