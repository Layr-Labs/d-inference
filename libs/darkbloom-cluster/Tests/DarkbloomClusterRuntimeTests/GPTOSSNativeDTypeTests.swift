import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import Testing
@testable import DarkbloomClusterRuntime

@Suite("GPT-OSS native residual contract (CPU)", .serialized)
struct GPTOSSNativeDTypeTests {
    @Test func tinyMXFP4StagesPreserveNativeBF16AndFloat32WithoutForwardCasts() throws {
        try Device.withDefaultDevice(.cpu) {
            for dtype in [DType.bfloat16, .float32] {
                let whole = try GPTOSSNativeTestFixture.model(layers: 0..<4, dtype: dtype)
                let weights = Dictionary(uniqueKeysWithValues: whole.parameters().flattened())
                #expect(weights["model.layers.0.mlp.experts.gate_proj.weight"]?.dtype == .uint32)
                #expect(weights["model.layers.0.mlp.experts.gate_proj.scales"]?.dtype == .uint8)
                #expect(weights["model.layers.0.self_attn.q_proj.scales"]?.dtype == dtype)
                for cut in 1..<4 {
                    let producer = try GPTOSSNativeTestFixture.stage(from: whole, layers: 0..<cut, first: true, dtype: dtype)
                    let consumer = try GPTOSSNativeTestFixture.stage(from: whole, layers: cut..<4, first: false, dtype: dtype)
                    let head = try #require(consumer.namedModules().first { $0.0 == "lm_head" }?.1 as? Linear)
                    let referenceCaches = whole.newCache(parameters: nil)
                    let producerCaches = producer.newCache(parameters: nil)
                    let consumerCaches = consumer.newCache(parameters: nil)
                    // Cross the sliding-window boundary and use both prompt
                    // chunks and decode, with real sinks and packed experts.
                    for tokens in [[1, 7, 13, 21, 31, 43, 59], [5], [9], [17, 29], [47]] {
                        let input = MLXArray(tokens.map(Int32.init)).reshaped([1, tokens.count])
                        let reference = whole(input, cache: referenceCaches)
                        let residual = producer.model(input, cache: producerCaches)
                        let hidden = consumer.model(input, cache: consumerCaches, inputEmbeddings: residual)
                        let actual = head(hidden)
                        eval(reference, residual, actual)
                        #expect(residual.dtype == dtype && actual.dtype == dtype)
                        #expect(reference.dtype == dtype && reference.asData().data == actual.asData().data)
                        #expect(reference.asArray(Float.self).allSatisfy { $0.isFinite })
                        for cache in producerCaches + consumerCaches {
                            #expect(cache.state.count == 2 && cache.state.allSatisfy { $0.dtype == dtype })
                        }
                        if dtype == .bfloat16 {
                            #expect(String(describing: residual.dtype) == GPTOSSRegisteredSpecification.residualDType)
                            #expect(residual.nbytes == tokens.count * 64 * GPTOSSRegisteredSpecification.residualElementBytes)
                        }
                    }
                }
            }
        }
    }

    @Test func registeredWireBytesAreNativeWhileMemoryChargesRemainConservative() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let config = try Data(contentsOf: package.deletingLastPathComponent()
            .appendingPathComponent("darkbloom-cluster-worker/Tests/CapabilityChecks/Fixtures/registered-gpt-oss-20b.configuration.json"))
        let family = try GPTOSSPlacementFamily(configuration: config)
        #expect(family.profile.activationDType == "bfloat16" && family.profile.selectedRowDType == "bfloat16")
        #expect(family.boundaryBytesPerToken == 2880 * 2)
        #expect(try family.requestState(layer: 1).bytesPerToken == 2 * 8 * 64 * 4)
        #expect(GPTOSSRequestStateBudget.activationBytes == 4)
    }
}
