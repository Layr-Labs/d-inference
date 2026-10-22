import Foundation
import MLXLMCommon

/// Attention precision for live execution or checkpoint storage. Weight precision
/// never selects either policy.
public enum EngineV2KVQuantizationSelection: String, Sendable, Equatable, CaseIterable {
    case balanced
    case k8v4
    case k8v8
    case native

    public var configuration: PagedKVQuantizationConfig? {
        guard self != .native else { return nil }
        return PagedKVQuantizationConfig(
            keyBits: self == .balanced ? 4 : 8, valueBits: self == .k8v8 ? 8 : 4,
            groupSize: 64, rotationBlockSize: 128, recentTokenCount: 128)
    }
}

public enum EngineV2KVQuantizationPolicy {
    public static let environmentKey = "DARKBLOOM_CBV2_KV_QUANTIZATION"
    public static let checkpointEnvironmentKey = "DARKBLOOM_CBV2_CHECKPOINT_QUANTIZATION"

    public enum Purpose: Sendable, Equatable {
        case live
        case checkpoint

        var defaultSelection: EngineV2KVQuantizationSelection {
            self == .live ? .native : .balanced
        }

        var environmentKey: String {
            self == .live ? EngineV2KVQuantizationPolicy.environmentKey
                : EngineV2KVQuantizationPolicy.checkpointEnvironmentKey
        }
    }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case invalidSelection(String)
        case invalidCheckpointSelection(String)
        case requiresPagedBackend(String)
        case flintRequiresNative

        public var description: String {
            switch self {
            case .invalidSelection(let raw):
                "Invalid live KV quantization \"\(raw)\"; expected balanced, k8v4, k8v8 or native"
            case .invalidCheckpointSelection(let raw):
                "Invalid checkpoint KV quantization \"\(raw)\"; expected balanced, k8v4, k8v8 or native"
            case .requiresPagedBackend(let reason):
                "Live quantized KV requires paged execution; select native live precision for \(reason)"
            case .flintRequiresNative:
                "Flint currently requires native BF16 KV and native checkpoint precision"
            }
        }
    }

    public static func parseSelection(
        _ raw: String, purpose: Purpose = .live
    ) throws -> EngineV2KVQuantizationSelection {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "": purpose.defaultSelection
        case "balanced", "k4v4", "int4", "on": .balanced
        case "k8v4": .k8v4
        case "k8v8", "int8": .k8v8
        case "native", "off", "0": .native
        default:
            throw purpose == .live ? Failure.invalidSelection(raw)
                : Failure.invalidCheckpointSelection(raw)
        }
    }

    /// MiMo's SDK-owned execution path is excluded before parsing any override.
    public static func resolve(
        modelType: String?, global: String? = nil, byModel: [String: String] = [:],
        modelID: String, environment: [String: String] = ProcessInfo.processInfo.environment,
        purpose: Purpose = .live
    ) throws -> EngineV2KVQuantizationSelection {
        guard modelType != "mimo_v2" else { return .native }
        if modelType == "flint" {
            let raw = environment[purpose.environmentKey] ?? byModel[modelID] ?? global
            if let raw, !raw.isEmpty, try parseSelection(raw, purpose: purpose) != .native {
                throw Failure.flintRequiresNative
            }
            return .native
        }
        return try parseSelection(
            environment[purpose.environmentKey] ?? byModel[modelID] ?? global ?? "", purpose: purpose)
    }

    static func requireResolvedBackend(
        _ kind: EngineV2KVBackendKind, selection: EngineV2KVQuantizationSelection,
        reason: String? = nil
    ) throws {
        guard selection == .native || kind == .paged else {
            throw Failure.requiresPagedBackend(reason ?? kind.rawValue)
        }
    }

    /// Gemma's active assistant reads these two owning rows without copying history.
    static func nativeAssistantAccessLayers(
        layerKinds: [CBv2LayerKind], gemmaAssistantActive: Bool
    ) -> Set<Int> {
        guard gemmaAssistantActive else { return [] }
        var full: Int?, window: Int?
        for (index, kind) in layerKinds.enumerated() where kind.sharesKVWithLayer == nil {
            switch kind.attention {
            case .full: full = index
            case .slidingWindow: window = index
            }
        }
        return Set([full, window].compactMap { $0 })
    }
}
