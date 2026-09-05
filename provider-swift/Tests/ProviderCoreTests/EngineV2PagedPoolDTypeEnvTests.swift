// Copyright © 2026 Eigen Labs.
//
// `DARKBLOOM_CBV2_PAGED_KV_DTYPE` — the paged pool's page dtype, parsed from
// the environment dictionary threaded into `EngineV2Factory`.
//
// The knob REACHES the pool. `EngineBuild.pagedPool` carries the page dtype,
// the slab commitment, the physical capacity the policy allowed, the device
// buffer ceiling and the context the groups are sized against; the runner
// builds the pool from exactly that and then reads the CONSTRUCTED pool back,
// refusing `pagedPoolDTypeUnsupported` if the two disagree. So an fp32
// control arm either measures fp32 or fails loudly — never fp16 wearing an
// fp32 label.
//
// The parse itself is unchanged and still pinned here: a typo REFUSES an
// explicit paged selection rather than defaulting, recognized values
// tolerate case and whitespace, `.auto` never reads the knob at all
// (v0.8.1: `.auto` resolves contiguous), and a contiguous build reports NO
// page dtype rather than the value that was asked for.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXRunners
import Testing

@testable import ProviderCore

// MARK: - Fixture

private func dtypeFixtureModel() throws -> GPTOSSModel {
    let data = try JSONSerialization.data(withJSONObject: [
        "model_type": "gpt_oss",
        "num_hidden_layers": 2,
        "num_local_experts": 4,
        "num_experts_per_tok": 2,
        "vocab_size": 128,
        "rms_norm_eps": 1e-5,
        "hidden_size": 64,
        "intermediate_size": 64,
        "head_dim": 64,
        "num_attention_heads": 4,
        "num_key_value_heads": 2,
        "sliding_window": 32,
    ])
    let config = try JSONDecoder().decode(GPTOSSConfiguration.self, from: data)
    return GPTOSSModel(config)
}

private let dtypeTestCapacity = 8 << 20
private let dtypeTestConcurrency = 2
private let dtypeTestContext = 2048

/// The production DECISION for a paged selection under `environment`.
private func pagedDecision(
    environment: [String: String],
    kvBackend: EngineV2KVBackendSelection = .paged,
    capacityBytes: Int = dtypeTestCapacity
) throws -> EngineV2Factory.ProductionBackendPreparation {
    let model = try dtypeFixtureModel()
    return try EngineV2Factory.prepareProductionBackend(
        runner: StubRunner(
            layerKinds: model.cbv2LayerKinds, capabilities: .attentionOnly),
        kvBytesCapacity: capacityBytes,
        maxConcurrentRequests: dtypeTestConcurrency,
        kvBackend: kvBackend,
        maxContextLength: dtypeTestContext,
        environment: environment,
        pagedPreflightOverride: { _ in })
}

// MARK: - Tests

@Suite("Paged page-dtype knob")
struct EngineV2PagedPoolDTypeEnvTests {

    @Test("the parse maps the two recognized spellings and defaults to float16")
    func parseMapsRecognizedValues() throws {
        #expect(try EngineV2Factory.pagedPoolDType(environment: [:]) == .float16)
        #expect(
            try EngineV2Factory.pagedPoolDType(
                environment: [EngineV2Factory.pagedPoolDTypeEnvKey: ""]) == .float16)
        #expect(
            try EngineV2Factory.pagedPoolDType(
                environment: [EngineV2Factory.pagedPoolDTypeEnvKey: "float16"]) == .float16)
        #expect(
            try EngineV2Factory.pagedPoolDType(
                environment: [EngineV2Factory.pagedPoolDTypeEnvKey: "float32"]) == .float32)
    }

    @Test("recognized values tolerate case and surrounding whitespace")
    func parseNormalizesWhatCannotBeMisread() throws {
        #expect(
            try EngineV2Factory.pagedPoolDType(
                environment: [EngineV2Factory.pagedPoolDTypeEnvKey: " FLOAT32\n"])
                == .float32)
        #expect(
            try EngineV2Factory.pagedPoolDType(
                environment: [EngineV2Factory.pagedPoolDTypeEnvKey: "  Float16  "])
                == .float16)
    }

    @Test("an unrecognized value REFUSES instead of silently serving float16")
    func typoRefusesExplicitPaged() throws {
        #expect(throws: EngineV2ProductionError.self) {
            _ = try EngineV2Factory.pagedPoolDType(
                environment: [EngineV2Factory.pagedPoolDTypeEnvKey: "fp32"])
        }
        // Classified apart from a paged-infrastructure failure: a typo in a
        // measurement knob must stay separable from paged breaking.
        #expect(
            EngineV2RefusalReason.classify(
                EngineV2ProductionError.invalidPagedPoolDType("fp32"))
                == .pagedKVDTypeInvalid)
        do {
            _ = try pagedDecision(
                environment: [EngineV2Factory.pagedPoolDTypeEnvKey: "fp32"])
            Issue.record("expected the explicit paged selection to refuse")
        } catch let error as EngineV2ProductionError {
            guard case .invalidPagedPoolDType = error else {
                Issue.record("expected invalidPagedPoolDType, got \(error)")
                return
            }
        }
    }

    @Test("the pool plan the caller states is the one that crosses on EngineBuild")
    func poolPlanCrossesOnEngineBuild() throws {
        // Hermetic: no live-memory input. `PagedKVPhysicalCapacityPolicy`
        // measures the box, so the end-to-end decision below can legitimately
        // refuse on a machine with no headroom; the plan-to-`EngineBuild`
        // wiring must be provable regardless.
        let plan = PagedPoolPlan(
            dtype: .float32,
            slabCommitment: .atFirstAdmission,
            nominalMaxSequenceLength: dtypeTestContext,
            capacityBytes: 4 << 20,
            maxBufferLength: 1 << 30)
        let runner = StubRunner(
            layerKinds: try dtypeFixtureModel().cbv2LayerKinds,
            capabilities: .attentionOnly)
        let build = try EngineV2Factory.makeRunnerBuild(
            runner: runner,
            decoder: .serial,
            policy: EngineV2RunnerPolicy(
                kvBackendKind: .paged,
                kvBytesCapacity: 4 << 20,
                schedulerConfig: CBv2SchedulerConfig(),
                loopConfig: CBv2EngineLoopConfig(),
                pagedPool: plan,
                environment: [:]))
        let received = try #require(runner.receivedBuild)
        #expect(received.kvBackend == .paged)
        #expect(received.pagedPool == plan)
        // What the build REPORTS is the dtype the pool was built with; the
        // runner refuses by name when its constructed pool disagrees.
        #expect(build.pagedPoolDType == "float32")
    }

    @Test("an explicit float32 request reaches the pool plan the runner builds from")
    func float32ReachesThePoolPlan() throws {
        let prepared: EngineV2Factory.ProductionBackendPreparation
        do {
            prepared = try pagedDecision(
                environment: [EngineV2Factory.pagedPoolDTypeEnvKey: "float32"])
        } catch let error as EngineV2ProductionError {
            // A box with no live KV headroom cannot plan ANY pool — the
            // physical-capacity policy refuses before the dtype matters.
            // That is the policy working, not this property failing, and
            // `poolPlanCrossesOnEngineBuild` covers the wiring hermetically.
            guard case .pagedUnavailable(let reason) = error,
                reason.hasPrefix("physical_capacity:")
            else { throw error }
            withKnownIssue("no live KV headroom on this box to plan a pool") {
                Issue.record("physical-capacity policy refused: \(reason)")
            }
            return
        }
        #expect(prepared.kind == .paged)
        #expect(prepared.pagedPoolDType == "float32")
        let plan = try #require(prepared.pagedPool)
        #expect(plan.dtype == .float32)
        // The production posture, unchanged by the move: slabs are wired at
        // the pool's FIRST ADMISSION, so a slot that has served nothing does
        // not hold unified memory the next model's headroom guard measures.
        #expect(plan.slabCommitment == .atFirstAdmission)
        // Physical capacity is the policy's, not the raw grant, and the
        // device's own buffer ceiling is passed rather than assumed.
        #expect(plan.capacityBytes == prepared.kvBytesCapacity)
        #expect(plan.capacityBytes ?? 0 <= dtypeTestCapacity)
        #expect(plan.maxBufferLength != nil)
        #expect(plan.nominalMaxSequenceLength == dtypeTestContext)

        // And it crosses to the runner on `EngineBuild`.
        let runner = StubRunner(
            layerKinds: try dtypeFixtureModel().cbv2LayerKinds,
            capabilities: .attentionOnly)
        let build = try EngineV2Factory.assembleProductionBuild(
            runner: runner,
            prefixCache: nil,
            mtpConfig: CBv2MTPConfig(),
            preparedBackend: prepared,
            environment: [:])
        let received = try #require(runner.receivedBuild)
        #expect(received.kvBackend == .paged)
        #expect(received.pagedPool == plan)
        #expect(build.pagedPoolDType == "float32")
    }

    @Test("a pool built with other arithmetic is refused BY NAME, not reported")
    func mismatchedPoolRefuses() {
        // The runner's own guard, and the reason the provider reports for it:
        // an explicit paged run that could not be served. A control arm that
        // silently ran the baseline looks exactly like agreement.
        let error = RunnerError.pagedPoolDTypeUnsupported(
            requested: "float32", served: "float16")
        #expect("\(error)".contains("float32"))
        #expect("\(error)".contains("float16"))
        #expect(EngineV2RefusalReason.classify(error) == .pagedBackendUnavailable)
    }

    @Test("`.auto` IGNORES the page dtype entirely — malformed or not (v0.8.1)")
    func autoIgnoresThePageDTypeKnob() throws {
        for value in ["float32", "fp32", "garbage"] {
            let prepared = try pagedDecision(
                environment: [EngineV2Factory.pagedPoolDTypeEnvKey: value],
                kvBackend: .auto)
            #expect(prepared.kind == .contiguous, "value=\(value)")
            #expect(prepared.fallbackReason == nil, "value=\(value)")
            #expect(prepared.pagedPoolDType == nil, "value=\(value)")
            #expect(prepared.pagedPool == nil, "value=\(value)")
        }
    }

    @Test("the contiguous backend ignores the knob and reports no page dtype")
    func contiguousReportsNoPageDType() throws {
        let prepared = try pagedDecision(
            environment: [EngineV2Factory.pagedPoolDTypeEnvKey: "float32"],
            kvBackend: .contiguous)
        #expect(prepared.kind == .contiguous)
        #expect(prepared.pagedPoolDType == nil)
        #expect(prepared.pagedPool == nil)
    }

    @Test("a float32 request that DEGRADES reports no dtype, not float32")
    func degradedFloat32ReportsNoDType() throws {
        // The kill switch degrades an explicit paged selection, so the knob
        // is inert before it is ever read — the build reports a contiguous
        // slot with no pages, never the value the operator set.
        let prepared = try pagedDecision(environment: [
            EngineV2Factory.pagedPoolDTypeEnvKey: "float32",
            EngineV2KVBackendPolicy.killSwitchEnvKey: "0",
        ])
        #expect(prepared.kind == .contiguous)
        #expect(prepared.fallbackReason == "kill_switch")
        #expect(prepared.pagedPoolDType == nil)
    }

    @Test("the operator-facing name round-trips the values the knob accepts")
    func dtypeNameRoundTrips() {
        #expect(EngineV2Factory.pagedPoolDTypeName(.float16) == "float16")
        #expect(EngineV2Factory.pagedPoolDTypeName(.float32) == "float32")
    }
}
