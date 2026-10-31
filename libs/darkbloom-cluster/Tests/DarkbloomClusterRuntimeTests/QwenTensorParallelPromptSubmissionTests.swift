import Foundation
import MLX
@testable import MLXLLM
import MLXLMCommon
import MLXNN
import Testing
@testable import DarkbloomClusterRuntime

/// A tensor-parallel prompt frame submitted to the GPU every few decoder
/// layers while it is built (`QwenTensorParallelBatchSession.prefillLayerStride`)
/// gives the same bytes as the frame evaluated at once: only when work reaches
/// the GPU changes, never a primitive, an input or a rounding
/// (`QWEN_TP_BATCH_GPU=1`, `QWEN_TP_BATCH_KV=paged`).
@Suite(.serialized)
struct QwenTensorParallelPromptSubmissionTests {
    /// Two ranks in one process: each sums by meeting the other (FP32, rank
    /// order), as the sealed all-sum adds two values.
    final class Rendezvous: @unchecked Sendable {
        let condition = NSCondition()
        var step = 0, leaving = 0
        var inputs: [Int: [Float]] = [:]
        var shapes: [Int: [Int]] = [:]
        var result: [Float] = []
        func sum(_ array: MLXArray, rank: Int) -> MLXArray {
            let values = array.asType(.float32).asArray(Float.self)
            condition.lock()
            while leaving > 0 { condition.wait() }
            let generation = step
            inputs[rank] = values; shapes[rank] = array.shape
            if inputs.count == 2 {
                precondition(shapes[0] == shapes[1], "ranks summed different shapes")
                result = zip(inputs[0]!, inputs[1]!).map(+)
                leaving = 2; condition.broadcast()
            } else {
                let deadline = Date().addingTimeInterval(60)
                while leaving == 0 && step == generation {
                    precondition(condition.wait(until: deadline), "TP rank failed to meet its peer")
                }
            }
            let output = result
            leaving -= 1
            if leaving == 0 { inputs = [:]; shapes = [:]; result = []; step += 1; condition.broadcast() }
            condition.unlock()
            return MLXArray(output, array.shape).asType(array.dtype)
        }
    }
    final class Rank: QwenTensorParallelReduction, @unchecked Sendable {
        let rank: Int, size = 2
        let shared: Rendezvous
        private(set) var collectives = 0
        init(_ rank: Int, _ shared: Rendezvous) { self.rank = rank; self.shared = shared }
        func allSum(_ value: MLXArray) -> MLXArray { collectives += 1; return shared.sum(value, rank: rank) }
    }
    final class Lane: @unchecked Sendable {
        let model: QwenTensorParallelModel
        let reduction: Rank
        let host: CBv2StageKVHost
        var session: QwenTensorParallelBatchSession?
        var output: MLXArray?
        var failure: Error?
        init(_ model: QwenTensorParallelModel, _ reduction: Rank, tokens: Int, chunk: Int) throws {
            self.model = model; self.reduction = reduction
            host = try CBv2StageKVHost(model: model.model, kind: .paged, lanes: 1, maximumTokensPerRequest: tokens,
                maximumChunkTokens: chunk)
        }
    }

    /// A real two-rank prefill (three frames: 512, 512 and 76 rows) gives the
    /// same logits, keys, values and recurrent rows on both ranks, and the same
    /// collectives, with the frame submitted every layer or every four layers
    /// as with the frame evaluated at once (the scheduling before).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_BATCH_GPU"] == "1"
        && ProcessInfo.processInfo.environment["QWEN_TP_BATCH_KV"] == "paged"))
    func promptLayerSubmissionKeepsEveryBit() throws {
        try Device.withDefaultDevice(.gpu) {
            let fixture = QwenTensorParallelFixtures.checkpoint(hidden: 4096, layers: 4, heads: 8, kvHeads: 2,
                vocabulary: 256)
            var root = try JSONSerialization.jsonObject(with: fixture.configuration) as! [String: Any]
            var text = root["text_config"] as! [String: Any]
            text["max_position_embeddings"] = 4096; root["text_config"] = text
            let configuration = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
            let promptCount = 1100, chunk = 512, budget = promptCount + 16
            let profile = try QwenLayerStageGenerationProfile(identifier: "qwen-tp-prompt-submission",
                vocabularySize: 256, hiddenSize: 4096, activationDType: "bfloat16",
                maximumPromptTokens: promptCount, maximumChunkTokens: chunk, maximumOutputTokens: 16,
                maximumContextTokens: budget)
            let request = try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(),
                promptTokenIDs: (0..<promptCount).map { ($0 * 37 + 5) % 256 }, chunkSize: chunk,
                outputCount: 16, stopTokenIDs: [])
            func pair() throws -> [Lane] {
                let wire = Rendezvous()
                return try (0..<2).map { rank in
                    let reduction = Rank(rank, wire)
                    let model = try QwenTensorParallelModel.assemble(configurationData: configuration,
                        role: .shard(rank: rank, size: 2), reduction: reduction) { _, keep in
                        for (name, value) in fixture.tensors { try keep(name, value) }
                    }
                    return try Lane(model, reduction, tokens: budget, chunk: chunk)
                }
            }
            /// The whole prompt on both ranks at once, with `stride` on each rank's thread.
            func prefill(_ lanes: [Lane], stride: Int) throws {
                for lane in lanes {
                    lane.session = try .init(model: lane.model, configuration: configuration, host: lane.host,
                        request: request)
                }
                while lanes[0].session!.schedule.committedPromptTokens < promptCount {
                    DispatchQueue.concurrentPerform(iterations: 2) { rank in
                        Device.withDefaultDevice(.gpu) {
                            do {
                                lanes[rank].output = try QwenTensorParallelBatchSession.$prefillStride.withValue(stride) {
                                    try lanes[rank].session!.prefill(check: {})
                                }
                            } catch { lanes[rank].failure = error }
                        }
                    }
                    for lane in lanes { if let failure = lane.failure { throw failure } }
                }
            }
            func bytes(_ a: MLXArray) -> Data { eval(a); return a.asData(access: .copy).data }
            let before = try pair()
            defer { for lane in before { try? lane.session?.retire() } }
            try prefill(before, stride: 0)
            for stride in [1, 4] {
              let after = try pair()
              defer { for lane in after { try? lane.session?.retire() } }
              try prefill(after, stride: stride)
              // Three frames (512, 512, 76 rows); 2 x 4 layers' sums each, in the same order.
              #expect(before[0].reduction.collectives == after[0].reduction.collectives)
              for rank in 0..<2 {
                let x = before[rank], y = after[rank]
                #expect(bytes(try #require(x.output)) == bytes(try #require(y.output)), "final logits rank \(rank)")
                let a = x.session!, b = y.session!
                for (left, right) in zip(a.state.rows, b.state.rows) {
                    let l = left!.snapshot(), r = right!.snapshot()
                    #expect(l.offset == r.offset && bytes(l.keys) == bytes(r.keys) && bytes(l.values) == bytes(r.values))
                }
                let l = a.state.recurrent.confirmedStateSnapshot() ?? [:], r = b.state.recurrent.confirmedStateSnapshot() ?? [:]
                #expect(l.count == 3 && l.keys.sorted() == r.keys.sorted())
                for layer in l.keys {
                    #expect(bytes(l[layer]!.conv!) == bytes(r[layer]!.conv!))
                    #expect(bytes(l[layer]!.ssm!) == bytes(r[layer]!.ssm!))
                }
              }
            }
        }
    }
}
