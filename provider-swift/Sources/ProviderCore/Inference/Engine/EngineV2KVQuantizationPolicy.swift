import Foundation
import MLXLMCommon

/// Physical attention-cache precision. Weight quantization never selects this policy.
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

    public enum Failure: Error, CustomStringConvertible {
        case invalidSelection(String)
        case requiresPagedBackend(String)

        public var description: String {
            switch self {
            case .invalidSelection(let raw):
                "Invalid KV quantization \"\(raw)\"; expected balanced, k8v4, k8v8 or native"
            case .requiresPagedBackend(let reason):
                "Quantized KV requires paged storage; select native precision for \(reason)"
            }
        }
    }

    public static func parseSelection(_ raw: String) throws -> EngineV2KVQuantizationSelection {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "balanced", "k4v4", "int4", "on": .balanced
        case "k8v4": .k8v4
        case "k8v8", "int8": .k8v8
        case "native", "off", "0": .native
        default: throw Failure.invalidSelection(raw)
        }
    }

    /// MiMo's SDK-owned execution path is excluded before parsing any override.
    public static func resolve(
        modelType: String?, global: String = "balanced", byModel: [String: String] = [:],
        modelID: String, environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> EngineV2KVQuantizationSelection {
        guard modelType != "mimo_v2" else { return .native }
        return try parseSelection(environment[environmentKey] ?? byModel[modelID] ?? global)
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
