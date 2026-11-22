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

    /// Whether a Gemma slot keeps the assistant's two access layers native
    /// (`nativeAssistantAccessLayers`). With the assistant attached, MTP decides
    /// as before. Without it, they stay native while an assistant is configured
    /// for the model: a slot built target-only (catalog metadata not ready yet,
    /// or the assistant skipped for memory) takes it later through the idle
    /// upgrade, and checkpoints written before and after the upgrade must encode
    /// the target rows the same way. The process MTP switch and the spec-dec kill
    /// switch keep the target-only layout.
    static func gemmaAssistantAccessExpected(
        assistantAttached: Bool, mtpEnabled: Bool, status: MTPActivationStatus,
        processMTPEnabled: Bool = CBv2MTPConfig.envEnabled
    ) -> Bool {
        if assistantAttached { return mtpEnabled }
        return processMTPEnabled && status.configured && status.reason != .killSwitchDisabled
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
