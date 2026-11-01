import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import Testing
@testable import DarkbloomClusterRuntime

@Suite("GPT-OSS independent request native decode batches (CPU)", .serialized)
struct GPTOSSBatchForwardTests {
    private typealias F = GPTOSSNativeTestFixture
    private func pages(_ model: GPTOSSModel) -> [GPTOSSPagedKVCache] {
        model.cbv2LayerKinds.map { kind in
            switch kind.attention {
            case .full: GPTOSSPagedKVCache()
            case .slidingWindow(let window): GPTOSSPagedKVCache(window: window)
            }
        }
    }
    private func exact(_ actual: MLXArray, _ expected: MLXArray, _ context: String) {
        eval(actual, expected)
        #expect(actual.shape == expected.shape && actual.dtype == expected.dtype)
        #expect(actual.asData().data == expected.asData().data, "Exact native bytes: \(context)")
    }

    @Test func packedStagesBatchDifferentFrontiersAndPreserveLeavingAndReorderedRequests() throws {
        try Device.withDefaultDevice(.cpu) {
            for dtype in [DType.bfloat16] {
                let whole = try F.model(layers: 0..<4, dtype: dtype)
                let producer = try F.stage(from: whole, layers: 0..<2, first: true, dtype: dtype)
                let consumer = try F.stage(from: whole, layers: 2..<4, first: false, dtype: dtype)
                let head = try #require(consumer.namedModules().first { $0.0 == "lm_head" }?.1 as? Linear)
                let lengths = [3, 9, 17, 63, 65, 127, 129, 261]
                let before = lengths.map { _ in pages(producer) }, after = lengths.map { _ in pages(consumer) }
                let oracle = try lengths.map { _ in try whole.newCache(parameters: nil) }
                for (lane, length) in lengths.enumerated() {
                    // Each request keeps its own prefill chunk grid and ring
                    // layout before it participates in a shared decode frame.
                    var position = 0
                    while position < length {
                        let count = min(lane % 3 == 0 ? 65 : 7, length - position)
                        let input = MLXArray((position..<(position + count)).map { Int32(($0 * 7 + lane) % 64) }).reshaped([1, count])
                        let hidden = producer.model(input, cache: before[lane])
                        let output = head(consumer.model(input, cache: after[lane], inputEmbeddings: hidden))
                        let reference = whole(input, cache: oracle[lane])
                        exact(output, reference, "prefill dtype=\(dtype) lane=\(lane) position=\(position) count=\(count)")
                        position += count
                    }
                }
                // Widths2/4/8 plus reorder, leave and later rejoin. Inactive
                // rows retain exactly their own frontier and native KV bytes.
                for (step, active) in [[0, 1], [3, 1, 7, 0], Array(0..<8), [7, 2, 4], [4], [1, 6, 0, 3]].enumerated() {
                    let tokens = active.map { ($0 * 3 + step * 11) % 64 }
                    let untouched = (0..<8).filter { !active.contains($0) }
                    let preserved = untouched.map { (before[$0] + after[$0]).map { ($0.offset, $0.state.map { $0.asData().data }) } }
                    let residual = try GPTOSSBatchForward.decode(model: producer, head: nil, stageIndex: 0,
                        hiddenSize: 64, vocabularySize: 64, dtype: dtype, tokens: tokens, residual: nil,
                        histories: active.map { before[$0] }, check: {})
                    let output = try GPTOSSBatchForward.decode(model: consumer, head: head, stageIndex: 1,
                        hiddenSize: 64, vocabularySize: 64, dtype: dtype, tokens: tokens, residual: residual,
                        histories: active.map { after[$0] }, check: {})
                    for (row, lane) in active.enumerated() {
                        let input = MLXArray([Int32(tokens[row])]).reshaped([1, 1])
                        exact(output[row..<(row + 1)], whole(input, cache: oracle[lane])[0..., -1, 0...], "decode dtype=\(dtype) step=\(step) width=\(active.count) lane=\(lane)")
                        for (layer, pair) in zip(before[lane] + after[lane], oracle[lane]).enumerated() {
                            let (actual, expected) = pair
                            #expect(actual.offset == expected.offset)
                            for (leaf, pair) in zip(actual.state, expected.state).enumerated() {
                                exact(pair.0, pair.1, "cache dtype=\(dtype) step=\(step) width=\(active.count) lane=\(lane) layer=\(layer) leaf=\(leaf)")
                            }
                        }
                    }
                    for (index, lane) in untouched.enumerated() {
                        for (layer, cache) in (before[lane] + after[lane]).enumerated() {
                            #expect(cache.offset == preserved[index][layer].0)
                            #expect(cache.state.map { $0.asData().data } == preserved[index][layer].1)
                        }
                    }
                }
            }
        }
    }

    @Test func incompatibleHistoryOrResidualRefusesBeforeAnyCacheAdvances() throws {
        try Device.withDefaultDevice(.cpu) {
            let whole = try F.model(layers: 0..<4, dtype: .bfloat16)
            let producer = try F.stage(from: whole, layers: 0..<2, first: true, dtype: .bfloat16)
            let a = pages(producer), b = pages(producer)
            func invoke(_ histories: [[GPTOSSPagedKVCache]], residual: MLXArray? = nil, dtype: DType = .bfloat16) throws {
                _ = try GPTOSSBatchForward.decode(model: producer, head: nil, stageIndex: 0,
                    hiddenSize: 64, vocabularySize: 64, dtype: dtype, tokens: [1, 2],
                    residual: residual, histories: histories, check: {})
            }
            #expect(throws: (any Error).self) { try invoke([a, a]) }
            #expect(throws: (any Error).self) { try invoke([a, b], dtype: .float32) }
            #expect(throws: (any Error).self) { try invoke([a, [GPTOSSPagedKVCache(), GPTOSSPagedKVCache()]]) }
            #expect(throws: (any Error).self) { try invoke([a, b], residual: MLXArray.zeros([2, 1, 64], dtype: .bfloat16)) }
            #expect((a + b).allSatisfy { $0.offset == 0 && $0.allocatedBytes == 0 })
            #expect(throws: (any Error).self) { _ = try GPTOSSBatchAttentionCache([a[0], a[0]]) }
            #expect(throws: (any Error).self) { _ = try GPTOSSBatchAttentionCache([]) }
        }
    }
}
