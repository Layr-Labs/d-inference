import Foundation

/// Gemma 4's assistant drafter (the catalog's pinned `spec_dec` artifact of the
/// QAT 4-bit row, the one a single Mac loads) on a tensor-parallel pair: the
/// worker arguments that launch speculative rounds with it, and their bounds.
/// Both ranks are given the same depth and the same verified artifact; each
/// names its own local directory. This value grants neither memory nor
/// readiness and selects no generation mode.
public enum ClusterGemmaTensorAssistant {
    /// The assistant's local directory: the verified catalog artifact (its
    /// `manifest.json`, `config.json` and weights).
    public static let directoryArgument = "--gemma-assistant-dir"
    /// The artifact's manifest aggregate SHA-256, which the worker verifies
    /// every file against before it reads a weight.
    public static let aggregateArgument = "--gemma-assistant-sha256"
    /// Proposals a round may make (`--mtp-depth`).
    public static let depths = 1 ... 4
    /// The rows whose tensor-parallel owner takes the assistant.
    public static let runtimeModelIDs: Set<String> = ["registered_gemma4_26b_qat_4bit"]
    /// Schema of the launch fields a resource policy names.
    public static let schemaName = "gemma4_tensor_assistant_v1"

    /// The worker arguments of a launch with the assistant: the depth, the
    /// local directory and the pinned aggregate.
    public static func workerArguments(depth: Int, directory: String, aggregateSHA256: String) throws -> [String] {
        try workerRequire(depths.contains(depth) && directory.hasPrefix("/") && ClusterWorkerValidation.hash(aggregateSHA256),
            "Invalid Gemma tensor assistant launch")
        return ["--mtp-depth", String(depth), directoryArgument, directory, aggregateArgument, aggregateSHA256]
    }
}
