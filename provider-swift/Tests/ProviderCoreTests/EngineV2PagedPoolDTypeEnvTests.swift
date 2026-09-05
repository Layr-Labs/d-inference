// Copyright © 2026 Eigen Labs.
//
// `DARKBLOOM_CBV2_PAGED_KV_DTYPE` — the paged pool's page dtype, parsed from
// the environment dictionary threaded into `EngineV2Factory`.
//
// WHAT CHANGED, and why these tests now pin a refusal rather than a pool:
// the paged pool is built by the family's RUNNER inside `makeEngine`, from
// an `EngineBuild` that carries a byte capacity and no page dtype. fp32
// pages are therefore unreachable from here. The knob's whole reason to
// exist is a parity harness's fp32 CONTROL ARM, and a control arm that
// silently ran fp16 under an fp32 label looks exactly like agreement — so
// an explicit paged fp32 request REFUSES, and an `.auto` one degrades with
// its reason named. Restoring the capability is a fork change:
// `EngineBuild` must carry the page dtype so `RunnerEngineAssembly` can
// build the pool with it.
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

    @Test("an explicit float32 request REFUSES rather than serving float16 pages")
    func float32RefusesOnTheRunnerPath() throws {
        do {
            _ = try pagedDecision(
                environment: [EngineV2Factory.pagedPoolDTypeEnvKey: "float32"])
            Issue.record("expected the fp32 page request to refuse")
        } catch let error as EngineV2ProductionError {
            guard case .pagedUnavailable(let reason) = error else {
                Issue.record("expected pagedUnavailable, got \(error)")
                return
            }
            // The reason NAMES the missing seam, so whoever reads the 503
            // knows this is not paged infrastructure failing.
            #expect(reason.hasPrefix("paged_dtype_unsupported:"))
            #expect(reason.contains("EngineBuild"))
            #expect(
                EngineV2RefusalReason.classify(error) == .pagedBackendUnavailable)
        }
    }

    @Test("a resolved paged build reports float16 — the pages it will actually have")
    func resolvedPagedReportsFloat16() throws {
        let prepared = try pagedDecision(environment: [:])
        #expect(prepared.kind == .paged)
        #expect(prepared.pagedPoolDType == "float16")
        #expect(prepared.kvBytesCapacity <= dtypeTestCapacity)
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
        }
    }

    @Test("the contiguous backend ignores the knob and reports no page dtype")
    func contiguousReportsNoPageDType() throws {
        let prepared = try pagedDecision(
            environment: [EngineV2Factory.pagedPoolDTypeEnvKey: "float32"],
            kvBackend: .contiguous)
        #expect(prepared.kind == .contiguous)
        #expect(prepared.pagedPoolDType == nil)
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
