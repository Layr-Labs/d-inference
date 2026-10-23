import Foundation

/// Exact product admission, separate from the reusable arithmetic primitive.
/// Existing TP rows and one-lane launch agreement keep their earlier behavior.
struct QwenTensorParallelBatchSettings {
    let lanes: Int
    let backend: ClusterStageKVBackendKind
    static func resolve(model: QwenRegisteredDenseModel, keyed: Bool,
                        environment: [String: String]) throws -> Self {
        guard model == .qwen38TwentySevenB else { return .init(lanes: 1, backend: .paged) }
        let requested = try QwenBatchSettings.fromEnvironment(environment)
        guard !requested.batching || keyed else { throw ProbeError("Qwen27 TP batching requires an authenticated sealed pair") }
        return try .init(lanes: requested.lanes,
            backend: requested.batching ? ClusterStageKVBackendKind.fromEnvironment(environment) : .paged)
    }
    var agreementFields: [String] {
        lanes == 1 ? [] : [QwenTensorParallelBatchWire.agreement, "lanes=\(lanes)", "kv=\(backend.rawValue)",
            "fp32-row-m1-v1", "request-local-original-rope-v1", "batch-inventory-budget-v1"]
    }
}
