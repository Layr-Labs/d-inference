import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import MLXRandom
import Testing
@_spi(Benchmarking) @testable import ProviderCore

@Suite("Explicit Gemma benchmark verifier control", .serialized)
struct EngineV2BenchmarkMTPVerificationTests {
    private let disabledCache = ["DARKBLOOM_PREFIX_CACHE": "0", "DARKBLOOM_PREFIX_CACHE_MEMORY": "0"]

    @Test func scopeRefusesNonisolatedAndNonproductionRequests() throws {
        for mode in [EngineV2BenchmarkMTPVerification.automatic, .serialTarget] {
            try mode.validateScope(mtpEnabled: true, concurrency: 1, productionGrant: true,
                backend: "paged", environment: disabledCache)
            for (mtp, batch, grant, backend, env) in [
                (false, 1, true, "paged", disabledCache),
                (true, 2, true, "paged", disabledCache),
                (true, 1, false, "paged", disabledCache),
                (true, 1, true, "auto", disabledCache),
                (true, 1, true, "paged", ["DARKBLOOM_PREFIX_CACHE": "1"]),
                (true, 1, true, "paged", ["DARKBLOOM_PREFIX_CACHE": "1", "DARKBLOOM_PREFIX_CACHE_MEMORY": "1"]),
            ] {
                #expect(throws: EngineV2BenchmarkMTPVerification.Failure.invalidScope) {
                    try mode.validateScope(mtpEnabled: mtp, concurrency: batch, productionGrant: grant,
                        backend: backend, environment: env)
                }
            }
        }
        #expect(EngineV2BenchmarkMTPVerification(rawValue: "rectangular") == nil)
        #expect(EngineV2BenchmarkMTPVerification(rawValue: "rectangular_exact") == nil)
    }

    private func target() throws -> Gemma4TextModel {
        let json = """
            {"model_type":"gemma4_text","hidden_size":64,"num_hidden_layers":2,
             "intermediate_size":128,"num_attention_heads":2,"head_dim":64,
             "global_head_dim":64,"num_key_value_heads":1,"num_kv_shared_layers":0,
             "layer_types":["sliding_attention","full_attention"],"sliding_window":16,
             "final_logit_softcapping":30.0,"tie_word_embeddings":false,"vocab_size":128,
             "vocab_size_per_layer_input":128,"rms_norm_eps":1e-6,"hidden_size_per_layer_input":0,
             "use_double_wide_mlp":false}
            """
        MLXRandom.seed(0x6144)
        return Gemma4TextModel(try JSONDecoder().decode(
            Gemma4TextConfiguration.self, from: Data(json.utf8)))
    }

    private final class Prepared: CBv2MTPPreparedCapture {}
    private final class OtherTarget: Module, LanguageModel {
        func prepare(_ input: LMInput, cache: [KVCache], windowSize: Int?) throws -> PrepareResult {
            .tokens(input.text)
        }
        func newCache(parameters: GenerateParameters?) -> [KVCache] { [] }
    }
    private class Drafter: CBv2MTPDrafter {
        let mtpTargetIdentity: ObjectIdentifier?
        let requiredVerificationMode: CBv2MTPVerificationMode?
        init(target: any LanguageModel, required: CBv2MTPVerificationMode? = nil) {
            mtpTargetIdentity = ObjectIdentifier(target)
            requiredVerificationMode = required
        }
        func prepare(rows: [CBv2MTPRowCapture]) -> CBv2MTPPreparedCapture { Prepared() }
        func draftStep(tokens: MLXArray, hidden: MLXArray, prepared: CBv2MTPPreparedCapture)
            -> (tokens: MLXArray, hidden: MLXArray)
        { (tokens.reshaped([-1]), hidden) }
    }

    private final class StatefulDrafter: Drafter, CBv2MTPRequestStatefulDrafter {
        private final class State: CBv2MTPRequestState {
            let committedInputCount = 0
            let stagedInputCount = 0
        }
        func makeRequestState() -> any CBv2MTPRequestState { State() }
        func observeCommittedTarget(_ observation: CBv2MTPCommittedTargetObservation,
            requestState: any CBv2MTPRequestState) {}
        func draftStep(tokens: MLXArray, hidden: MLXArray, shortlist: MLXArray?,
            requestState: any CBv2MTPRequestState) -> (tokens: MLXArray, hidden: MLXArray)
        { (tokens.reshaped([-1]), hidden) }
        func evaluationTargets(for requestState: any CBv2MTPRequestState) -> [MLXArray] { [] }
        func finalizeRound(requestState: any CBv2MTPRequestState, confirmedInputTokens: Int,
            committedDraftTokens: MLXArray, committedTargetHidden: MLXArray) {}
        func discardRound(requestState: any CBv2MTPRequestState) {}
        func releaseRequestState(_ requestState: any CBv2MTPRequestState) {}
    }

    @Test func onlyVerifierModeChangesAndConflictingAssistantIsRejected() throws {
        let model = try target(), other = try target()
        let original = CBv2MTPConfig(enabled: true, maxDraftTokens: 7,
            maxSpeculativeBatch: 8, fixedDraftTokens: 1,
            verificationMode: .automatic, maxAutomaticRectangularTokens: 8)
        for mode in [EngineV2BenchmarkMTPVerification.automatic, .serialTarget] {
            let selected = try mode.applying(to: original, target: model, drafter: Drafter(target: model))
            #expect(selected.verificationMode == (mode == .automatic ? .automatic : .serialTarget))
            #expect(selected.enabled == original.enabled && selected.maxDraftTokens == original.maxDraftTokens)
            #expect(selected.fixedDraftTokens == original.fixedDraftTokens)
            #expect(selected.maxSpeculativeBatch == original.maxSpeculativeBatch)
            #expect(selected.maxAutomaticRectangularTokens == original.maxAutomaticRectangularTokens)
            for drafter in [nil, Drafter(target: other), Drafter(target: model, required: .rectangularExact),
                Drafter(target: model, required: .serialTarget), StatefulDrafter(target: model)] {
                #expect(throws: EngineV2BenchmarkMTPVerification.Failure.unsupportedTargetOrAssistant) {
                    try mode.applying(to: original, target: model, drafter: drafter)
                }
            }
            var invalid = original
            invalid.fixedDraftTokens = 2
            #expect(throws: EngineV2BenchmarkMTPVerification.Failure.unexpectedConfiguration) {
                try mode.applying(to: invalid, target: model, drafter: Drafter(target: model))
            }
            let unsupported = OtherTarget()
            #expect(throws: EngineV2BenchmarkMTPVerification.Failure.unsupportedTargetOrAssistant) {
                try mode.applying(to: original, target: unsupported, drafter: Drafter(target: unsupported))
            }
            #expect(throws: EngineV2BenchmarkMTPVerification.Failure.unexpectedEffectiveMode) {
                try mode.validateObservedMetrics(nil)
            }
            var metrics = CBv2MTPMetrics()
            metrics.verificationMode = selected.verificationMode
            try mode.validateObservedMetrics(metrics)
            #expect(throws: EngineV2BenchmarkMTPVerification.Failure.unexpectedVerificationRounds) {
                try mode.validateObservedMetrics(metrics, requireRounds: true)
            }
            metrics.rounds = 3
            metrics.rectangularVerificationRounds = mode == .automatic ? 3 : 0
            metrics.serialVerificationRounds = mode == .serialTarget ? 3 : 0
            try mode.validateObservedMetrics(metrics, requireRounds: true)
            if mode == .automatic { metrics.serialVerificationRounds = 1 }
            else { metrics.rectangularVerificationRounds = 1 }
            #expect(throws: EngineV2BenchmarkMTPVerification.Failure.unexpectedVerificationRounds) {
                try mode.validateObservedMetrics(metrics, requireRounds: true)
            }
            metrics.verificationMode = mode == .automatic ? .serialTarget : .automatic
            #expect(throws: EngineV2BenchmarkMTPVerification.Failure.unexpectedEffectiveMode) {
                try mode.validateObservedMetrics(metrics)
            }
        }
    }

    @Test func qatProductionDefaultDoesNotHideExplicitRectangularDiagnostics() throws {
        let model = try target()
        let drafter = Drafter(target: model)
        let production = providerMTPVerificationPolicy(for: drafter,
            modelID: "gemma-4-26b-qat-4bit", automaticRectangularTokens: 8)
        #expect(production.mode == .serialTarget)
        for mode in [EngineV2BenchmarkMTPVerification.automatic, .serialTarget] {
            let baseline = providerMTPVerificationPolicy(for: drafter,
                modelID: "gemma-4-26b-qat-4bit", benchmarkVerification: mode,
                automaticRectangularTokens: 8)
            let config = CBv2MTPConfig(enabled: true, fixedDraftTokens: 1,
                verificationMode: baseline.mode,
                maxAutomaticRectangularTokens: baseline.automaticRectangularTokens)
            let selected = try mode.applying(to: config, target: model, drafter: drafter)
            #expect(selected.enabled && selected.fixedDraftTokens == 1)
            #expect(selected.verificationMode == (mode == .automatic ? .automatic : .serialTarget))
            #expect(selected.maxAutomaticRectangularTokens == 8)
            let required = Drafter(target: model, required: .serialTarget)
            let protected = providerMTPVerificationPolicy(for: required,
                modelID: "gemma-4-26b-qat-4bit", benchmarkVerification: mode,
                automaticRectangularTokens: 8)
            #expect(protected.mode == .serialTarget && protected.automaticRectangularTokens == 0)
            #expect(throws: EngineV2BenchmarkMTPVerification.Failure.unsupportedTargetOrAssistant) {
                try mode.applying(to: config, target: model, drafter: required)
            }
        }
    }

    @Test(arguments: [EngineV2BenchmarkMTPVerification.automatic, .serialTarget], ["contiguous", "paged"])
    func actualGemmaEngineExecutesSelectedRoundsAndRetires(
        mode: EngineV2BenchmarkMTPVerification, backendName: String
    ) async throws {
        let model = try target()
        model.update(parameters: ModuleParameters.unflattened(
            model.parameters().flattened().map { ($0.0, $0.1.asType(.bfloat16)) }))
        eval(model)
        let drafter = Drafter(target: model)
        let configuration = try mode.applying(to: .init(enabled: true,
            fixedDraftTokens: 1, verificationMode: .automatic, maxAutomaticRectangularTokens: 8),
            target: model, drafter: drafter)
        let backend: any CBv2KVBackend
        let bank: CBv2LayerCacheBank
        if backendName == "paged" {
            let paged = try PagedKVBackend(layerKinds: model.cbv2LayerKinds, config: .init(
                capacityBytes: 16 << 20, dtype: .bfloat16, maxPrefillChunk: 16,
                nominalMaxSequenceLength: 128, segmentSizeBytes: 1 << 18))
            backend = paged
            bank = CBv2LayerCacheBank(caches: paged.makeLayerCaches())
        } else {
            backend = CBv2ContiguousKVBackend(config: .init(bytesCapacity: 16 << 20))
            bank = CBv2LayerCacheBank(layerKinds: model.cbv2LayerKinds)
        }
        let engine = EngineV2(model: CBv2SteppableLanguageModelAdapter(model),
            layerKinds: model.cbv2LayerKinds, backend: backend, cacheProvider: bank,
            sampler: CBv2GreedySampler(), schedulerConfig: .init(maxConcurrentRequests: 1,
                maxBatchedTokensPerStep: 64, prefillChunkSize: 16, maxWaiting: 4, enablePrefixCache: false),
            mtpDrafter: drafter, mtpConfig: configuration)
        do {
            var tokens: [Int] = []
            var finish: CBv2FinishReason?
            for await event in try engine.submit(.init(id: .init(1), promptTokens: [3, 7, 11, 19],
                sampling: .init(temperature: 0), maxTokens: 12, prefixCacheEnabled: false)) {
                switch event {
                case .delta(_, let ids, _): tokens += ids
                case .finished(let reason, _): finish = reason
                }
            }
            #expect(finish == .length && tokens.count == 12)
            let metrics = try #require(engine.mtpMetricsSnapshot())
            try mode.validateObservedMetrics(metrics, requireRounds: true)
            #expect(metrics.rounds > 0)
            #expect(mode == .automatic
                ? metrics.rectangularVerificationRounds > 0 && metrics.serialVerificationRounds == 0
                : metrics.serialVerificationRounds > 0 && metrics.rectangularVerificationRounds == 0)
            await engine.shutdown()
            #expect(backend.bytesReserved == 0)
        } catch {
            await engine.shutdown()
            throw error
        }
    }
}
