// Copyright © 2026 Eigen Labs.
//
// Pure-logic tests for the paged-KV backend selection policy
// (`EngineV2KVBackendPolicy`): operator-string parsing (per-model override
// semantics), and the slot-veto layer — a VLM slot is forced to contiguous
// only while the paged cache does NOT vouch for multimodal span masks
// (kv-quant is no longer a veto; the feature is gone from the product).
// The family/eligibility layers live in `EngineV2KVBackendGateTests` (real
// tiny models), which also carries the THROUGH-the-slot-factory test for
// VLM routing; the wire-through lives in the wiring tests.

import MLXLMCommon
import Testing

@testable import ProviderCore

@Suite("EngineV2KVBackendPolicy")
struct EngineV2KVBackendPolicyTests {

    // MARK: parseSelection

    @Test("global value parses; per-model override wins")
    func parsePrecedence() {
        let global = EngineV2KVBackendPolicy.parseSelection(
            global: "paged", byModel: [:], modelID: "gpt-oss-20b")
        #expect(global.selection == .paged)
        #expect(global.unrecognized == nil)

        let overridden = EngineV2KVBackendPolicy.parseSelection(
            global: "paged",
            byModel: ["gpt-oss-20b": "contiguous"],
            modelID: "gpt-oss-20b")
        #expect(overridden.selection == .contiguous)

        let otherModel = EngineV2KVBackendPolicy.parseSelection(
            global: "paged",
            byModel: ["gemma-4-26b": "contiguous"],
            modelID: "gpt-oss-20b")
        #expect(otherModel.selection == .paged)
    }

    @Test("normalization: case + whitespace; empty means auto")
    func parseNormalization() {
        #expect(
            EngineV2KVBackendPolicy.parseSelection(
                global: "  Paged ", byModel: [:], modelID: "m"
            ).selection == .paged)
        #expect(
            EngineV2KVBackendPolicy.parseSelection(
                global: "AUTO", byModel: [:], modelID: "m"
            ).selection == .auto)
        let empty = EngineV2KVBackendPolicy.parseSelection(
            global: "", byModel: [:], modelID: "m")
        #expect(empty.selection == .auto)
        #expect(empty.unrecognized == nil)
    }

    @Test("typo fails safe to auto and reports the raw value")
    func parseTypo() {
        let parsed = EngineV2KVBackendPolicy.parseSelection(
            global: "pagedd", byModel: [:], modelID: "m")
        #expect(parsed.selection == .auto)
        #expect(parsed.unrecognized == "pagedd")

        // A per-model typo reports too (and does NOT fall through to the
        // global value — the operator addressed THIS model explicitly).
        let overrideTypo = EngineV2KVBackendPolicy.parseSelection(
            global: "contiguous", byModel: ["m": "nope"], modelID: "m")
        #expect(overrideTypo.selection == .auto)
        #expect(overrideTypo.unrecognized == "nope")
    }

    // MARK: kill switch

    @Test("kill switch: negative-only semantics")
    func killSwitch() {
        let key = EngineV2KVBackendPolicy.killSwitchEnvKey
        #expect(!EngineV2KVBackendPolicy.killSwitchDisabled(environment: [:]))
        for negative in ["0", "false", "no", "off", " OFF ", "False"] {
            #expect(
                EngineV2KVBackendPolicy.killSwitchDisabled(environment: [key: negative]),
                "\(negative) must kill")
        }
        // Affirmatives and typos leave paged eligibility enabled; this layer
        // says nothing about what `.auto` resolves to, which is decided in
        // `EngineV2Factory.prepareProductionBackend`.
        for benign in ["1", "true", "yes", "on", "junk", ""] {
            #expect(
                !EngineV2KVBackendPolicy.killSwitchDisabled(environment: [key: benign]),
                "\(benign) must not kill")
        }
    }

    // MARK: slot vetoes

    @Test("VLM is vetoed only while the paged cache does not vouch for spans")
    func slotVetoes() {
        // Explicit paged on a VLM slot whose cache does NOT vouch: vetoed,
        // tagged for the slot log. A veto is POLICY, not failure — it must
        // stay a silent force to contiguous, NOT the `pagedUnavailable`
        // refusal an explicit paged request gets when the backend genuinely
        // cannot be built.
        let pagedVLM = EngineV2KVBackendPolicy.applySlotVetoes(
            selection: .paged, isVLM: true, pagedHonorsSpanMasks: false)
        #expect(pagedVLM.selection == .contiguous)
        #expect(pagedVLM.veto == "vlm")

        // Auto on such a VLM slot resolves contiguous silently (the default
        // doing its job is not an override worth logging).
        let autoVLM = EngineV2KVBackendPolicy.applySlotVetoes(
            selection: .auto, isVLM: true, pagedHonorsSpanMasks: false)
        #expect(autoVLM.selection == .contiguous)
        #expect(autoVLM.veto == nil)

        // The LIFT. Once the cache affirms span masks the VLM slot is an
        // ordinary slot: paged passes through, and auto passes through
        // UNVETOED to resolve on its own merits (paged, as of v0.8.0)
        // rather than being forced. This is what makes the veto
        // self-lifting — no edit here was needed for paged to start serving
        // vision, and none will be needed for the next backend that
        // implements it.
        let vouchedPaged = EngineV2KVBackendPolicy.applySlotVetoes(
            selection: .paged, isVLM: true, pagedHonorsSpanMasks: true)
        #expect(vouchedPaged.selection == .paged)
        #expect(vouchedPaged.veto == nil)
        let vouchedAuto = EngineV2KVBackendPolicy.applySlotVetoes(
            selection: .auto, isVLM: true, pagedHonorsSpanMasks: true)
        #expect(vouchedAuto.selection == .auto)
        #expect(vouchedAuto.veto == nil)

        // The claim is consulted ONLY for VLM slots — it must not become a
        // second, backdoor way to disable paged for text.
        for vouches in [true, false] {
            let paged = EngineV2KVBackendPolicy.applySlotVetoes(
                selection: .paged, isVLM: false, pagedHonorsSpanMasks: vouches)
            #expect(paged.selection == .paged)
            #expect(paged.veto == nil)
            let auto = EngineV2KVBackendPolicy.applySlotVetoes(
                selection: .auto, isVLM: false, pagedHonorsSpanMasks: vouches)
            #expect(auto.selection == .auto)
            #expect(auto.veto == nil)

            // Contiguous is never vetoed (nothing to force).
            let contiguous = EngineV2KVBackendPolicy.applySlotVetoes(
                selection: .contiguous, isVLM: true, pagedHonorsSpanMasks: vouches)
            #expect(contiguous.selection == .contiguous)
            #expect(contiguous.veto == nil)
        }

        // And the shipping wiring: what `EngineV2SlotFactory` actually
        // passes is the cache's own constant, so this test tracks the
        // implementation rather than restating a literal.
        let production = EngineV2KVBackendPolicy.applySlotVetoes(
            selection: .paged, isVLM: true,
            pagedHonorsSpanMasks: PagedLayerCache.honorsSpanMaskContextsByConstruction)
        #expect(
            production.selection
                == (PagedLayerCache.honorsSpanMaskContextsByConstruction
                    ? .paged : .contiguous))
    }

    // MARK: post-build serveable-KV guard (PR #531 Codex P1)

    @Test("post-build guard: paged requires pool and whole-machine headroom")
    func postBuildServeableMatrix() {
        let gib: UInt64 = 1 << 30
        // Paged requires BOTH a useful committed pool and safe residual
        // whole-machine headroom.
        #expect(
            KVHeadroomProbe.postBuildServeable(
                kvBackendKind: .paged,
                pagedPoolBytes: 8 * gib,
                measuredHeadroomBytes: 2 * gib))
        #expect(
            !KVHeadroomProbe.postBuildServeable(
                kvBackendKind: .paged,
                pagedPoolBytes: 8 * gib,
                measuredHeadroomBytes: 0))
        #expect(
            !KVHeadroomProbe.postBuildServeable(
                kvBackendKind: .paged, pagedPoolBytes: gib / 2, measuredHeadroomBytes: 100 * gib))
        // Exactly at both floors serves (>= comparator).
        #expect(
            KVHeadroomProbe.postBuildServeable(
                kvBackendKind: .paged,
                pagedPoolBytes: UnifiedMemoryCap.minimumLoadKVBytes,
                measuredHeadroomBytes: UnifiedMemoryCap.minimumLoadKVBytes))
        // Contiguous: classic measured-headroom semantics, pool ignored.
        #expect(
            KVHeadroomProbe.postBuildServeable(
                kvBackendKind: .contiguous, pagedPoolBytes: 0, measuredHeadroomBytes: 2 * gib))
        #expect(
            !KVHeadroomProbe.postBuildServeable(
                kvBackendKind: .contiguous, pagedPoolBytes: 100 * gib,
                measuredHeadroomBytes: gib / 2))
    }
}
