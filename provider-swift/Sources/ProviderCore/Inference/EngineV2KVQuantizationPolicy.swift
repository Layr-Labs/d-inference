import Foundation
import MLXLMCommon

/// Experimental full-attention page formats. Native remains the default for
/// every artifact; weight quantization never selects a cache format implicitly.
public enum EngineV2KVQuantizationSelection: String, Sendable, Equatable, CaseIterable {
    case native
    case int4
    case k8v4
    case int8

    public var configuration: PagedKVQuantizationConfig? {
        switch self {
        case .native: nil
        case .int4: PagedKVQuantizationConfig(keyBits: 4, valueBits: 4)
        case .k8v4: PagedKVQuantizationConfig(keyBits: 8, valueBits: 4)
        case .int8: PagedKVQuantizationConfig(keyBits: 8, valueBits: 8)
        }
    }
}

public enum EngineV2KVQuantizationPolicy {
    public enum Failure: Error, CustomStringConvertible {
        case invalidSelection(String)
        case requiresPagedBackend(String)

        public var description: String {
            switch self {
            case .invalidSelection(let value):
                "Invalid KV quantization \"\(value)\"; expected native, int4, k8v4 or int8"
            case .requiresPagedBackend(let reason):
                "Quantized KV requires a paged backend; refusing native fallback (\(reason))"
            }
        }
    }

    /// Exact model IDs override the global choice. Unknown values refuse the
    /// load so a typo cannot silently produce a differently labelled experiment.
    public static func parseSelection(
        global: String = "native", byModel: [String: String] = [:], modelID: String
    ) throws -> EngineV2KVQuantizationSelection {
        let raw = byModel[modelID] ?? global
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty { return .native }
        guard let selection = EngineV2KVQuantizationSelection(rawValue: normalized) else {
            throw Failure.invalidSelection(raw)
        }
        return selection
    }

    static func requireResolvedBackend(
        _ kind: EngineV2KVBackendKind, selection: EngineV2KVQuantizationSelection,
        reason: String? = nil
    ) throws {
        guard selection == .native || kind == .paged else {
            throw Failure.requiresPagedBackend(reason ?? kind.rawValue)
        }
    }
}
