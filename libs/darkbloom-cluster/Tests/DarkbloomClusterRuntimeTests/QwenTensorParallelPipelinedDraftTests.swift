import DarkbloomClusterProtocol
import Foundation
import MLX
@testable import MLXLLM
import MLXLMCommon
import MLXNN
import Testing
@testable import DarkbloomClusterRuntime

/// The single-row speculative round with its draft chain pipelined into the
/// verify window (`QwenTensorParallelMTPDecoder.pipelinesDrafts`) on actual
/// paired tiny TP shards with a real assistant: it emits the same tokens and
/// runs the same collectives in the same order on both ranks as the round
/// that waits for every draft step; a drafted token outside the vocabulary is
/// refused after the window on both ranks; and one rank failing mid-chain
/// fails both, and both retire. GPU-gated (`QWEN_TP_MTP_GPU=1`).
@Suite(.serialized)
struct QwenTensorParallelPipelinedDraftTests {
    /// Two ranks' all-sums; records each collective's shape in order, and can
    /// be aborted (a lost peer): a waiting rank is released with zeros and
    /// every later check throws.
    private final class Wire: @unchecked Sendable {
        let condition = NSCondition()
        var leaving = 0, step = 0
        var values: [Int: [Float]] = [:], shapes: [Int: [Int]] = [:]
        var output: [Float] = []
        private(set) var log: [[Int]] = []
        private(set) var aborted = false
        func abort() {
            condition.lock(); aborted = true; condition.broadcast(); condition.unlock()
        }
        func sum(_ value: MLXArray, rank: Int) -> MLXArray {
            let bytes = value.asArray(Float.self)
            condition.lock()
            defer { condition.unlock() }
            while leaving > 0 && !aborted { condition.wait() }
            if aborted { return MLXArray.zeros(value.shape, dtype: .float32) }
            let generation = step
            precondition(values[rank] == nil)
            values[rank] = bytes; shapes[rank] = value.shape
            if values.count == 2 {
                precondition(shapes[0] == shapes[1]); output = zip(values[0]!, values[1]!).map(+)
                log.append(value.shape)
                leaving = 2; condition.broadcast()
            } else {
                let deadline = Date().addingTimeInterval(30)
                while leaving == 0 && step == generation && !aborted { precondition(condition.wait(until: deadline)) }
                if aborted { values[rank] = nil; return MLXArray.zeros(value.shape, dtype: .float32) }
            }
            let result = output; leaving -= 1
            if leaving == 0 { values = [:]; shapes = [:]; output = []; step += 1; condition.broadcast() }
            return MLXArray(result, value.shape)
        }
    }
    private final class Rank: QwenTensorParallelReduction, @unchecked Sendable {
        let rank: Int, size = 2, wire: Wire
        init(_ rank: Int, _ wire: Wire) { self.rank = rank; self.wire = wire }
        func allSum(_ value: MLXArray) -> MLXArray { wire.sum(value, rank: rank) }
    }
    private final class Owner: @unchecked Sendable {
        let target: QwenTensorParallelBatchSession
        let decoder: QwenTensorParallelMTPDecoder
        let host: CBv2StageKVHost
        var logits: MLXArray?
        var tokens: [Int] = []
        var failure: Error?
        init(target: QwenTensorParallelBatchSession, decoder: QwenTensorParallelMTPDecoder, host: CBv2StageKVHost) {
            self.target = target; self.decoder = decoder; self.host = host
        }
    }
    private final class Work: @unchecked Sendable {
        let body: (Owner, Int) throws -> Void
        init(_ body: @escaping (Owner, Int) throws -> Void) { self.body = body }
    }
    /// Both ranks at once, each with the pipelining choice; a rank that throws
    /// aborts the wire (as a lost peer would end the link).
    private func paired(_ owners: [Owner], wire: Wire, pipelined: Bool,
                        _ body: @escaping (Owner, Int) throws -> Void) {
        let work = Work(body)
        owners.forEach { $0.failure = nil }
        DispatchQueue.concurrentPerform(iterations: 2) { rank in
            Device.withDefaultDevice(.gpu) {
                QwenTensorParallelMTPDecoder.$pipelinesDraftsOverride.withValue(pipelined) {
                    do { try work.body(owners[rank], rank) } catch {
                        owners[rank].failure = error; wire.abort()
                    }
                }
            }
        }
    }

    private static func fixture() throws -> (configuration: Data, tensors: [(String, MLXArray)],
                                             weights: [String: MLXArray]) {
        let source = QwenTensorParallelFixtures.checkpoint(hidden: 256, layers: 4, heads: 4, kvHeads: 2, vocabulary: 256)
        var root = try JSONSerialization.jsonObject(with: source.configuration) as! [String: Any]
        var text = root["text_config"] as! [String: Any]
        text["max_position_embeddings"] = 256; text["mtp_num_hidden_layers"] = 1
        root["text_config"] = text
        root["mtplx_mtp"] = ["included": true, "prefix": "mtp.", "block_size": 3]
        root["mtplx_mtp_quantization"] = ["group_size": 64, "bits": 4, "mode": "affine"]
        let configuration = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        let config = try JSONDecoder().decode(Qwen35TextConfiguration.self,
            from: JSONSerialization.data(withJSONObject: text))
        MLXRandom.seed(817)
        let donor = Qwen35MTPModule(config)
        donor.update(parameters: ModuleParameters.unflattened(donor.parameters().flattened().map {
            ($0.0, $0.1.asType(.bfloat16))
        }))
        quantize(model: donor, groupSize: 64, bits: 4); eval(donor)
        return (configuration, source.tensors, Dictionary(uniqueKeysWithValues: donor.parameters().flattened()))
    }

    /// A pair of decoders over the same greedy request, prefilled and begun.
    private func pair(_ fixture: (configuration: Data, tensors: [(String, MLXArray)], weights: [String: MLXArray]),
                      wire: Wire, pipelined: Bool) throws -> [Owner] {
        let profile = try QwenLayerStageGenerationProfile(identifier: "qwen27-tp-pipelined-draft",
            vocabularySize: 256, hiddenSize: 256, activationDType: "bfloat16", maximumPromptTokens: 128,
            maximumChunkTokens: 64, maximumOutputTokens: 32, maximumContextTokens: 256)
        let id = UUID()
        let owners = try (0..<2).map { rank -> Owner in
            let group = Rank(rank, wire)
            let model = try QwenTensorParallelModel.assemble(configurationData: fixture.configuration,
                role: .shard(rank: rank, size: 2), reduction: group) { _, keep in
                for (name, value) in fixture.tensors { try keep(name, value) }
            }
            let request = try QwenLayerStageGenerationRequest(profile: profile, requestID: id,
                promptTokenIDs: (0..<37).map { ($0 * 7 + 3) % 256 }, chunkSize: 37, outputCount: 17, stopTokenIDs: [])
            let host = try CBv2StageKVHost(model: model.model, kind: .paged, lanes: 1,
                maximumTokensPerRequest: 256, maximumChunkTokens: 64)
            let target = try QwenTensorParallelBatchSession(model: model, configuration: fixture.configuration,
                host: host, request: request)
            let head = try QwenTensorParallelMTPHead(model: model, configuration: fixture.configuration,
                indexedWeights: fixture.weights, reduction: group)
            return Owner(target: target, decoder: try .init(target: target, head: head, group: group, depth: 3), host: host)
        }
        while owners[0].target.state.committedTokens < 37 {
            paired(owners, wire: wire, pipelined: pipelined) { owner, _ in
                owner.logits = try owner.decoder.prefill(check: {}) ?? owner.logits
            }
            if let failure = owners.compactMap(\.failure).first { throw failure }
        }
        paired(owners, wire: wire, pipelined: pipelined) { owner, rank in
            let model = owner.target.model
            let full = model.gatheredLogits(try #require(owner.logits)); eval(full)
            let (selection, flags) = model.broadcastChoice(rank == 0 ? argMax(full, axis: -1) : nil, stop: 0)
            eval(selection, flags)
            let token = Int(selection.item(Int32.self))
            try owner.decoder.begin(firstToken: token); owner.tokens = [token]
        }
        if let failure = owners.compactMap(\.failure).first { throw failure }
        return owners
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_MTP_GPU"] == "1"))
    func pipelinedDraftsEmitTheSameTokensAndCollectives() throws {
        try Device.withDefaultDevice(.gpu) {
            let fixture = try Self.fixture()
            var runs: [(tokens: [Int], log: [[Int]], rounds: Int)] = []
            for pipelined in [false, true] {
                let wire = Wire()
                let owners = try pair(fixture, wire: wire, pipelined: pipelined)
                while owners[0].tokens.count < 17 {
                    paired(owners, wire: wire, pipelined: pipelined) { owner, _ in
                        let round = try owner.decoder.step(lastToken: owner.tokens.last!,
                            remaining: 17 - owner.tokens.count, check: {})
                        owner.tokens += round.tokens
                    }
                    if let failure = owners.compactMap(\.failure).first { throw failure }
                    #expect(owners[0].tokens == owners[1].tokens)
                }
                #expect(owners.allSatisfy { $0.decoder.statistics.rounds > 0 })
                runs.append((owners[0].tokens, wire.log, owners[0].decoder.statistics.rounds))
                for owner in owners {
                    try owner.decoder.retire()
                    #expect(owner.decoder.retired && owner.host.isDrained)
                }
            }
            #expect(runs[0].tokens == runs[1].tokens, "pipelined drafts changed the emitted tokens")
            #expect(runs[0].log == runs[1].log, "pipelined drafts changed the collectives or their order")
            #expect(runs[0].rounds == runs[1].rounds)
        }
    }

    /// One rank's check fails right after its first draft step is submitted;
    /// the other rank's next check sees the lost peer. Both rounds throw, both
    /// decoders refuse further rounds, and both retire with their pages freed.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_MTP_GPU"] == "1"))
    func oneRankFailingMidChainFailsBothAndRetires() throws {
        try Device.withDefaultDevice(.gpu) {
            let fixture = try Self.fixture()
            let wire = Wire()
            let owners = try pair(fixture, wire: wire, pipelined: true)
            paired(owners, wire: wire, pipelined: true) { owner, rank in
                var checks = 0
                _ = try owner.decoder.step(lastToken: owner.tokens.last!, remaining: 16, check: {
                    checks += 1
                    if rank == 0 && checks == 1 { throw ProbeError("injected rank-0 failure after the first draft step") }
                    if wire.aborted { throw ProbeError("peer lost") }
                })
            }
            #expect(owners.allSatisfy { $0.failure != nil }, "a one-rank failure left the other rank's round standing")
            paired(owners, wire: wire, pipelined: true) { owner, _ in
                _ = try owner.decoder.step(lastToken: owner.tokens.last!, remaining: 16, check: {})
            }
            #expect(owners.allSatisfy { $0.failure != nil }, "a failed decoder took another round")
            for owner in owners {
                try owner.decoder.retire()
                #expect(owner.decoder.retired && owner.host.isDrained)
            }
        }
    }

    /// A window whose token check is deferred (`deferTokenRangeCheck`) adds
    /// the check to its roots, confirms after the evaluation and computes the
    /// same logits, hidden rows and settled history as a checked window.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_MTP_GPU"] == "1"))
    func deferredRangeCheckKeepsTheWindowAndItsHistory() throws {
        try Device.withDefaultDevice(.gpu) {
            let fixture = try Self.fixture()
            var results: [[Data]] = []
            for deferred in [false, true] {
                let wire = Wire()
                let owners = try pair(fixture, wire: wire, pipelined: deferred)
                paired(owners, wire: wire, pipelined: deferred) { owner, _ in
                    let committed = owner.target.state.committedTokens
                    let tokens = MLXArray([Int32(5), 9, 255, 0]).reshaped([1, 4])
                    let built = try QwenTensorParallelTargetWindow.$deferTokenRangeCheck.withValue(deferred) {
                        try owner.target.beginWindow(tokens: tokens, offset: committed)
                    }
                    #expect(built.outputs.count == 2)
                    eval(built.outputs + built.roots)
                    try owner.target.confirmWindow(check: {})
                    eval(try owner.target.settleWindow(keeping: 2))
                    try owner.target.confirmSettled(check: {})
                    #expect(owner.target.state.committedTokens == committed + 2)
                    owner.logits = concatenated([built.outputs[0].reshaped([-1]).asType(.float32),
                                                 built.outputs[1].reshaped([-1]).asType(.float32)])
                }
                if let failure = owners.compactMap(\.failure).first { throw failure }
                results.append(owners.map { owner in
                    let value = owner.logits!; eval(value); return value.asData(access: .copy).data
                })
                for owner in owners { try owner.decoder.retire() }
            }
            #expect(results[0] == results[1], "a deferred token check changed the window")
        }
    }
}
