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
    @Test("absent keys decode to nil and an empty table; Gemma QAT and Qwen 3.8 27B resolve to exact")
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
        for id in ["gemma-4-26b-qat-4bit", "EigenLabs/Qwen3.8-27B-4bit-mtp"] {
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

    @Test("explicit exact settings opt out of the typical default")
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
        #expect(other.acceptance == .typical(delta: CBv2MTPAcceptance.defaultTypicalDelta))
    }

    @Test("Qwen3.5-9B defaults to exact; the 35B Qwen builds keep typical; settings still win")
    func qwen35NineBDefaultsToExact() {
        let typical = CBv2MTPAcceptance.typical(delta: CBv2MTPAcceptance.defaultTypicalDelta)
        #expect(MTPAcceptancePolicy.resolve(global: nil, byModel: [:], modelID: "Qwen3.5-9B").acceptance == .exact)
        for id in ["qwen3.5-35b-a3b", "qwen3.6-35b-a3b-vl-mtp-mxfp8", "mlx-community/Qwen3.5-9B-4bit"] {
            #expect(MTPAcceptancePolicy.resolve(global: nil, byModel: [:], modelID: id).acceptance == typical, "\(id)")
        }
        // The precedence is unchanged: a per-model or global value still wins.
        #expect(MTPAcceptancePolicy.resolve(
            global: nil, byModel: ["Qwen3.5-9B": "typical"], modelID: "Qwen3.5-9B").acceptance == typical)
        #expect(MTPAcceptancePolicy.resolve(
            global: "typical", byModel: [:], modelID: "Qwen3.5-9B").acceptance == typical)
    }

    @Test("Gemma 4 26B QAT defaults to exact; every other model keeps its built-in rule; settings still win")
    func gemmaQATDefaultsToExact() {
        let typical = CBv2MTPAcceptance.typical(delta: CBv2MTPAcceptance.defaultTypicalDelta)
        #expect(MTPAcceptancePolicy.resolve(
            global: nil, byModel: [:], modelID: "gemma-4-26b-qat-4bit").acceptance == .exact)
        // Only the QAT build: its 8-bit siblings, and every other drafting model, stay typical
        // (Qwen 3.8 27B is exact too: qwen38DefaultsToExact).
        for id in [
            "gemma-4-26b", "gemma-4-26b-8bit", "qwen3.5-35b-a3b", "qwen3.6-35b-a3b-vl-mtp-mxfp8",
            "nvidia-nemotron-3.5-lightning", "glm-5.3-flash",
        ] {
            #expect(MTPAcceptancePolicy.resolve(global: nil, byModel: [:], modelID: id).acceptance == typical, "\(id)")
        }
        #expect(MTPAcceptancePolicy.resolve(global: nil, byModel: [:], modelID: "Qwen3.5-9B").acceptance == .exact)
        // The precedence is unchanged: a per-model or global value still wins.
        #expect(MTPAcceptancePolicy.resolve(
            global: nil, byModel: ["gemma-4-26b-qat-4bit": "typical"],
            modelID: "gemma-4-26b-qat-4bit").acceptance == typical)
        #expect(MTPAcceptancePolicy.resolve(
            global: "typical", byModel: [:], modelID: "gemma-4-26b-qat-4bit").acceptance == typical)
    }

    @Test("Qwen 3.8 27B defaults to exact; every other model keeps its built-in rule; settings still win")
    func qwen38DefaultsToExact() {
        let typical = CBv2MTPAcceptance.typical(delta: CBv2MTPAcceptance.defaultTypicalDelta)
        // The catalog build, and the same target without its inline head.
        for id in ["EigenLabs/Qwen3.8-27B-4bit-mtp", "EigenLabs/Qwen3.8-27B-4bit"] {
            #expect(MTPAcceptancePolicy.resolve(global: nil, byModel: [:], modelID: id).acceptance == .exact, "\(id)")
        }
        // Only those ids: the Flash-Next artifact, the Qwen 3.8-derived Bonsai 2 27B, a case variant and every
        // other drafting model keep typical.
        for id in [
            "qwen3.8-flash-next", "DarkBloom/Qwen3.8-Flash-Next-Q4-mtp", "ternary-bonsai-2-27b",
            "eigenlabs/qwen3.8-27b-4bit-mtp", "gemma-4-26b", "gemma-4-26b-8bit", "qwen3.5-35b-a3b",
            "qwen3.6-35b-a3b-vl-mtp-mxfp8", "nvidia-nemotron-3.5-lightning", "glm-5.3-flash",
        ] {
            #expect(MTPAcceptancePolicy.resolve(global: nil, byModel: [:], modelID: id).acceptance == typical, "\(id)")
        }
        // The earlier exact builds stay exact.
        for id in ["gemma-4-26b-qat-4bit", "Qwen3.5-9B"] {
            #expect(MTPAcceptancePolicy.resolve(global: nil, byModel: [:], modelID: id).acceptance == .exact, "\(id)")
        }
        // The precedence is unchanged: a per-model or global value still wins.
        #expect(MTPAcceptancePolicy.resolve(
            global: nil, byModel: ["EigenLabs/Qwen3.8-27B-4bit-mtp": "typical"],
            modelID: "EigenLabs/Qwen3.8-27B-4bit-mtp").acceptance == typical)
        #expect(MTPAcceptancePolicy.resolve(
            global: "typical", byModel: [:], modelID: "EigenLabs/Qwen3.8-27B-4bit-mtp").acceptance == typical)
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
