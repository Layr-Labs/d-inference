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

    @Test(arguments: [
        "qwen3.5-35b-a3b", "qwen3.6-35b-a3b-vl-mtp-mxfp8",
        "EigenLabs/Qwen3.8-27B-4bit-mtp", "gpt-oss-20b", "gemma-4-26b-qat-4bit",
    ])
    func exactReleaseArtifactAutoPolicy(modelID: String) {
        let parsed = EngineV2KVBackendPolicy.parseSelection(
            global: "auto", byModel: [:], modelID: modelID)
        #expect(parsed.selection == .auto)
        #expect(EngineV2KVBackendPolicy.preferredBackend(
            selection: parsed.selection, modelID: modelID) == .paged)
        #expect(EngineV2KVBackendPolicy.degradesPagedFailure(selection: parsed.selection))
        for selection in [EngineV2KVBackendSelection.contiguous, .paged] {
            let override = EngineV2KVBackendPolicy.parseSelection(
                global: "auto", byModel: [modelID: selection.rawValue], modelID: modelID)
            #expect(override.selection == selection)
            #expect(EngineV2KVBackendPolicy.preferredBackend(
                selection: override.selection, modelID: modelID).rawValue == selection.rawValue)
        }
        let automaticOverride = EngineV2KVBackendPolicy.parseSelection(
            global: "contiguous", byModel: [modelID: "auto"], modelID: modelID)
        #expect(automaticOverride.selection == .auto)
        #expect(EngineV2KVBackendPolicy.preferredBackend(
            selection: automaticOverride.selection, modelID: modelID) == .paged)
        #expect(!PrefixCachePolicy.isMemoryEnabled(environment: [:]))
        #expect(PrefixCachePolicy.residentConfig(
            modelId: modelID, promptContractID: "contract", environment: [:]) == nil)
    }

    @Test(arguments: [
        nil, "", "unknown", "gemma-4-26b", "gemma-4-31b", "gemma-4-26b-8bit",
        "gemma-4-26b-qat-4bit-other", "gpt-oss-20b-other",
        "qwen3.5-9b", "qwen3.5-27b", "qwen3.6-35b-a3b",
        "EigenLabs/Qwen3.8-27B-4bit", "Qwen3.8-27B-4bit-mtp",
        "eigenlabs/qwen3.8-27b-4bit-mtp", "QWEN3.5-35B-A3B",
        " qwen3.5-35b-a3b", "qwen3.5-35b-a3b ", "org/qwen3.5-35b-a3b",
        "qwen3.5-35b-a3b-other", "qwen3.6-35b-a3b-vl-mtp-mxfp8-other",
        "EigenLabs/Qwen3.8-27B-4bit-mtp-other",
    ] as [String?])
    func otherIDsRemainContiguous(modelID: String?) {
        #expect(EngineV2KVBackendPolicy.preferredBackend(
            selection: .auto, modelID: modelID) == .contiguous)
        #expect(EngineV2KVBackendPolicy.preferredBackend(
            selection: .contiguous, modelID: modelID) == .contiguous)
        #expect(EngineV2KVBackendPolicy.preferredBackend(
            selection: .paged, modelID: modelID) == .paged)
    }

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
