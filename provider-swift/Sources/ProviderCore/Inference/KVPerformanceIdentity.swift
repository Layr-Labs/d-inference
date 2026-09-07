import Foundation
import MLXLMCommon

/// Performance-history identity, separate from model weight quantization.
/// Native omission preserves legacy wire/key behavior. Unknown nonempty
/// identities stay quarantined rather than borrowing native measurements.
enum KVPerformanceIdentity {
    static let maximumBytes = 160
    static let quarantine = "kvq-v1:invalid"
    private static let pattern = #"^kvq-v1:affine-v1-k(4|8)v(4|8)-g(32|64|128)-f32-h(0|32|64|128|256|512)-s1:prefill=(direct|opportunisticSDPA)$"#

    static func normalized(_ identity: String?) -> String? {
        guard let identity, !identity.isEmpty else { return nil }
        guard identity.utf8.count <= maximumBytes,
              identity.utf8.allSatisfy({ (33...126).contains($0) }),
              identity.range(of: pattern, options: .regularExpression) != nil else { return quarantine }
        return identity
    }

    static func actual(format: String?, prefillMode: PagedQuantizedPrefillMode) -> String? {
        guard let format else { return nil }
        return normalized("kvq-v1:\(format):prefill=\(prefillMode.rawValue)")
    }

    static func resolved(slot: BackendSlotCapacity?, declared: ModelInfo?) -> String? {
        if let slot, slot.state == "running" || slot.state == "idle" {
            return normalized(slot.executionIdentity)
        }
        return normalized(declared?.executionIdentity)
    }

    static func observedRatesCompatible(slot: BackendSlotCapacity, declared: ModelInfo?) -> Bool {
        let identity = resolved(slot: slot, declared: declared)
        return identity != quarantine && (identity == nil || slot.state == "running" || slot.state == "idle")
    }

    static func declared(model: ModelInfo, settings: BackendSettings) -> ModelInfo {
        var result = model
        do {
            let selection = try EngineV2KVQuantizationPolicy.parseSelection(
                global: settings.engineV2KVQuantization,
                byModel: settings.engineV2KVQuantizationByModel, modelID: model.id)
            result.executionIdentity = actual(format: selection.configuration?.identity, prefillMode: .direct)
        } catch {
            result.executionIdentity = quarantine
        }
        return result
    }
}
