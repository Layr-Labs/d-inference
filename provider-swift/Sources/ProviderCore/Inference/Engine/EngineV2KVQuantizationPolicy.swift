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
    /// for the model (`MTPActivationStatus.configured`), whether or not it ever
    /// attaches: a slot built target-only (assistant or catalog metadata not
    /// ready, or skipped for memory) then encodes its checkpoints as an attached
    /// slot does. `mtp_mode = "off"` (`configured` false) or the
    /// `DARKBLOOM_CBV2_MTP=0` kill switch keeps the target-only layout, whether
    /// seen by the SDK at process start (`CBv2MTPConfig.envEnabled`) or recorded
    /// as a preparation fallback (`killSwitchDisabled`). The benchmark
    /// construction (`EngineV2Factory.makeProductionBuild`) keeps its
    /// attached-only rule.
    static func gemmaAssistantAccessExpected(
        assistantAttached: Bool, mtpEnabled: Bool, status: MTPActivationStatus,
        processMTPEnabled: Bool = CBv2MTPConfig.envEnabled,
        nativeRowsBeforeAssistant: Bool = gemmaNativeRowsBeforeAssistantEnabled
    ) -> Bool {
        if assistantAttached { return mtpEnabled }
        return nativeRowsBeforeAssistant && processMTPEnabled && status.configured
            && status.reason != .killSwitchDisabled
    }

    /// `DARKBLOOM_GEMMA_NATIVE_ROWS_BEFORE_ASSISTANT`: on (unset, empty, `1`,
    /// `true`, `yes`, `on`; trimmed, any case) a Gemma slot whose assistant is
    /// configured but not attached keeps the access layers native
    /// (`gemmaAssistantAccessExpected`). Any other value (e.g. `0`) restores the
    /// earlier rule, native only with the assistant attached, and leaves MTP on.
    /// Read once from the process environment; the LaunchAgent forwards it.
    public static let gemmaNativeRowsBeforeAssistantEnvironmentKey =
        "DARKBLOOM_GEMMA_NATIVE_ROWS_BEFORE_ASSISTANT"
    static let gemmaNativeRowsBeforeAssistantEnabled = MTPAutomaticVerificationPolicy.gemmaLoneRowEnabled(
        ProcessInfo.processInfo.environment[gemmaNativeRowsBeforeAssistantEnvironmentKey])

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
