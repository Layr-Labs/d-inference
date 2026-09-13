import Foundation
import MLX
import MLXLLM
import Testing
@_spi(Diagnostics) @testable import MLXLMCommon
@testable import ProviderCore

@Suite("Attention metadata production cache owners", .serialized)
struct AttentionMetadataProductionOwnerTests {
    private func model() throws -> Qwen35MoEModel {
        let configuration = try JSONDecoder().decode(Qwen35Configuration.self, from: Data("""
            {"model_type":"qwen3_5_moe","text_config":{
              "model_type":"qwen3_5_moe_text","hidden_size":64,"num_hidden_layers":40,
              "intermediate_size":32,"num_attention_heads":2,"num_key_value_heads":1,
              "head_dim":64,"linear_num_value_heads":1,"linear_num_key_heads":1,
              "linear_key_head_dim":64,"linear_value_head_dim":64,"linear_conv_kernel_dim":4,
              "full_attention_interval":4,"vocab_size":64,"num_experts":4,
              "num_experts_per_tok":2,"moe_intermediate_size":32,
              "shared_expert_intermediate_size":32,"norm_topk_prob":true}}
            """.utf8))
        return Qwen35MoEModel(configuration)
    }

    private func run(_ model: Qwen35MoEModel, capture: Bool) async throws
        -> (tokens: [Int], snapshot: CBv2AttentionMetadataSnapshot?) {
        // This is the real factory path that passes the adapter's original
        // model indices into contiguous caches. Do not rebuild a dense bank.
        let prepared = try EngineV2Factory.prepareProductionBackend(
            model: model, kvBytesCapacity: 32 << 20, maxConcurrentRequests: 1,
            kvBackend: .contiguous, maxContextLength: 64, environment: [:])
        let (backend, caches) = try prepared.consume(model: model, maxConcurrentRequests: 1)
        let originalIndices = Array(stride(from: 3, through: 39, by: 4))
        #expect(caches.map(\.layerIndex) == originalIndices)
        #expect(prepared.layerKinds.compactMap(\.modelLayerIndex) == originalIndices)
        let engine = EngineV2(
            model: CBv2SteppableLanguageModelAdapter(model), layerKinds: prepared.layerKinds,
            backend: backend, cacheProvider: CBv2LayerCacheBank(caches: caches),
            sampler: CBv2GreedySampler(), schedulerConfig: .init(
                maxConcurrentRequests: 1, maxBatchedTokensPerStep: 8, prefillChunkSize: 8,
                maxWaiting: 4, enablePrefixCache: false))
        do {
            if capture { try engine.configureAttentionMetadata(.init(requestID: 2, outputIndex: 2)) }
            let stream = try engine.submit(.init(id: .init(2), promptTokens: [1, 2, 3, 4],
                sampling: .init(temperature: 0), maxTokens: 4, prefixCacheEnabled: false))
            var tokens: [Int] = []
            var terminated = false
            for await event in stream {
                switch event {
                case .delta(_, let emitted, _): tokens += emitted
                case .finished(let reason, _):
                    #expect(reason == .length)
                    terminated = true
                }
            }
            #expect(terminated && tokens.count == 4)
            var snapshot: CBv2AttentionMetadataSnapshot?
            var idle = false
            for _ in 0..<500 {
                do { snapshot = try engine.takeAttentionMetadataSnapshot(); idle = true; break }
                catch { try await Task.sleep(for: .milliseconds(2)) }
            }
            #expect(idle)
            #expect(caches.map(\.layerIndex) == originalIndices)
            #expect(caches.allSatisfy { ($0 as? CBv2LayerCache)?.attentionMetadata == nil })
            await engine.shutdown()
            return (tokens, snapshot)
        } catch {
            await engine.shutdown()
            throw error
        }
    }

    @Test func realQwenAdapterPreservesTenOriginalIndicesAndRecordsTenDenseOwners() async throws {
        let model = try model()
        let control = try await run(model, capture: false)
        let observed = try await run(model, capture: true)
        #expect(control.tokens == observed.tokens)
        #expect(control.snapshot == nil)
        let snapshot = try #require(observed.snapshot)
        #expect(snapshot.selectedForwards == 1 && snapshot.expectedOwnerCount == 10)
        #expect(snapshot.forwardSucceeded && snapshot.sampleOutcome == "confirmed")
        #expect(snapshot.refusals.isEmpty)
        #expect(snapshot.records.map(\.storageLayerIndex) == Array(0..<10))
        #expect(snapshot.records.map(\.modelLayerIndex) == Array(stride(from: 3, through: 39, by: 4)))
        #expect(snapshot.records.allSatisfy { $0.dispatch == "contiguous_sdpa" && $0.outputIndex == 2 })
        #expect(snapshot.seedToken == observed.tokens[1] && snapshot.targetToken == observed.tokens[2])
    }
}
