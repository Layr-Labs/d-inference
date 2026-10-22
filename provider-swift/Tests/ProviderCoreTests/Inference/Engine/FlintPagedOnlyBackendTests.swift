// Copyright © 2026 Eigen Labs.
import Foundation
import MLX
import MLXLLM
import Testing
@testable import MLXLMCommon
@testable import ProviderCore

/// Flint is qualified only on paged attention. The production factory must
/// resolve the default configuration to paged and refuse every path that would
/// otherwise serve it contiguous, instead of degrading silently.
@Suite("Flint paged-only KV backend", .serialized)
struct FlintPagedOnlyBackendTests {
    private let modelID = "RecursiveSI/flint-int4"
    private let capacity = 8 << 20

    private func environment(_ overrides: [String: String] = [:]) -> [String: String] {
        [KVBackendGuardStore.pathEnvKey: "/dev/null", EngineV2KVQuantizationPolicy.environmentKey: "native"]
            .merging(overrides) { _, explicit in explicit }
    }

    private func flint() throws -> FlintModel {
        let configuration = try JSONDecoder().decode(FlintConfiguration.self, from: Data("""
        {"model_type":"flint","hidden_size":64,"intermediate_size":64,
         "num_hidden_layers":2,"num_attention_heads":2,"num_key_value_heads":1,
         "head_dim":64,"vocab_size":32,"rms_norm_eps":0.00001,
         "max_position_embeddings":4096,"rope_theta":10000,
         "layer_types":["full_attention","sliding_attention"],
         "no_rope_layer_indices":[0],"mlp_only_layers":[0],"sliding_window":4,
         "num_experts":4,"num_experts_per_tok":2,"moe_intermediate_size":32,
         "shared_expert_intermediate_size":32,"tie_word_embeddings":false,
         "hidden_act":"silu","router_score_function":"sigmoid","softmax_type":"learnable",
         "norm_topk_prob":true,"attention_bias":false,"use_sliding_window":true,
         "decoder_sparse_step":1}
        """.utf8))
        return FlintModel(configuration)
    }

    private func prepare(
        _ selection: EngineV2KVBackendSelection, environment: [String: String],
        preflight: (([CBv2LayerKind]) throws -> Void)? = nil
    ) throws -> EngineV2Factory.ProductionBackendPreparation {
        try EngineV2Factory.prepareProductionBackend(
            model: flint(), modelID: modelID, kvBytesCapacity: capacity, maxConcurrentRequests: 2,
            kvBackend: selection, maxContextLength: 2048, environment: environment,
            pagedPreflightOverride: preflight)
    }

    @Test("the default (automatic) and explicit paged selections resolve to paged")
    func automaticAndExplicitResolvePaged() throws {
        for selection in [EngineV2KVBackendSelection.auto, .paged] {
            let prepared = try prepare(selection, environment: environment())
            #expect(prepared.kind == .paged, "\(selection)")
            #expect(prepared.fallbackReason == nil, "\(selection)")
        }
    }

    @Test("the automatic crash-loop guard cannot move Flint to contiguous")
    func crashLoopGuardDoesNotDegradeFlint() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flint-kv-guard-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let guardEnvironment = environment([KVBackendGuardStore.pathEnvKey: url.path])
        #expect(KVBackendGuardStore.write(
            KVBackendGuard(trippedAt: 1, providerVersion: ProviderCore.version, crashCount: 3),
            environment: guardEnvironment))
        #expect(EngineV2KVBackendPolicy.crashLoopGuardForcesContiguous(
            record: KVBackendGuardStore.read(environment: guardEnvironment),
            runningVersion: ProviderCore.version), "premise: the guard is active")
        let prepared = try prepare(.auto, environment: guardEnvironment)
        #expect(prepared.kind == .paged && prepared.fallbackReason == nil)
    }

    /// The production error a failed preparation threw, so each refusal is
    /// checked for its own reason rather than for any error of the type.
    private func refusal(_ body: () throws -> EngineV2Factory.ProductionBackendPreparation)
        -> EngineV2ProductionError?
    {
        do {
            _ = try body()
            return nil
        } catch {
            return error as? EngineV2ProductionError
        }
    }

    @Test("paged construction failures refuse Flint under the default selection")
    func pagedFailuresRefuseInsteadOfDegrading() throws {
        struct PreflightFailure: Error {}
        let dtype = refusal { try prepare(.auto, environment: environment([EngineV2Factory.pagedPoolDTypeEnvKey: "int3"])) }
        guard case .invalidPagedPoolDType(let raw)? = dtype else {
            Issue.record("invalid paged dtype must refuse, got \(String(describing: dtype))")
            return
        }
        #expect(raw == "int3")
        let preflight = refusal {
            try prepare(.auto, environment: environment(), preflight: { _ in throw PreflightFailure() })
        }
        guard case .pagedUnavailable(let reason)? = preflight else {
            Issue.record("a failed paged preflight must refuse, got \(String(describing: preflight))")
            return
        }
        #expect(reason.hasPrefix("kernel_preflight"), "\(reason)")
        // Positive control: the same preflight hook passing keeps paged.
        #expect(try prepare(.auto, environment: environment(), preflight: { _ in }).kind == .paged)
    }

    @Test("explicit contiguous and the paged kill switch refuse Flint instead of serving contiguous")
    func contiguousIsRefused() throws {
        let cases: [(EngineV2KVBackendSelection, [String: String], String)] = [
            (.contiguous, [:], "Flint requires the paged KV backend; resolved contiguous"),
            (.auto, [EngineV2KVBackendPolicy.killSwitchEnvKey: "0"],
             "Flint requires the paged KV backend; resolved contiguous (kill_switch)"),
            (.paged, [EngineV2KVBackendPolicy.killSwitchEnvKey: "0"],
             "Flint requires the paged KV backend; resolved contiguous (kill_switch)"),
        ]
        for (selection, overrides, expected) in cases {
            let error = refusal { try prepare(selection, environment: environment(overrides)) }
            guard case .pagedUnavailable(let reason)? = error else {
                Issue.record("\(selection) must refuse, got \(String(describing: error))")
                continue
            }
            #expect(reason == expected, "\(selection)")
        }
    }
}
