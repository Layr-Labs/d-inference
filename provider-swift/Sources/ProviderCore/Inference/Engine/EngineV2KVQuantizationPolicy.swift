import Foundation
import MLXLMCommon

/// Attention precision for live execution or checkpoint storage
/// (`PagedKVQuantizationSelection`, shared with the cluster's stage hosts).
public typealias EngineV2KVQuantizationSelection = PagedKVQuantizationSelection

/// The shared resolution (`PagedKVQuantizationPolicy`); the provider passes its
/// saved settings and adds the engine's own backend and assistant rules.
public typealias EngineV2KVQuantizationPolicy = PagedKVQuantizationPolicy

extension PagedKVQuantizationPolicy {
    /// Complete-checkpoint precision for a provider slot: the shared resolution,
    /// except for model types whose restores must continue a cold prefill bit for
    /// bit. Muse Glimmer stores native rows: restored from `balanced` rows, 3 of 5
    /// live conversation turns emitted other tokens than their cold runs; from
    /// native rows none did. For it the process switch, then the per-model setting
    /// (each when not blank) still selects a profile; the global setting does not
    /// apply, as for Nemotron Super (`NemotronSuperLocalPrefixCache`).
    public static func resolveProviderCheckpoint(
        modelType: String?, global: String?, byModel: [String: String], modelID: String,
        environment: [String: String]
    ) throws -> PagedKVQuantizationSelection {
        guard MuseGlimmerModelPolicy.isModelType(modelType) else {
            return try resolve(modelType: modelType, global: global, byModel: byModel,
                               modelID: modelID, environment: environment, purpose: .checkpoint)
        }
        let explicit = [environment[checkpointEnvironmentKey], byModel[modelID]].compactMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return try explicit.map { try parseSelection($0, purpose: .checkpoint) } ?? .native
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
