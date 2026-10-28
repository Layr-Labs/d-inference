import Foundation

/// Exact product admission, separate from the reusable arithmetic primitive.
/// Every registered Qwen TP row serves request-owned CBv2 lanes at every
/// capacity, one included, and keeps one execution/cache family across
/// capacity changes. Only an authenticated sealed pair serves them.
struct QwenTensorParallelBatchSettings {
    let lanes: Int
    let backend: ClusterStageKVBackendKind
    /// A routed-expert row's cohort packs every row's expert and shared
    /// partials into one collective a layer (`Qwen35SparseMoeBlock`).
    var routedExperts = false
    static func resolve(model: QwenRegisteredDenseModel, keyed: Bool,
                        environment: [String: String]) throws -> Self {
        let definition = try QwenResidentModelDefinition(model: model)
        guard definition.supportedGenerationModes.contains(.tensorParallel) else {
            throw ProbeError("\(model.rawValue) has no tensor-parallel row")
        }
        guard keyed else { throw ProbeError("Qwen TP serves request-owned lanes over an authenticated sealed pair only") }
        let requested = try QwenBatchSettings.fromEnvironment(environment)
        return try .init(lanes: requested.lanes, backend: ClusterStageKVBackendKind.fromEnvironment(environment),
            routedExperts: definition.arithmetic == .routedExperts)
    }
    var agreementFields: [String] {
        [QwenTensorParallelBatchWire.agreement, "lanes=\(lanes)", "kv=\(backend.rawValue)",
            "fp32-row-m1-v1", "request-local-original-rope-v1", "batch-inventory-budget-v3-rank-heads", QwenTensorParallelBatchPrefixBudget.policy]
            + (routedExperts ? ["moe-rows-one-collective-v1"] : [])
    }
}
