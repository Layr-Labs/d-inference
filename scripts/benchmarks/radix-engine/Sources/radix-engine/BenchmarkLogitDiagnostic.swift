import Foundation
@_spi(Diagnostics) import MLXLMCommon

/// Offline records belong to the first main request (native id 2). Warmup
/// completes before installation, and later controls run after explicit clear.
enum BenchmarkLogitDiagnostic {
    static func install(_ configuration: CBv2LogitDiagnosticConfig?, loaded: Loaded) throws {
        guard let configuration else { return }
        guard let engine = loaded.engine as? EngineV2 else {
            throw RadixBenchmark.Failure.message("diagnostic requires EngineV2")
        }
        try engine.configureLogitDiagnostic(configuration)
    }

    static func take(loaded: Loaded) throws -> [String: Any] {
        guard let engine = loaded.engine as? EngineV2,
            let snapshot = try engine.takeLogitDiagnosticSnapshot() else {
            throw RadixBenchmark.Failure.message("diagnostic configuration disappeared before drain")
        }
        try engine.configureLogitDiagnostic(nil)
        let data = try JSONEncoder().encode(snapshot)
        let encoded = try JSONSerialization.jsonObject(with: data)
        let confirmed = snapshot.records.contains { $0.outcome == "confirmed" }
        return [
            "scope": "first main request only; actual forward, no teacher forcing",
            "status": confirmed && snapshot.omittedRecords == 0
                && snapshot.invalidVocabularyRecords == 0 ? "captured" : "inconclusive",
            "timing_warning": "Diagnostic reductions can change adaptive verification geometry. Compare emitted IDs to the frozen uninstrumented arm; do not use diagnostic timing as performance evidence.",
            "value_bits_order": "Float32 argMax value, fused top-two values, requested candidate values",
            "snapshot": encoded,
        ]
    }
}
