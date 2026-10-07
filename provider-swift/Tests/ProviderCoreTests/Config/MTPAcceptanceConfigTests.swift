// Copyright © 2026 Eigen Labs.
//
// MTP draft acceptance: the per-model `[backend].mtp_acceptance_by_model`
// table, the exact default, the retired global `mtp_acceptance` key, refusal
// of unknown values, the slot capability check, and the benchmark-only
// environment override.

import MLX
import MLXLMCommon
import Testing

@testable import ProviderCore

/// Construction-only drafter on the protocol default: no target-prefix
/// acceptance.
private final class PolicyDrafter: CBv2MTPDrafter {
    private final class Capture: CBv2MTPPreparedCapture {}
    func prepare(rows: [CBv2MTPRowCapture]) -> any CBv2MTPPreparedCapture { Capture() }
    func draftStep(tokens: MLXArray, hidden: MLXArray, prepared: any CBv2MTPPreparedCapture)
        -> (tokens: MLXArray, hidden: MLXArray)
    {
        preconditionFailure("policy fixture must not run draft math")
    }
}

private final class TargetPrefixPolicyDrafter: CBv2MTPDrafter {
    private final class Capture: CBv2MTPPreparedCapture {}
    var supportsTargetPrefixAcceptance: Bool { true }
    func prepare(rows: [CBv2MTPRowCapture]) -> any CBv2MTPPreparedCapture { Capture() }
    func draftStep(tokens: MLXArray, hidden: MLXArray, prepared: any CBv2MTPPreparedCapture)
        -> (tokens: MLXArray, hidden: MLXArray)
    {
        preconditionFailure("policy fixture must not run draft math")
    }
}

private let typical = CBv2MTPAcceptance.typical(delta: CBv2MTPAcceptance.defaultTypicalDelta)

@Suite("MTP acceptance config")
struct MTPAcceptanceConfigTests {
    @Test("an absent table decodes empty and every model resolves to exact")
    func absentKeys() {
        let config = ConfigManager.parse(
            """
            [provider]
            name = "test-provider"

            [backend]
            port = 8100
            """)
        #expect(config.backend.mtpAcceptanceByModel.isEmpty)
        #expect(config.backend.retiredKeysPresent.isEmpty)
        let resolved = MTPAcceptancePolicy.resolve(
            byModel: config.backend.mtpAcceptanceByModel, modelID: "gemma-4-26b-qat-4bit")
        #expect(resolved.acceptance == .exact)
        #expect(resolved.unrecognized == nil)
    }

    @Test("only the per-model table selects a rule; the global key selects nothing")
    func perModelOnly() {
        let config = ConfigManager.parse(
            """
            [provider]
            name = "test-provider"

            [backend]
            mtp_acceptance = "typical"

            [backend.mtp_acceptance_by_model]
            "gemma-4-26b-qat-4bit" = "exact"
            "qwen3.8-flash-next" = "typical"
            """)
        #expect(
            config.backend.mtpAcceptanceByModel
                == ["gemma-4-26b-qat-4bit": "exact", "qwen3.8-flash-next": "typical"])
        func resolve(_ modelID: String) -> MTPAcceptancePolicy.Resolution {
            MTPAcceptancePolicy.resolve(
                byModel: config.backend.mtpAcceptanceByModel, modelID: modelID)
        }
        #expect(resolve("qwen3.8-flash-next").acceptance == typical)
        #expect(resolve("gemma-4-26b-qat-4bit").acceptance == .exact)
        #expect(resolve("gpt-oss-20b").acceptance == .exact)
        #expect(resolve("gpt-oss-20b").unrecognized == nil)
    }

    @Test("a per-model exact entry resolves to exact")
    func perModelExact() {
        let resolved = MTPAcceptancePolicy.resolve(byModel: ["m": "exact"], modelID: "m")
        #expect(resolved.acceptance == .exact)
        #expect(resolved.unrecognized == nil)
        #expect(resolved.unrecognizedWarning(modelID: "m") == nil)
    }

    @Test("a global mtp_acceptance key alone is ignored with one startup warning")
    func globalKeyIsIgnored() {
        let config = ConfigManager.parse(
            """
            [provider]
            name = "test-provider"

            [backend]
            mtp_acceptance = "typical"
            """)
        #expect(config.backend.retiredKeysPresent == ["mtp_acceptance"])
        #expect(config.backend.mtpAcceptanceByModel.isEmpty)
        let warnings = RetiredKnobWarnings.messages(config: config, environment: [:])
            .filter { $0.contains("mtp_acceptance") }
        #expect(warnings.count == 1)
        #expect(warnings.first?.contains("IGNORED") == true)
        #expect(warnings.first?.contains("[backend.mtp_acceptance_by_model]") == true)
    }

    @Test("an unknown per-model value resolves to exact and is reported")
    func unknownValue() {
        let resolved = MTPAcceptancePolicy.resolve(byModel: ["m": "tokenv3"], modelID: "m")
        #expect(resolved.acceptance == .exact)
        #expect(resolved.unrecognized == "tokenv3")
        #expect(
            resolved.unrecognizedWarning(modelID: "m")
                == "engine_v2: unrecognized mtp_acceptance value \"tokenv3\" for m — using \"exact\"")

        #expect(MTPAcceptancePolicy.parse(" Typical ") == .typical(delta: 0.2))
        #expect(MTPAcceptancePolicy.parse("EXACT") == .exact)
        #expect(MTPAcceptancePolicy.parse("") == nil)
    }

    @Test("typical installs only with an enabled drafter that supports target-prefix acceptance")
    func capabilityCheck() {
        let capable = MTPAcceptancePolicy.installation(
            requested: typical, mtpEnabled: true, drafter: TargetPrefixPolicyDrafter())
        #expect(capable == .init(acceptance: typical, fallback: nil))
        #expect(capable.fallbackWarning(modelID: "m") == nil)

        // The protocol default is false: native MiMo and any drafter that does
        // not declare the capability.
        let incapable = MTPAcceptancePolicy.installation(
            requested: typical, mtpEnabled: true, drafter: PolicyDrafter())
        #expect(incapable == .init(acceptance: .exact, fallback: .noTargetPrefixAcceptance))
        #expect(
            incapable.fallbackWarning(modelID: "m")
                == "engine_v2: m cannot use mtp_acceptance \"typical\" (its MTP drafter does not "
                + "support target-prefix acceptance) — using \"exact\"")

        for (enabled, drafter) in [
            (false, TargetPrefixPolicyDrafter() as (any CBv2MTPDrafter)?), (true, nil),
        ] {
            let off = MTPAcceptancePolicy.installation(
                requested: typical, mtpEnabled: enabled, drafter: drafter)
            #expect(off == .init(acceptance: .exact, fallback: .mtpOff))
            #expect(off.fallbackWarning(modelID: "m")?.contains("MTP is off for this slot") == true)
        }

        for drafter in [PolicyDrafter() as (any CBv2MTPDrafter)?, nil] {
            let exact = MTPAcceptancePolicy.installation(
                requested: .exact, mtpEnabled: drafter != nil, drafter: drafter)
            #expect(exact == .init(acceptance: .exact, fallback: nil))
        }
    }

    @Test("the retired global key is not written back; the per-model table round-trips")
    func serialization() {
        let unset = ProviderConfig(
            provider: ProviderSettings(name: "test-provider"),
            backend: BackendSettings(),
            coordinator: CoordinatorSettings())
        #expect(!ConfigManager.serialize(unset).contains("\nmtp_acceptance = "))

        let legacy = ConfigManager.parse(
            """
            [provider]
            name = "test-provider"

            [backend]
            mtp_acceptance = "typical"
            """)
        #expect(!ConfigManager.serialize(legacy).contains("\nmtp_acceptance = "))

        let set = ProviderConfig(
            provider: ProviderSettings(name: "test-provider"),
            backend: BackendSettings(mtpAcceptanceByModel: ["qwen3.8-flash-next": "typical"]),
            coordinator: CoordinatorSettings())
        let decoded = ConfigManager.parse(ConfigManager.serialize(set))
        #expect(decoded.backend.mtpAcceptanceByModel == ["qwen3.8-flash-next": "typical"])
        #expect(decoded.backend.retiredKeysPresent.isEmpty)
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
