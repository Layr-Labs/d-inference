// Copyright © 2026 Eigen Labs.
//
// Pure-logic tests for the paged-KV backend selection policy
// (`EngineV2KVBackendPolicy`): operator-string parsing (per-model override
// precedence, typo fail-safe), the fleet kill switch's negative-only
// semantics, and the slot-veto layer (VLM / kv-quant force contiguous).
// The family/eligibility layers live in `EngineV2KVBackendGateTests`
// (real tiny models); the wire-through lives in the wiring tests.

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
        // Affirmatives and typos leave the default ON — a typo must not
        // flip the fleet.
        for benign in ["1", "true", "yes", "on", "junk", ""] {
            #expect(
                !EngineV2KVBackendPolicy.killSwitchDisabled(environment: [key: benign]),
                "\(benign) must not kill")
        }
    }

    // MARK: slot vetoes

    @Test("VLM and kv-quant force contiguous; clean slots pass through")
    func slotVetoes() {
        // Explicit paged on a VLM slot: vetoed, tagged for the slot log.
        let pagedVLM = EngineV2KVBackendPolicy.applySlotVetoes(
            selection: .paged, isVLM: true, kvQuantConfigured: false)
        #expect(pagedVLM.selection == .contiguous)
        #expect(pagedVLM.veto == "vlm")

        // Auto on a VLM slot resolves contiguous silently (the default
        // doing its job is not an override worth logging).
        let autoVLM = EngineV2KVBackendPolicy.applySlotVetoes(
            selection: .auto, isVLM: true, kvQuantConfigured: false)
        #expect(autoVLM.selection == .contiguous)
        #expect(autoVLM.veto == nil)

        // kv-quant intent vetoes both paged and auto (fp16 pages only).
        for selection in [EngineV2KVBackendSelection.paged, .auto] {
            let vetoed = EngineV2KVBackendPolicy.applySlotVetoes(
                selection: selection, isVLM: false, kvQuantConfigured: true)
            #expect(vetoed.selection == .contiguous)
            #expect(vetoed.veto == "kv_quant")
        }

        // Clean text slots pass through untouched.
        let paged = EngineV2KVBackendPolicy.applySlotVetoes(
            selection: .paged, isVLM: false, kvQuantConfigured: false)
        #expect(paged.selection == .paged)
        #expect(paged.veto == nil)
        let auto = EngineV2KVBackendPolicy.applySlotVetoes(
            selection: .auto, isVLM: false, kvQuantConfigured: false)
        #expect(auto.selection == .auto)
        #expect(auto.veto == nil)

        // Contiguous is never vetoed (nothing to force).
        let contiguous = EngineV2KVBackendPolicy.applySlotVetoes(
            selection: .contiguous, isVLM: true, kvQuantConfigured: true)
        #expect(contiguous.selection == .contiguous)
        #expect(contiguous.veto == nil)
    }
}
