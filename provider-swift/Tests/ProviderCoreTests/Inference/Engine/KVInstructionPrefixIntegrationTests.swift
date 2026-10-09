import Foundation
import MLX
import MLXLLM
import Testing

@testable import MLXLMCommon
@testable import ProviderCore

@Suite("Instruction-retention factory and owned row", .serialized)
struct KVInstructionPrefixIntegrationTests {
    @Test func fixedCandidateProtectsHeaderWhileRetainingNativeReservation() throws {
        let data = Data("""
        {"model_type":"gpt_oss", "num_hidden_layers":2,
         "num_local_experts":4,"num_experts_per_tok":2,"vocab_size":128,
         "rms_norm_eps":0.00001,"hidden_size":64,"intermediate_size":64,
         "head_dim":64,"num_attention_heads":4,"num_key_value_heads":2,"sliding_window":32}
        """.utf8)
        let model = GPTOSSModel(try JSONDecoder().decode(GPTOSSConfiguration.self, from: data))
        let configured = try EngineV2Factory.selectiveKVPolicy(model: model,
            purpose: .benchmark, backend: .contiguous,
            environment: [EngineV2Factory.selectiveKVEnvKey: "instruction-half"])
        let policy = try #require(configured)
        #expect(policy.protectedPrefixTokens == 128)
        let kind = CBv2LayerKind(attention: .full, headDim: 1, kvHeads: 1, queryHeads: 1)
        let native = CBv2ContiguousKVBackend(config: .init(bytesCapacity: 1<<20, kvDType: .float32))
        let protected = CBv2ContiguousKVBackend(config: .init(bytesCapacity: 1<<20,
            kvDType: .float32, selectiveRetention: policy))
        let nativeRows = try native.makeSequenceState(layerKinds: [kind], promptLength: 5120, maxLength: 8192)
        let rows = try protected.makeSequenceState(layerKinds: [kind], promptLength: 5120, maxLength: 8192)
        #expect(native.bytesReserved == protected.bytesReserved)
        let row = try #require(rows[0] as? CBv2SelectiveSequenceKV)
        let positions = MLXArray((0..<5120).map(Float.init)).reshaped([1, 1, 5120, 1])
        _ = row.update(keys: positions, values: positions)
        row.prepareForAttention(queries: MLXArray.ones([1, 1, 1, 1]),
            scale: 0.001, sinks: nil, softcap: nil)
        let retained = row.snapshot().keys.asArray(Float.self).map(Int.init)
        #expect(Array(retained.prefix(128)) == Array(0..<128))
        #expect(Array(retained.suffix(512)) == Array(4608..<5120))
        #expect(retained.count < 5120 && retained == retained.sorted())
        #expect(row.absoluteOffset == 5120 && row.statistics.pruningEvents == 1)
        #expect(protected.prefixReuseBackend == .unknown)
        native.release(nativeRows)
        protected.release(rows)
        #expect(protected.bytesReserved == 0)
    }
}
