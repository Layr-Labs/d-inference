import Foundation
import MLXLMCommon

/// Attention precision for live execution or checkpoint storage
/// (`PagedKVQuantizationSelection`, shared with the cluster's stage hosts).
public typealias EngineV2KVQuantizationSelection = PagedKVQuantizationSelection

/// The shared resolution (`PagedKVQuantizationPolicy`); the provider passes its
/// saved settings and adds the engine's own backend and assistant rules.
public typealias EngineV2KVQuantizationPolicy = PagedKVQuantizationPolicy

extension PagedKVQuantizationPolicy {
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
