import Foundation

/// Exact product admission, separate from the reusable arithmetic primitive.
/// Other TP rows and unkeyed singleton probes keep their earlier behavior.
struct QwenTensorParallelBatchSettings {
    let lanes: Int
    let backend: ClusterStageKVBackendKind
    /// Keyed Qwen27 keeps one execution/cache family across capacity changes.
    var requestOwned = false
    static func resolve(model: QwenRegisteredDenseModel, keyed: Bool,
                        environment: [String: String]) throws -> Self {
        guard model == .qwen38TwentySevenB else { return .init(lanes: 1, backend: .paged) }
        let requested = try QwenBatchSettings.fromEnvironment(environment)
        guard !requested.batching || keyed else { throw ProbeError("Qwen27 TP batching requires an authenticated sealed pair") }
        return try .init(lanes: requested.lanes,
            backend: keyed ? ClusterStageKVBackendKind.fromEnvironment(environment) : .paged, requestOwned: keyed)
    }
    var agreementFields: [String] {
        !requestOwned && lanes == 1 ? [] : [QwenTensorParallelBatchWire.agreement, "lanes=\(lanes)", "kv=\(backend.rawValue)",
            "fp32-row-m1-v1", "request-local-original-rope-v1", "batch-inventory-budget-v3-rank-heads", QwenTensorParallelBatchPrefixBudget.policy]
    }
}
