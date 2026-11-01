import Foundation
import MLX
import MLXLMCommon
import Testing
@testable import DarkbloomClusterRuntime

/// Opt-in: the registered A3B artifact's real shards on the GPU, both ranks
/// in one process (two threads whose all-sum adds both ranks' float32
/// elements in rank order, each submitting to its own MLX stream). Rows of
/// one request-owned cohort decode together, in a rotating order, and alone:
/// every row's logits are bit-identical on both ranks (alone in one
/// evaluation, together submitted layer by layer as the product decodes), and
/// a cohort's decode issues the same collectives at any width (the mixer's and
/// the packed MoE rows' per layer). `QWEN_TP_MOE_BATCH_MODEL=<registered A3B directory>`
/// [`QWEN_TP_MOE_BATCH_ROWS=4`] [`QWEN_TP_MOE_BATCH_STEPS=6`].
@Suite("Qwen routed-expert TP cohort on the real artifact", .serialized)
struct QwenTensorParallelRoutedCohortRealTests {
    private final class Wire: @unchecked Sendable {
        let condition = NSCondition()
        var leaving = 0, step = 0
        var values: [Int: [Float]] = [:], shapes: [Int: [Int]] = [:]
        var output: [Float] = []
        func sum(_ value: MLXArray, rank: Int) -> MLXArray {
            precondition(value.dtype == .float32)
            let bytes = value.asArray(Float.self)
            condition.lock()
            while leaving > 0 { condition.wait() }
            let generation = step
            precondition(values[rank] == nil)
            values[rank] = bytes; shapes[rank] = value.shape
            if values.count == 2 {
                precondition(shapes[0] == shapes[1])
                output = zip(values[0]!, values[1]!).map(+)
                leaving = 2; condition.broadcast()
            } else {
                let deadline = Date().addingTimeInterval(300)
                while leaving == 0 && step == generation { precondition(condition.wait(until: deadline)) }
            }
            let result = output; leaving -= 1
            if leaving == 0 { values = [:]; shapes = [:]; output = []; step += 1; condition.broadcast() }
            condition.unlock()
            return MLXArray(result, value.shape)
        }
    }

    private final class Rank: QwenTensorParallelReduction, @unchecked Sendable {
        let rank: Int, size = 2, wire: Wire
        init(_ rank: Int, _ wire: Wire) { self.rank = rank; self.wire = wire }
        func allSum(_ value: MLXArray) -> MLXArray {
            // Integer agreements cross as float32, as the sealed product group sends them.
            value.dtype == .float32 ? wire.sum(value, rank: rank) : wire.sum(value.asType(.float32), rank: rank).asType(value.dtype)
        }
    }

    private final class Owner: @unchecked Sendable {
        let model: QwenTensorParallelModel
        let host: CBv2StageKVHost
        var alone: [QwenTensorParallelBatchSession] = [], together: [QwenTensorParallelBatchSession] = []
        var rows: [Data] = []
        var failure: Error?
        init(_ model: QwenTensorParallelModel, _ host: CBv2StageKVHost) { self.model = model; self.host = host }
    }

    private final class Work: @unchecked Sendable {
        let body: (Owner) throws -> Void
        init(_ body: @escaping (Owner) throws -> Void) { self.body = body }
    }

    private func paired(_ owners: [Owner], _ body: @escaping (Owner) throws -> Void) throws {
        let work = Work(body)
        DispatchQueue.concurrentPerform(iterations: 2) { rank in
            // MLX's default stream is one process-wide, thread-unsafe stream:
            // each rank's thread submits to its own, as each rank's process does.
            Device.withDefaultDevice(.gpu) {
                Stream.withNewDefaultStream(device: .gpu) {
                    do { try work.body(owners[rank]) } catch { owners[rank].failure = error }
                }
            }
        }
        for owner in owners { if let failure = owner.failure { throw failure } }
    }

    private static func bytes(_ value: MLXArray) -> Data {
        eval(value); return value.asType(.float32).asData(access: .copy).data
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_MOE_BATCH_MODEL"] != nil))
    func cohortRowsEqualTheirSoloRowsOnTheRealArtifact() throws {
        let environment = ProcessInfo.processInfo.environment
        let directory = URL(fileURLWithPath: try #require(environment["QWEN_TP_MOE_BATCH_MODEL"]), isDirectory: true)
        let width = Int(environment["QWEN_TP_MOE_BATCH_ROWS"] ?? "") ?? 4
        let steps = Int(environment["QWEN_TP_MOE_BATCH_STEPS"] ?? "") ?? 6
        let configuration = try Data(contentsOf: directory.appendingPathComponent("config.json"))
        let wire = Wire()
        let owners = try (0..<2).map { rank -> Owner in
            try Device.withDefaultDevice(.gpu) {
                let model = try QwenTensorParallelModel.load(modelDirectory: directory, role: .shard(rank: rank, size: 2),
                    reduction: Rank(rank, wire))
                return Owner(model, try CBv2StageKVHost(model: model.model, kind: .paged, lanes: 2 * width,
                    maximumTokensPerRequest: 512, maximumChunkTokens: 128))
            }
        }
        let plan = owners[0].model.plan
        #expect(plan.routedExperts && plan.reductionsPerForward == 2 * plan.layerCount)
        let profile = try QwenLayerStageGenerationProfile(identifier: "qwen-tp-moe-cohort-real",
            vocabularySize: plan.vocabularySize, hiddenSize: plan.hiddenSize, activationDType: "bfloat16",
            maximumPromptTokens: 256, maximumChunkTokens: 128, maximumOutputTokens: 64, maximumContextTokens: 512)
        defer { for owner in owners { for session in owner.alone + owner.together { try? session.retire() } } }
        for row in 0..<width {
            let request = try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(),
                promptTokenIDs: (0..<(150 + 17 * row)).map { ($0 * 7919 + 13 * row + 11) % 150_000 },
                chunkSize: 128, outputCount: steps + 8, stopTokenIDs: [])
            try paired(owners) { owner in
                for _ in 0..<2 {
                    let session = try QwenTensorParallelBatchSession(model: owner.model, configuration: configuration,
                        host: owner.host, request: request)
                    while session.schedule.committedPromptTokens < request.promptCount { _ = try session.prefill(check: {}) }
                    if owner.alone.count == row { owner.alone.append(session) } else { owner.together.append(session) }
                }
            }
        }
        for step in 0..<steps {
            let tokens = (0..<width).map { ($0 * 31 + step * 7 + 5) % 150_000 }
            var expected: [[Data]] = [[], []]
            for row in 0..<width {
                try paired(owners) { owner in
                    // Alone and in one evaluation; the cohort is submitted layer by layer.
                    try QwenTensorParallelBatchSession.$layerStride.withValue(0) {
                        owner.rows = [Self.bytes(try QwenTensorParallelBatchSession.decode([owner.alone[row]],
                            tokens: [tokens[row]], check: {}))]
                    }
                }
                for rank in 0..<2 { expected[rank].append(owners[rank].rows[0]) }
            }
            let order = (0..<width).map { (step + (step % 2 == 0 ? $0 : width - 1 - $0)) % width }
            let before = wire.step
            try paired(owners) { owner in
                let logits = try QwenTensorParallelBatchSession.decode(order.map { owner.together[$0] },
                    tokens: order.map { tokens[$0] }, check: {})
                owner.rows = order.indices.map { Self.bytes(logits[$0 ..< $0 + 1]) }
            }
            #expect(wire.step - before == plan.reductionsPerForward, "a cohort's collectives do not grow with its width")
            for rank in 0..<2 {
                for (slot, row) in order.enumerated() {
                    #expect(owners[rank].rows[slot] == expected[rank][row], "rank=\(rank) step=\(step) row=\(row)")
                }
            }
        }
        print("qwen-tp-moe-cohort-real \(directory.lastPathComponent) rows=\(width) steps=\(steps) collectives=\(wire.step)")
    }
}
