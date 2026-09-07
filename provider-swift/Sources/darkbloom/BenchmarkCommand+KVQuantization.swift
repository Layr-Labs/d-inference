import ArgumentParser
import Foundation
import ProviderCore

extension Benchmark {
    func resolvedKVQuantizationSelection() throws -> EngineV2KVQuantizationSelection {
        try EngineV2KVQuantizationPolicy.parseSelection(global: kvQuantization, modelID: "")
    }

    /// Reject unsupported measurement modes before model loading. In particular,
    /// the ordinary benchmark and backend-parity harness do not consume this
    /// format parameter, so accepting it would mislabel a native-cache result.
    func kvQuantizationOptionError() -> String? {
        let selection: EngineV2KVQuantizationSelection
        do { selection = try resolvedKVQuantizationSelection() }
        catch { return "--kv-quantization must be one of: native, int4, k8v4, int8" }
        guard selection != .native else { return nil }
        guard kvBackend.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "paged" else {
            return "--kv-quantization \(selection.rawValue) requires --kv-backend paged"
        }
        guard sweep || schedulerPrefill || arrivalInvariance || teacherForcedInput != nil || kvQualityInput != nil else {
            return "--kv-quantization requires --sweep, --scheduler-prefill, --arrival-invariance --teacher-forced-input or --kv-quality-input"
        }
        return nil
    }
}
