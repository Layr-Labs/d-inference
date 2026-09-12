import Foundation
@_spi(Diagnostics) import MLXLMCommon

enum BenchmarkAttentionMetadata {
    static func install(_ configuration: CBv2AttentionMetadataConfig?, loaded: Loaded) throws {
        guard let configuration else { return }
        guard let engine = loaded.engine as? EngineV2 else {
            throw RadixBenchmark.Failure.message("attention metadata requires EngineV2")
        }
        try engine.configureAttentionMetadata(configuration)
    }

    static func take(loaded: Loaded) throws -> [String: Any] {
        guard let engine = loaded.engine as? EngineV2,
            let snapshot = try engine.takeAttentionMetadataSnapshot() else {
            throw RadixBenchmark.Failure.message("attention metadata disappeared before idle drain")
        }
        try engine.configureAttentionMetadata(nil)
        let complete = snapshot.forwardSucceeded && snapshot.sampleOutcome == "confirmed"
            && snapshot.selectedForwards == 1 && snapshot.refusals.isEmpty
            && snapshot.records.count == snapshot.expectedOwnerCount
        return [
            "scope": "First main request, selected ordinary forward; tensor metadata at graph construction, reconciled with normal sample retirement. No tensor contents captured.",
            "status": complete ? "captured" : "inconclusive",
            "stride_scope": "Graph-construction strides may change during evaluation; they do not describe evaluated physical layout.",
            "timing_scope": "Compare emitted IDs with the uninstrumented control. Diagnostic timing is not release performance evidence.",
            "snapshot": try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)),
        ]
    }
}
