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
    @Test("absent keys decode to nil and an empty table; models resolve to exact")
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
        for id in ["gemma-4-26b-qat-4bit", "EigenLabs/Qwen3.8-27B-4bit-mtp", "glm-5.3-flash"] {
            let resolved = MTPAcceptancePolicy.resolve(
                global: config.backend.mtpAcceptance,
                byModel: config.backend.mtpAcceptanceByModel,
                modelID: id)
            #expect(resolved.acceptance == .exact, "\(id)")
            #expect(resolved.unrecognized == nil, "\(id)")
        }
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

    @Test("explicit exact settings resolve to exact")
    func exactOptOut() {
        let global = MTPAcceptancePolicy.resolve(global: "exact", byModel: [:], modelID: "m")
        #expect(global.acceptance == .exact)
        #expect(global.unrecognized == nil)

        let perModel = MTPAcceptancePolicy.resolve(
            global: nil, byModel: ["m": "exact"], modelID: "m")
        #expect(perModel.acceptance == .exact)
        #expect(perModel.unrecognized == nil)

        let other = MTPAcceptancePolicy.resolve(
            global: nil, byModel: ["m": "exact"], modelID: "other")
        #expect(other.acceptance == .exact)
    }

    @Test("every model defaults to exact; typical only where configured")
    func everyModelDefaultsToExact() {
        let typical = CBv2MTPAcceptance.typical(delta: CBv2MTPAcceptance.defaultTypicalDelta)
        // The builds that were already exact, the served families that were
        // typical (GLM, Qwen 4, Nemotron, Gemma 8-bit), and unknown ids.
        for id in [
            "Qwen3.5-9B", "qwen3.5-35b-a3b", "qwen3.6-35b-a3b-vl-mtp-mxfp8", "gemma-4-26b-qat-4bit",
            "EigenLabs/Qwen3.8-27B-4bit-mtp", "EigenLabs/Qwen3.8-27B-4bit",
            "thinkingmachines/Inkling-2-Mini", "glm-5.3-flash",
            "eigenlabs/glm-5.3-flash-mlx-nvfp4-mtp", "qwen3.8-flash-next",
            "DarkBloom/Qwen3.8-Flash-Next-Q4-mtp", "nvidia-nemotron-3.5-lightning", "gemma-4-26b",
            "gemma-4-26b-8bit", "ternary-bonsai-2-27b", "mlx-community/Qwen3.5-9B-4bit", "m",
        ] {
            #expect(MTPAcceptancePolicy.resolve(global: nil, byModel: [:], modelID: id).acceptance == .exact, "\(id)")
            // A per-model or global value still wins.
            #expect(MTPAcceptancePolicy.resolve(
                global: nil, byModel: [id: "typical"], modelID: id).acceptance == typical, "\(id)")
            #expect(MTPAcceptancePolicy.resolve(
                global: "typical", byModel: [:], modelID: id).acceptance == typical, "\(id)")
            #expect(MTPAcceptancePolicy.resolve(
                global: "typical", byModel: [id: "exact"], modelID: id).acceptance == .exact, "\(id)")
        }
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
