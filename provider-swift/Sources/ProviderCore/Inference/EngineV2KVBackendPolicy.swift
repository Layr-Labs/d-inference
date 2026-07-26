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
//   2. Slot veto (`EngineV2SlotFactory`): a VLM slot may serve on paged
//      only while the paged cache AFFIRMS that it applies multimodal span
//      masks (`PagedLayerCache.honorsSpanMaskContextsByConstruction`).
//      Without that affirmation vision requests would 4xx at submit with
//      `CBv2MultimodalError.unsupportedBackend`, so the slot is forced to
//      contiguous. A veto is POLICY, not failure, so it stays silent even
//      under an explicit "paged" selection; only layer 5 refuses. This
//      layer is collapsing toward the identity function — the kv-quant
//      veto went with the feature, and the VLM veto now lifts ITSELF for
//      any backend whose cache vouches.
//   3. Fleet kill switch: `DARKBLOOM_CBV2_PAGED_KV=0` forces contiguous
//      everywhere, enforced at engine construction (the deepest layer) so
//      no call path can bypass it. Forwarded through the launchd plist
//      (`LaunchAgent.passthroughEnvKeys`) so an operator kill survives
//      install/restart — the same rationale as the SSD tier's switch.
//   4. "auto" is production-safe and resolves PAGED as of v0.8.0.
//      Contiguous remains fully supported and is one config value away
//      (`engine_v2_kv_backend = "contiguous"`), plus the fleet-wide kill
//      switch DARKBLOOM_CBV2_PAGED_KV=0. It is NOT deprecated: it is the
//      rollback target and the parity reference the gates measure against.
//      Paged is experimental and requires the explicit "paged" selection.
//      This is intentionally not a family table: adding a future model
//      family cannot silently turn a stale/default config into paged.
//   5. Failure handling, and it depends on WHO asked. Kernel preflight,
//      physical-capacity planning, and `PagedKVBackend` construction can
//      each fail. Under "auto" they degrade to contiguous — a
//      paged-ineligible model must still load and serve. Under an
//      EXPLICIT "paged" they THROW
//      (`EngineV2ProductionError.pagedUnavailable`): with no canary
//      fleet, benchmarks and e2e ARE the safety net, and a silent degrade
//      makes a run report paged while measuring contiguous. The layer-3
//      kill switch is an override, not a failure, and always degrades.

import Foundation

/// The KV backend a production CBv2 engine was actually built with.
public enum EngineV2KVBackendKind: String, Sendable, Equatable {
    case contiguous
    case paged
}

/// Operator-facing backend selection (`engine_v2_kv_backend`).
public enum EngineV2KVBackendSelection: String, Sendable, Equatable, CaseIterable {
    /// Production default: PAGED for every current and future model as of
    /// v0.8.0. Slot vetoes and the kill switch can still land it on
    /// contiguous; `.auto` means "we choose", not "we promise paged".
    case auto
    /// Force paged. VLM slots still resolve contiguous (slot veto), but a
    /// paged FAILURE refuses instead of degrading — see layer 5.
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
    /// selection is then `.auto` (the shipped contiguous default).
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
    /// serve.
    ///
    /// Today that is a VLM slot whose paged cache does NOT vouch for
    /// multimodal span masks. `pagedHonorsSpanMasks` is the cache's own
    /// affirmative claim, not this file's belief about it — callers pass
    /// `PagedLayerCache.honorsSpanMaskContextsByConstruction`, the same
    /// constant the engine's submit-time gate
    /// (`CBv2LayerCacheBank.supportsMultimodalSpans`) resolves to. An
    /// otherwise paged-ELIGIBLE model is not enough on its own: gemma-4's
    /// shapes construct fine and only vision traffic breaks, which is why
    /// layer 5 cannot cover this.
    ///
    /// Deliberately NOT `guard isVLM else { ... }` deleted outright. That
    /// would make the lift unconditional in the other direction — every VLM
    /// slot routed to paged whether or not the cache in front of it honours
    /// spans — which is a capability ASSUMED rather than asked, and the
    /// assumption would sit in a different repository from the mask code
    /// and would not move when it does. Gated on the claim, the veto lifts
    /// itself when the capability becomes real and re-arms if it regresses,
    /// on this backend or any future one, with no second edit here.
    ///
    /// WHAT A VLM SLOT TRADES BY GOING PAGED: as of the frozen-chunk
    /// gather, NOTHING on prefix reuse. This paragraph used to record a
    /// one-window penalty; it is gone, and the history matters because the
    /// penalty was real and someone may remember it.
    ///
    /// `CBv2PrefixReuseCapability.derive` returns `.frozenFullReplay` for
    /// `.pagedFP16` on gemma-4's windowed-then-full shape, at
    /// `windowCount * maxWindow` — the SAME expression contiguous gets, from
    /// the same shared case. Paged formerly paid one extra `maxWindow`
    /// because `PagedLayerCache.prefillKV` assembled
    /// `gather([base, queryStart)) ++ chunk` with the chunk half being the
    /// freshly projected K/V the layer was handed, so a frozen paged row was
    /// exact BEFORE the current chunk and poisoned inside it. It now gathers
    /// the CACHED keys for the frozen chunk instead — matching what
    /// contiguous's `CBv2FrozenReplayFullSequenceKV.update` always did — so
    /// the first exact position is no longer pushed back and the slack was
    /// deleted rather than tolerated.
    ///
    /// Measured at exact parity on both models: gemma-4 25,600 and gpt-oss
    /// 1,536, each equal to contiguous. Do not re-derive these from this
    /// comment; they follow from `cbv2RequiredRecompute`.
    ///
    /// A veto is POLICY ("we choose not to"), not failure ("we cannot"),
    /// so it is SILENT: it forces contiguous even for an explicit paged
    /// selection rather than throwing `pagedUnavailable`.
    ///
    /// Returns the effective selection plus a veto tag for the slot log.
    public static func applySlotVetoes(
        selection: EngineV2KVBackendSelection,
        isVLM: Bool,
        pagedHonorsSpanMasks: Bool
    ) -> (selection: EngineV2KVBackendSelection, veto: String?) {
        guard selection != .contiguous else { return (.contiguous, nil) }
        guard isVLM, !pagedHonorsSpanMasks else { return (selection, nil) }
        return (.contiguous, selection == .paged ? "vlm" : nil)
    }

    /// Layer 5. Paged could not be built — kernel preflight, physical
    /// capacity planning, or `PagedKVBackend` construction FAILED. True
    /// when the caller must record the reason and degrade to contiguous;
    /// false when it must REFUSE with the reason attached.
    ///
    /// The split is by who asked, not by what broke. `.auto` is the
    /// fleet's default and has promised nothing, so a model that cannot
    /// serve paged must still load and serve. An explicit "paged" — the
    /// operator config, a per-model override, or the benchmark's
    /// `--kv-backend paged` — is a claim someone measures against, and
    /// with no canary fleet those runs ARE the safety net: degrading one
    /// silently makes it report paged while measuring contiguous.
    ///
    /// NOT the same question as the layer-3 kill switch, which always
    /// degrades. A failure means "we CANNOT do what you asked"; the kill
    /// switch means "do NOT do what you asked". Only the first is a
    /// broken promise. Do not collapse them.
    public static func degradesPagedFailure(
        selection: EngineV2KVBackendSelection
    ) -> Bool {
        selection != .paged
    }
}
