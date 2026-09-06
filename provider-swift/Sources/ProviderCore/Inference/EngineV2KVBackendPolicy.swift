// Copyright © 2026 Eigen Labs.
// Backend policy: per-model config wins, slot/model capabilities may veto it,
// and the fleet kill switch overrides every caller. Auto selects paged only
// for exact candidate fleet Qwen IDs. Explicit paged failures refuse the load; automatic
// failures may degrade. The crash-loop guard applies only to automatic selection.

import Foundation

/// The KV backend actually serving a slot.
public enum EngineV2KVBackendKind: String, Sendable, Equatable {
    case contiguous
    case paged
}

/// Operator configuration, preserved separately from the resolved backend.
public enum EngineV2KVBackendSelection: String, Sendable, Equatable, CaseIterable {
    case auto
    case paged
    case contiguous
}

public enum EngineV2KVBackendPolicy {
    public static func preferredBackend(
        selection: EngineV2KVBackendSelection,
        modelID: String?
    ) -> EngineV2KVBackendKind {
        switch selection {
        case .contiguous: return .contiguous
        case .paged: return .paged
        case .auto:
            switch modelID {
            case "qwen3.5-35b-a3b", "qwen3.6-35b-a3b-vl-mtp-mxfp8",
                "EigenLabs/Qwen3.8-27B-4bit-mtp":
                return .paged
            default:
                return .contiguous
            }
        }
    }

    /// Only negative values disable paged; this switch cannot select paged.
    public static let killSwitchEnvKey = "DARKBLOOM_CBV2_PAGED_KV"

    /// Per-model configuration overrides the global selection. Return an invalid
    /// raw value for the caller's warning, while falling back to auto.
    public static func parseSelection(
        global: String,
        byModel: [String: String],
        modelID: String
    ) -> (selection: EngineV2KVBackendSelection, unrecognized: String?) {
        let raw = byModel[modelID] ?? global
        let normalized = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if normalized.isEmpty { return (.auto, nil) }
        guard let parsed = EngineV2KVBackendSelection(rawValue: normalized) else {
            return (.auto, raw)
        }
        return (parsed, nil)
    }

    /// Absence, affirmative values, and typos preserve the configured selection.
    public static func killSwitchDisabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let raw = environment[killSwitchEnvKey] else { return false }
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "0", "false", "no", "off": return true
        default: return false
        }
    }

    /// A guard binds only the version that tripped it. New releases retry the
    /// configured backend; startup removes stale records.
    public static func crashLoopGuardForcesContiguous(
        record: KVBackendGuard?,
        runningVersion: String
    ) -> Bool {
        guard let record else { return false }
        return record.providerVersion == runningVersion
    }

    /// Vision requires the cache's own span-mask capability. A capability veto
    /// may override explicit paged intent and is reported as policy, not failure.
    public static func applySlotVetoes(
        selection: EngineV2KVBackendSelection,
        isVLM: Bool,
        pagedHonorsSpanMasks: Bool
    ) -> (selection: EngineV2KVBackendSelection, veto: String?) {
        guard selection != .contiguous else { return (.contiguous, nil) }
        guard isVLM, !pagedHonorsSpanMasks else { return (selection, nil) }
        return (.contiguous, selection == .paged ? "vlm" : nil)
    }

    /// Construction failure may degrade an automatic selection. An explicit
    /// paged request must fail so serving and benchmark labels remain truthful.
    public static func degradesPagedFailure(
        selection: EngineV2KVBackendSelection
    ) -> Bool {
        selection != .paged
    }
}
