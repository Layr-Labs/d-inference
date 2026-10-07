// Copyright © 2026 Eigen Labs.
//
// MTP draft acceptance: the optional `[backend].mtp_acceptance` key, its
// per-model table, resolution precedence, refusal of unknown values, and the
// benchmark-only environment override.

import MLXLMCommon
import Testing

@testable import ProviderCore

@Suite("MTP acceptance config")
struct MTPAcceptanceConfigTests {
    @Test("absent keys decode to nil and an empty table, and resolve to exact")
    func absentKeys() {
        let config = ConfigManager.parse(
            """
            [provider]
            name = "test-provider"

            [backend]
            port = 8100
            """)
        #expect(config.backend.mtpAcceptance == nil)
        #expect(config.backend.mtpAcceptanceByModel.isEmpty)
        let resolved = MTPAcceptancePolicy.resolve(
            global: config.backend.mtpAcceptance,
            byModel: config.backend.mtpAcceptanceByModel,
            modelID: "gemma-4-26b-qat-4bit")
        #expect(resolved.acceptance == .exact)
        #expect(resolved.unrecognized == nil)
    }

    @Test("keys decode and the per-model table outranks the global value")
    func precedence() {
        let config = ConfigManager.parse(
            """
            [provider]
            name = "test-provider"

            [backend]
            mtp_acceptance = "typical"

            [backend.mtp_acceptance_by_model]
            "gemma-4-26b-qat-4bit" = "exact"
            """)
        #expect(config.backend.mtpAcceptance == "typical")
        #expect(config.backend.mtpAcceptanceByModel == ["gemma-4-26b-qat-4bit": "exact"])

        let gemma = MTPAcceptancePolicy.resolve(
            global: config.backend.mtpAcceptance,
            byModel: config.backend.mtpAcceptanceByModel,
            modelID: "gemma-4-26b-qat-4bit")
        #expect(gemma.acceptance == .exact)

        let other = MTPAcceptancePolicy.resolve(
            global: config.backend.mtpAcceptance,
            byModel: config.backend.mtpAcceptanceByModel,
            modelID: "qwen3.8-flash-next")
        #expect(other.acceptance == .typical(delta: CBv2MTPAcceptance.defaultTypicalDelta))
        #expect(other.unrecognized == nil)
    }

    @Test("an unknown value resolves to exact and is reported")
    func unknownValue() {
        let resolved = MTPAcceptancePolicy.resolve(
            global: "fast", byModel: [:], modelID: "m")
        #expect(resolved.acceptance == .exact)
        #expect(resolved.unrecognized == "fast")

        let perModel = MTPAcceptancePolicy.resolve(
            global: "typical", byModel: ["m": "tokenv3"], modelID: "m")
        #expect(perModel.acceptance == .exact)
        #expect(perModel.unrecognized == "tokenv3")

        #expect(MTPAcceptancePolicy.parse(" Typical ") == .typical(delta: 0.2))
        #expect(MTPAcceptancePolicy.parse("EXACT") == .exact)
        #expect(MTPAcceptancePolicy.parse("") == nil)
    }

    @Test("an unset key is not written back; a set key round-trips")
    func serialization() {
        let unset = ProviderConfig(
            provider: ProviderSettings(name: "test-provider"),
            backend: BackendSettings(),
            coordinator: CoordinatorSettings())
        let unsetTOML = ConfigManager.serialize(unset)
        #expect(!unsetTOML.contains("\nmtp_acceptance = "))
        #expect(ConfigManager.parse(unsetTOML).backend.mtpAcceptance == nil)

        let set = ProviderConfig(
            provider: ProviderSettings(name: "test-provider"),
            backend: BackendSettings(
                mtpAcceptance: "typical",
                mtpAcceptanceByModel: ["qwen3.8-flash-next": "exact"]),
            coordinator: CoordinatorSettings())
        let setTOML = ConfigManager.serialize(set)
        #expect(setTOML.contains("mtp_acceptance = 'typical'"))
        let decoded = ConfigManager.parse(setTOML)
        #expect(decoded.backend.mtpAcceptance == "typical")
        #expect(decoded.backend.mtpAcceptanceByModel == ["qwen3.8-flash-next": "exact"])
    }

    @Test("the benchmark override parses a mode and an optional delta")
    func benchmarkOverride() {
        #expect(MTPAcceptancePolicy.benchmarkOverride(environment: [:]) == nil)
        #expect(
            MTPAcceptancePolicy.benchmarkOverride(
                environment: ["DARKBLOOM_MTP_ACCEPTANCE": "exact"]) == .exact)
        #expect(
            MTPAcceptancePolicy.benchmarkOverride(
                environment: ["DARKBLOOM_MTP_ACCEPTANCE": "typical"])
                == .typical(delta: CBv2MTPAcceptance.defaultTypicalDelta))
        #expect(
            MTPAcceptancePolicy.benchmarkOverride(
                environment: ["DARKBLOOM_MTP_ACCEPTANCE": "typical:0.35"])
                == .typical(delta: 0.35))
        // A bad delta keeps the default; a bad mode is ignored.
        #expect(
            MTPAcceptancePolicy.benchmarkOverride(
                environment: ["DARKBLOOM_MTP_ACCEPTANCE": "typical:-1"])
                == .typical(delta: CBv2MTPAcceptance.defaultTypicalDelta))
        #expect(
            MTPAcceptancePolicy.benchmarkOverride(
                environment: ["DARKBLOOM_MTP_ACCEPTANCE": "tokenv3"]) == nil)
    }
}
