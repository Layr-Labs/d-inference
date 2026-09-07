import ArgumentParser
import Foundation
import MLXLMCommon
import ProviderCore

extension Benchmark {
    func resolvedQuantizedPrefillMode() throws -> PagedQuantizedPrefillMode {
        switch quantizedPrefill?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "direct" {
        case "direct": return .direct
        case "opportunistic": return .opportunisticSDPA
        default: throw ValidationError("--quantized-prefill must be direct or opportunistic")
        }
    }

    func quantizedPrefillOptionError() -> String? {
        guard quantizedPrefill != nil else { return nil }
        do { _ = try resolvedQuantizedPrefillMode() }
        catch { return "--quantized-prefill must be direct or opportunistic" }
        guard sweep || schedulerPrefill || kvQualityInput != nil,
              !parity, !schedulerPrefillDecision, !arrivalInvariance, teacherForcedInput == nil else {
            return "--quantized-prefill requires --sweep, --scheduler-prefill or --kv-quality-input"
        }
        guard let quantization = try? resolvedKVQuantizationSelection(), quantization != .native,
              kvBackend.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "paged" else {
            return "--quantized-prefill requires a packed --kv-quantization format and --kv-backend paged"
        }
        return nil
    }
}
