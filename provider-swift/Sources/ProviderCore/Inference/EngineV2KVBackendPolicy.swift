// Copyright © 2026 Eigen Labs.
//
// KV-backend selection policy for production CBv2 engines: which slots
// serve on the PAGED backend (`PagedKVBackend` — block-table page pool +
// fused Metal decode kernel) vs the CONTIGUOUS backend
// (`CBv2ContiguousKVBackend` — per-sequence buffers).
//
// Decision layers, outermost first:
//
//   1. Operator config: `engine_v2_kv_backend` under `[backend]`
//      ("auto" | "paged" | "contiguous", default "auto"), per-model
//      overrides in `engine_v2_kv_backend_by_model`. Unrecognized values
//      WARN and fall back to "auto" — safe by construction because every
//      auto path still passes the vetoes below.
//   2. Slot vetoes (`EngineV2SlotFactory`): VLM slots and `kv_quant`
//      configs force contiguous. The paged cache cannot bind multimodal
//      span masks (vision requests would 4xx at submit with
//      `CBv2MultimodalError.unsupportedBackend`) and serves fp16 pages
//      only.
//   3. Fleet kill switch: `DARKBLOOM_CBV2_PAGED_KV=0` forces contiguous
//      everywhere, enforced at engine construction (the deepest layer) so
//      no call path can bypass it. Forwarded through the launchd plist
//      (`LaunchAgent.passthroughEnvKeys`) so an operator kill survives
//      install/restart — the same rationale as the SSD tier's switch.
//   4. Family resolution for "auto", kept NEXT TO the authoritative family
//      switch in `makeProductionEngine` so the two can never drift:
//      GPT-OSS → paged (default-ON, 2026-07-10 decision); Gemma-4 →
//      contiguous (its KV arrives bf16; fp16 pages are a numerics delta
//      that stays opt-in via an explicit "paged").
//   5. Eligibility fallback: `PagedKVBackend` construction throwing
//      `backendIneligible` falls back to contiguous — a paged-ineligible
//      model must load and serve, never refuse.

import Foundation

/// The KV backend a production CBv2 engine was actually built with.
public enum EngineV2KVBackendKind: String, Sendable, Equatable {
    case contiguous
    case paged
}

/// Operator-facing backend selection (`engine_v2_kv_backend`).
public enum EngineV2KVBackendSelection: String, Sendable, Equatable, CaseIterable {
    /// Family default: paged for GPT-OSS text slots, contiguous otherwise.
    case auto
    /// Force paged where structurally possible (VLM/kv-quant slots and
    /// kernel-ineligible models still fall back to contiguous).
    case paged
    /// Force contiguous.
    case contiguous
}

public enum EngineV2KVBackendPolicy {
    /// Fleet kill switch: set to `0`/`false`/`no`/`off` to force the
    /// contiguous backend everywhere regardless of config. Mirrors the
    /// compiled-decode kill switch idiom (`DARKBLOOM_CBV2_COMPILED`).
    public static let killSwitchEnvKey = "DARKBLOOM_CBV2_PAGED_KV"

    /// Parse the operator selection for `modelID` (per-model override
    /// wins over the global value). `unrecognized` carries a raw value
    /// that failed to parse so the caller can WARN once; the returned
    /// selection is then `.auto` (the shipped default — still safe: every
    /// auto path passes the VLM/kv-quant vetoes and eligibility fallback).
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

    /// True when the fleet kill switch disables paged serving. Affirmative
    /// values (or absence) leave paged enabled; only an explicit negative
    /// kills it — a typo must not flip the fleet's default.
    public static func killSwitchDisabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let raw = environment[killSwitchEnvKey] else { return false }
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "0", "false", "no", "off": return true
        default: return false
        }
    }

    /// Slot-veto layer: force contiguous for slots the paged cache cannot
    /// serve. VLM slots — the paged cache cannot bind multimodal span
    /// masks, so media requests would 4xx at submit on an otherwise
    /// paged-ELIGIBLE model (gemma-4's shapes construct fine; only vision
    /// traffic breaks, which is why eligibility fallback alone is not
    /// enough). kv-quant intent — the pool serves fp16 pages only.
    /// Returns the effective selection plus a veto tag for the slot log.
    public static func applySlotVetoes(
        selection: EngineV2KVBackendSelection,
        isVLM: Bool,
        kvQuantConfigured: Bool
    ) -> (selection: EngineV2KVBackendSelection, veto: String?) {
        guard selection != .contiguous else { return (.contiguous, nil) }
        if isVLM {
            return (.contiguous, selection == .paged ? "vlm" : nil)
        }
        if kvQuantConfigured {
            return (.contiguous, "kv_quant")
        }
        return (selection, nil)
    }
}
