import Cmlx
import DarkbloomClusterProtocol
import Foundation
import MLX
@testable import MLXLLM
import MLXLMCommon
import MLXNN
import Testing
@testable import DarkbloomClusterRuntime

@Suite(.serialized)
struct QwenTensorParallelMTPSessionTests {
    private var gpu: Bool { ProcessInfo.processInfo.environment["QWEN_TP_MTP_GPU"] == "1" }
    private final class Rendezvous: @unchecked Sendable {
        let condition = NSCondition()
        var leaving = 0, step = 0
        var values: [Int: [Float]] = [:], shapes: [Int: [Int]] = [:]
        var output: [Float] = []
        func sum(_ value: MLXArray, rank: Int) -> MLXArray {
            let bytes = value.asArray(Float.self)
            condition.lock()
            while leaving > 0 { condition.wait() }
            let generation = step
            precondition(values[rank] == nil)
            values[rank] = bytes; shapes[rank] = value.shape
            if values.count == 2 {
                precondition(shapes[0] == shapes[1]); output = zip(values[0]!, values[1]!).map(+)
                leaving = 2; condition.broadcast()
            } else {
                let deadline = Date().addingTimeInterval(30)
                while leaving == 0 && step == generation { precondition(condition.wait(until: deadline)) }
            }
            let result = output; leaving -= 1
            if leaving == 0 { values = [:]; shapes = [:]; output = []; step += 1; condition.broadcast() }
            condition.unlock()
            return MLXArray(result, value.shape)
        }
    }
    private final class Rank: QwenTensorParallelReduction, @unchecked Sendable {
        let rank: Int, size = 2, wire: Rendezvous
        init(_ rank: Int, _ wire: Rendezvous) { self.rank = rank; self.wire = wire }
        func allSum(_ value: MLXArray) -> MLXArray { wire.sum(value, rank: rank) }
    }
    private final class Owner: @unchecked Sendable {
        let session: QwenTensorParallelMTPSession
        let host: CBv2StageKVHost
        var windowRows: [(Data, Data)] = []
        var failure: Error?
        init(_ session: QwenTensorParallelMTPSession, _ host: CBv2StageKVHost) { self.session = session; self.host = host }
    }
    private final class Work: @unchecked Sendable {
        let body: (Owner) throws -> Void
        init(_ body: @escaping (Owner) throws -> Void) { self.body = body }
    }
    private func parallel(_ owners: [Owner], body: @escaping (Owner) throws -> Void) throws {
        let work = Work(body), device = gpu ? Device.gpu : Device.cpu
        DispatchQueue.concurrentPerform(iterations: 2) { rank in
            Device.withDefaultDevice(device) {
                do { try work.body(owners[rank]) } catch { owners[rank].failure = error }
            }
        }
        for owner in owners { if let error = owner.failure { throw error } }
    }

    private final class ProjectionOwner: @unchecked Sendable {
        let projection: QwenTensorParallelMTPProjection
        let input: MLXArray
        var output: MLXArray?
        init(_ projection: QwenTensorParallelMTPProjection, _ input: MLXArray) {
            self.projection = projection; self.input = input
        }
    }

    /// The proposal head drafts greedily: both ranks project rank 0's hidden
    /// row through their own vocabulary interval, and one small exchange
    /// chooses the complete row's first maximum. The scores keep that maximum
    /// at its global index and -inf elsewhere; an equal maximum in both
    /// intervals goes to the lower index, as the complete row's argmax does.
    @Test func proposalHeadUsesRankZeroHiddenAndChoosesTheCompleteRowsFirstMaximum() throws {
        try Device.withDefaultDevice(.cpu) {
            let elements: [Float] = (0..<8192).map { index in
                let value = (index * 13) % 29 - 14
                return Float(value) / Float(19)
            }
            for tied in [false, true] {
                let distinct = MLXArray(elements).reshaped([128, 64]).asType(.bfloat16)
                // Tied: the upper interval repeats the lower one row for row.
                let weights = tied ? concatenated([distinct[0..<64], distinct[0..<64]], axis: 0) : distinct
                let full = QuantizedLinear(weight: weights, bias: nil, groupSize: 64, bits: 4)
                eval(full)
                for dtype in [DType.bfloat16, .float16, .float32] {
                    let wire = Rendezvous()
                    let row: [Float] = (0..<64).map { index in Float(index % 7 - 3) / Float(11) }
                    let authoritative = MLXArray(row).reshaped([1, 1, 64]).asType(dtype)
                    let owners = try (0..<2).map { rank -> ProjectionOwner in
                        let rows = (rank * 64)..<((rank + 1) * 64)
                        let local = QuantizedLinear(weight: weights[rows], bias: nil, groupSize: 64, bits: 4)
                        eval(local)
                        let projection = try QwenTensorParallelMTPProjection(local: local,
                            vocabulary: rows, vocabularySize: 128, reduction: Rank(rank, wire))
                        return ProjectionOwner(projection, rank == 0 ? authoritative : -authoritative + 2)
                    }
                    DispatchQueue.concurrentPerform(iterations: 2) { rank in
                        Device.withDefaultDevice(.cpu) {
                            let output = owners[rank].projection(owners[rank].input)
                            eval(output); owners[rank].output = output
                        }
                    }
                    let expected = full(authoritative); eval(expected)
                    let complete = expected[0, 0].asType(.float32).asArray(Float.self)
                    let winner = complete.indices.first { complete[$0] == complete.max()! }!
                    #expect(wire.step == 2)
                    if tied { #expect(winner < 64 && complete[winner + 64] == complete[winner]) }
                    for owner in owners {
                        let output = try #require(owner.output)
                        #expect(output.shape == expected.shape && output.dtype == expected.dtype)
                        let scores = output[0, 0].asType(.float32).asArray(Float.self)
                        #expect(argMax(output[0, 0], axis: -1).asType(.int32).item(Int32.self) == Int32(winner))
                        #expect(scores[winner] == complete[winner])
                        #expect(scores.indices.allSatisfy { $0 == winner || scores[$0] == -Float.infinity })
                        #expect(owner.projection.local.weight.dim(0) == 64)
                    }
                }
            }
        }
    }

    private final class DecoderOwner: @unchecked Sendable {
        let target: QwenTensorParallelMTPSession
        let decoder: QwenTensorParallelMTPDecoder
        let host: CBv2StageKVHost
        var logits: MLXArray?
        var tokens: [Int] = []
        var captureCount = 0
        var failure: Error?
        init(target: QwenTensorParallelMTPSession, decoder: QwenTensorParallelMTPDecoder, host: CBv2StageKVHost) {
            self.target = target; self.decoder = decoder; self.host = host
        }
    }
    private final class DecoderWork: @unchecked Sendable {
        let body: (DecoderOwner, Int) throws -> Void
        init(_ body: @escaping (DecoderOwner, Int) throws -> Void) { self.body = body }
    }
    private func parallelDecoders(_ owners: [DecoderOwner], device: Device = .gpu, body: @escaping (DecoderOwner, Int) throws -> Void) throws {
        let work = DecoderWork(body)
        DispatchQueue.concurrentPerform(iterations: 2) { rank in
            Device.withDefaultDevice(device) {
                do { try work.body(owners[rank], rank) } catch { owners[rank].failure = error }
            }
        }
        for owner in owners { if let error = owner.failure { throw error } }
    }

    private struct CombinedCase {
        let depth: Int
        let sampling: ClusterWorkerSampling?
        let history: Bool
        let capture: Bool
        let failAfterDraft: Bool
    }

    private var combinedCases: [CombinedCase] {
        func sampled(history: Bool = false, capture: Bool = false) -> ClusterWorkerSampling {
            .init(temperature: 0.7, topP: 0.9, topK: 32, minP: 0.01,
                repetitionPenalty: history ? 1.1 : 1, repetitionContextSize: 32,
                frequencyPenalty: 0, presencePenalty: 0, seed: 918, stream: 0,
                logitBias: [], topLogprobs: capture ? 2 : 0)
        }
        // Production greedy reservations omit sampling entirely. Captured
        // logprobs and history transforms are separate ordinary-step cases.
        return [
            .init(depth: 1, sampling: nil, history: false, capture: false, failAfterDraft: false),
            .init(depth: 4, sampling: sampled(), history: false, capture: false, failAfterDraft: false),
            .init(depth: 4, sampling: sampled(history: true), history: true, capture: false, failAfterDraft: false),
            .init(depth: 4, sampling: sampled(capture: true), history: false, capture: true, failAfterDraft: false),
            .init(depth: 4, sampling: nil, history: false, capture: false, failAfterDraft: true),
        ]
    }

    private func combinedRequest(_ item: CombinedCase, id: UUID) throws -> QwenLayerStageGenerationRequest {
        let profile = try QwenLayerStageGenerationProfile(identifier: "qwen27-tp-mtp-combined", vocabularySize: 256,
            hiddenSize: 256, activationDType: "bfloat16", maximumPromptTokens: 128, maximumChunkTokens: 64,
            maximumOutputTokens: 32, maximumContextTokens: 256)
        return try .init(profile: profile, requestID: id,
            promptTokenIDs: (0..<67).map { ($0 * 7 + 3) % 256 }, chunkSize: 31,
            outputCount: 11, stopTokenIDs: [], sampling: item.sampling)
    }

    @Test func combinedFixtureRequestsMatchProductionSamplingAndRoundEligibility() throws {
        #expect(combinedCases.count == 5)
        for item in combinedCases {
            let id = UUID(), first = try combinedRequest(item, id: id), second = try combinedRequest(item, id: id)
            #expect(first.fingerprint == second.fingerprint)
            #expect(first.promptCount == 67 && first.chunkSize == 31 && first.outputCount == 11)
            #expect(first.maximumTokens == 78 && first.qwenMedia == nil && first.stopTokenIDs.isEmpty)
            #expect((1...4).contains(item.depth) && first.outputCount - 1 >= item.depth)
            #expect((first.sampling?.wire.admitsSpeculativeVerification ?? true) == (!item.history && !item.capture))
            #expect((first.sampling?.wire.dependsOnHistory ?? false) == item.history)
            #expect((first.sampling?.wire.topLogprobs ?? 0) == (item.capture ? 2 : 0))
            if let sampling = item.sampling {
                #expect(!sampling.isGreedyNoOp && sampling.isStochastic)
                #expect(sampling.topK <= first.profile.vocabularySize)
            } else {
                #expect(first.sampling == nil && !item.history && !item.capture)
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_MTP_GPU"] == "1"))
    func realAssistantAndTargetRoundsSettleBeforePublicationAndRetireAfterFault() throws {
        try Device.withDefaultDevice(.gpu) {
            let source = QwenTensorParallelFixtures.checkpoint(hidden: 256, layers: 4, heads: 4,
                kvHeads: 2, vocabulary: 256)
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
            let weights = Dictionary(uniqueKeysWithValues: donor.parameters().flattened())
            for item in combinedCases {
                let depth = item.depth, history = item.history, capture = item.capture
                let failAfterDraft = item.failAfterDraft
                let wire = Rendezvous(), id = UUID()
                let owners = try (0..<2).map { rank -> DecoderOwner in
                    let group = Rank(rank, wire)
                    let model = try QwenTensorParallelModel.assemble(configurationData: configuration,
                        role: .shard(rank: rank, size: 2), reduction: group) { _, keep in
                        for (name, value) in source.tensors { try keep(name, value) }
                    }
                    // Construct separate request samplers, just as each native
                    // process does, while binding the same wire identity.
                    let request = try combinedRequest(item, id: id)
                    let host = try CBv2StageKVHost(model: model.model, kind: .paged, lanes: 1,
                        maximumTokensPerRequest: 256, maximumChunkTokens: 64)
                    let target = try QwenTensorParallelMTPSession(model: model, configuration: configuration,
                        host: host, request: request)
                    let head = try QwenTensorParallelMTPHead(model: model, configuration: configuration,
                        indexedWeights: weights, reduction: group)
                    return try DecoderOwner(target: target,
                        decoder: .init(target: target, head: head, group: group, depth: depth), host: host)
                }
                defer { for owner in owners { try? owner.decoder.retire() } }
                while owners[0].target.state.committedTokens < 67 {
                    try parallelDecoders(owners) { owner, _ in
                        owner.logits = try owner.decoder.prefill(check: {}) ?? owner.logits
                    }
                }
                try parallelDecoders(owners) { owner, rank in
                    let model = owner.target.model, request = owner.target.request
                    let full = model.gatheredLogits(try #require(owner.logits)); eval(full)
                    let sampled = rank == 0 ? (request.sampler?.sample(full) ?? argMax(full, axis: -1)) : nil
                    let (selection, flags) = model.broadcastChoice(sampled, stop: 0); eval(selection, flags)
                    let token = Int(selection.item(Int32.self))
                    if rank == 0 {
                        request.sampler?.commit(token)
                        let firstCapture = request.sampler?.takePendingLogprobs()
                        if capture {
                            let record = try #require(firstCapture)
                            #expect(record.logprob.isFinite && record.top.count == 2)
                            owner.captureCount += 1
                        } else { #expect(firstCapture == nil) }
                    }
                    try owner.decoder.begin(firstToken: token); owner.tokens = [token]; owner.logits = nil
                }
                #expect(owners[0].tokens == owners[1].tokens)
                if failAfterDraft {
                    let beforeDraft = wire.step
                    #expect(owners.allSatisfy { $0.target.request.sampler?.admitsSpeculativeVerification ?? true })
                    try parallelDecoders(owners) { owner, _ in
                        var checkedDraft = false
                        #expect(throws: ProbeError.self) {
                            try owner.decoder.step(lastToken: owner.tokens.last!, remaining: 10, check: {
                                checkedDraft = true; throw ProbeError("injected completed-draft failure")
                            })
                        }
                        #expect(checkedDraft)
                        #expect(throws: ProbeError.self) {
                            try owner.decoder.step(lastToken: owner.tokens.last!, remaining: 10, check: {})
                        }
                    }
                    // The failure hook runs immediately after the first draft
                    // evaluation: authoritative hidden plus sharded-head gather,
                    // before draft-ID exchange or any target verification.
                    #expect(wire.step == beforeDraft + 2)
                } else {
                    while owners[0].tokens.count < 11 {
                        try parallelDecoders(owners) { owner, rank in
                            let request = owner.target.request
                            let round = try owner.decoder.step(lastToken: owner.tokens.last!,
                                remaining: 11 - owner.tokens.count, check: {})
                            // These are inspected before the caller publishes
                            // any returned token, not after a subsequent step.
                            #expect(owner.target.state.committedTokens == 67 + owner.tokens.count + round.tokens.count - 1)
                            #expect(owner.target.schedule.committedTokens == owner.target.state.committedTokens)
                            #expect(round.speculative == (!history && !capture && 11 - owner.tokens.count >= depth))
                            if rank == 0 && capture {
                                #expect(round.logprobs.count == round.tokens.count)
                                #expect(round.logprobs.allSatisfy { $0.logprob.isFinite && $0.top.count == 2 })
                                owner.captureCount += round.logprobs.count
                            } else { #expect(round.logprobs.isEmpty) }
                            owner.tokens += round.tokens
                            #expect((request.sampler?.nextOutputIndex ?? 0) == (rank == 0 && request.sampler != nil ? owner.tokens.count : 0))
                        }
                        #expect(owners[0].tokens == owners[1].tokens)
                    }
                    #expect(owners[0].captureCount == (capture ? 11 : 0) && owners[1].captureCount == 0)
                    #expect(owners.allSatisfy { (history || capture) ? $0.decoder.statistics.rounds == 0 : $0.decoder.statistics.rounds > 0 })
                }
                for owner in owners {
                    try owner.decoder.retire()
                    #expect(owner.decoder.retired && owner.target.retired && owner.target.state.isClosed)
                    #expect(owner.host.isDrained && owner.host.backend.bytesReserved == 0)
                }
            }
        }
    }

    /// Bounded assistant flushes change only draft accumulation geometry. A
    /// 67-token prompt with 8-row blocks exercises the blocked first draft and
    /// the ordinary-step flush on both ranks; committed tokens stay the target's.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_MTP_GPU"] == "1"))
    func boundedHistoryFlushKeepsTargetVerifiedOutputs() throws {
        try Device.withDefaultDevice(.gpu) {
            let source = QwenTensorParallelFixtures.checkpoint(hidden: 256, layers: 4, heads: 4,
                kvHeads: 2, vocabulary: 256)
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
            let weights = Dictionary(uniqueKeysWithValues: donor.parameters().flattened())
            func generate(_ item: CombinedCase, flushRows: Int?) throws -> (tokens: [Int], rounds: Int) {
                let wire = Rendezvous(), id = UUID()
                let owners = try (0..<2).map { rank -> DecoderOwner in
                    let group = Rank(rank, wire)
                    let model = try QwenTensorParallelModel.assemble(configurationData: configuration,
                        role: .shard(rank: rank, size: 2), reduction: group) { _, keep in
                        for (name, value) in source.tensors { try keep(name, value) }
                    }
                    let request = try combinedRequest(item, id: id)
                    let host = try CBv2StageKVHost(model: model.model, kind: .paged, lanes: 1,
                        maximumTokensPerRequest: 256, maximumChunkTokens: 64)
                    let target = try QwenTensorParallelMTPSession(model: model, configuration: configuration,
                        host: host, request: request)
                    let head = try QwenTensorParallelMTPHead(model: model, configuration: configuration,
                        indexedWeights: weights, reduction: group)
                    #expect(head.assistant.historyFlushRows == QwenTensorParallelMTPPolicy.historyFlushRows)
                    head.assistant.historyFlushRows = flushRows
                    return try DecoderOwner(target: target,
                        decoder: .init(target: target, head: head, group: group, depth: item.depth), host: host)
                }
                defer { for owner in owners { try? owner.decoder.retire() } }
                while owners[0].target.state.committedTokens < 67 {
                    try parallelDecoders(owners) { owner, _ in
                        owner.logits = try owner.decoder.prefill(check: {}) ?? owner.logits
                    }
                }
                try parallelDecoders(owners) { owner, rank in
                    let model = owner.target.model, request = owner.target.request
                    let full = model.gatheredLogits(try #require(owner.logits)); eval(full)
                    let sampled = rank == 0 ? (request.sampler?.sample(full) ?? argMax(full, axis: -1)) : nil
                    let (selection, flags) = model.broadcastChoice(sampled, stop: 0); eval(selection, flags)
                    let token = Int(selection.item(Int32.self))
                    if rank == 0 { request.sampler?.commit(token) }
                    try owner.decoder.begin(firstToken: token); owner.tokens = [token]; owner.logits = nil
                }
                while owners[0].tokens.count < 11 {
                    try parallelDecoders(owners) { owner, _ in
                        let round = try owner.decoder.step(lastToken: owner.tokens.last!,
                            remaining: 11 - owner.tokens.count, check: {})
                        owner.tokens += round.tokens
                    }
                    #expect(owners[0].tokens == owners[1].tokens)
                }
                for owner in owners {
                    try owner.decoder.retire()
                    #expect(owner.host.isDrained && owner.host.backend.bytesReserved == 0)
                }
                return (owners[0].tokens, owners[0].decoder.statistics.rounds)
            }
            // Greedy speculation, then an ordinary-only history sampler whose
            // every step observes one trusted row and flushes at the bound.
            for item in [CombinedCase(depth: 2, sampling: nil, history: false, capture: false, failAfterDraft: false),
                         combinedCases[2]] {
                let whole = try generate(item, flushRows: nil), bounded = try generate(item, flushRows: 8)
                #expect(whole.tokens == bounded.tokens && whole.tokens.count == 11)
                #expect(item.history ? bounded.rounds == 0 : bounded.rounds > 0)
            }
        }
    }

    /// Leading complete history blocks move into head K/V while the prompt is
    /// observed: the same blocks, in the same order and shapes, as the first
    /// round's draft would flush, so every proposal, round and token is the
    /// whole-prompt flush's, while the queued trusted rows stay within one
    /// flush block instead of growing with the prompt (67 tokens in frames of
    /// 31, 8-row blocks, greedy and sampled speculation).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_MTP_GPU"] == "1"))
    func promptHistoryFlushesKeepDraftsAndBoundTheBacklog() throws {
        try Device.withDefaultDevice(.gpu) {
            let source = QwenTensorParallelFixtures.checkpoint(hidden: 256, layers: 4, heads: 4,
                kvHeads: 2, vocabulary: 256)
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
            let weights = Dictionary(uniqueKeysWithValues: donor.parameters().flattened())
            struct Run: Equatable { let tokens: [Int]; let rounds: Int; let emitted: Int; let examined: [Int]; let accepted: [Int] }
            func generate(_ item: CombinedCase, early: Bool) throws -> (run: Run, backlog: Int) {
                let wire = Rendezvous(), id = UUID()
                let owners = try (0..<2).map { rank -> DecoderOwner in
                    let group = Rank(rank, wire)
                    let model = try QwenTensorParallelModel.assemble(configurationData: configuration,
                        role: .shard(rank: rank, size: 2), reduction: group) { _, keep in
                        for (name, value) in source.tensors { try keep(name, value) }
                    }
                    let request = try combinedRequest(item, id: id)
                    let host = try CBv2StageKVHost(model: model.model, kind: .paged, lanes: 1,
                        maximumTokensPerRequest: 256, maximumChunkTokens: 64)
                    let target = try QwenTensorParallelMTPSession(model: model, configuration: configuration,
                        host: host, request: request)
                    let head = try QwenTensorParallelMTPHead(model: model, configuration: configuration,
                        indexedWeights: weights, reduction: group)
                    head.assistant.historyFlushRows = 8
                    return try DecoderOwner(target: target, decoder: .init(target: target, head: head, group: group,
                        depth: item.depth, flushesHistoryDuringPrompt: early), host: host)
                }
                defer { for owner in owners { try? owner.decoder.retire() } }
                var backlog = 0
                while owners[0].target.state.committedTokens < 67 {
                    try parallelDecoders(owners) { owner, _ in
                        owner.logits = try owner.decoder.prefill(check: {}) ?? owner.logits
                    }
                    backlog = max(backlog, owners[0].decoder.trustedBacklogRows)
                    #expect(owners[0].decoder.trustedBacklogRows == owners[1].decoder.trustedBacklogRows)
                }
                try parallelDecoders(owners) { owner, rank in
                    let model = owner.target.model, request = owner.target.request
                    let full = model.gatheredLogits(try #require(owner.logits)); eval(full)
                    let sampled = rank == 0 ? (request.sampler?.sample(full) ?? argMax(full, axis: -1)) : nil
                    let (selection, flags) = model.broadcastChoice(sampled, stop: 0); eval(selection, flags)
                    let token = Int(selection.item(Int32.self))
                    if rank == 0 { request.sampler?.commit(token) }
                    try owner.decoder.begin(firstToken: token); owner.tokens = [token]; owner.logits = nil
                }
                while owners[0].tokens.count < 11 {
                    try parallelDecoders(owners) { owner, _ in
                        let round = try owner.decoder.step(lastToken: owner.tokens.last!,
                            remaining: 11 - owner.tokens.count, check: {})
                        owner.tokens += round.tokens
                    }
                    #expect(owners[0].tokens == owners[1].tokens)
                }
                let statistics = owners[0].decoder.statistics
                for owner in owners {
                    try owner.decoder.retire()
                    #expect(owner.host.isDrained && owner.host.backend.bytesReserved == 0)
                }
                return (Run(tokens: owners[0].tokens, rounds: statistics.rounds, emitted: statistics.emittedTokens,
                    examined: statistics.examinedByPosition, accepted: statistics.acceptedByPosition), backlog)
            }
            for item in [CombinedCase(depth: 2, sampling: nil, history: false, capture: false, failAfterDraft: false),
                         combinedCases[1]] {
                let whole = try generate(item, early: false), early = try generate(item, early: true)
                print("darkbloom-prompt-history-flush-test depth=\(item.depth) whole_backlog=\(whole.backlog)"
                    + " early_backlog=\(early.backlog) rounds=\(early.run.rounds) accepted=\(early.run.accepted)")
                #expect(early.run == whole.run && early.run.tokens.count == 11 && early.run.rounds > 0)
                #expect(whole.backlog >= 60 && early.backlog <= 8)
            }
        }
    }

    /// The MTP ledger prices a verify window's speculation, not a second
    /// history: columns are written into the row's own pages, rollback moves
    /// the frontier, and attention gathers one layer at a time. Over an 8K
    /// paged history, a window's transient allocation stays within the target
    /// ledger's full-history gather bank plus captured state and outputs.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_MTP_GPU"] == "1"))
    func capturedWindowsAllocateNoSecondHistory() throws {
        try Device.withDefaultDevice(.gpu) {
            let source = QwenTensorParallelFixtures.checkpoint(hidden: 256, layers: 8, heads: 4, kvHeads: 2, vocabulary: 256)
            var root = try JSONSerialization.jsonObject(with: source.configuration) as! [String: Any]
            var text = root["text_config"] as! [String: Any]
            text["max_position_embeddings"] = 16384
            root["text_config"] = text
            let configuration = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
            let prompt = 8197, context = 8256
            let profile = try QwenLayerStageGenerationProfile(identifier: "qwen27-tp-window-memory", vocabularySize: 256,
                hiddenSize: 256, activationDType: "bfloat16", maximumPromptTokens: prompt,
                maximumChunkTokens: 512, maximumOutputTokens: context - prompt, maximumContextTokens: context)
            let request = try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(),
                promptTokenIDs: (0..<prompt).map { ($0 * 7 + 3) % 256 }, chunkSize: 512, outputCount: 16, stopTokenIDs: [])
            let wire = Rendezvous()
            let owners = try (0..<2).map { rank -> Owner in
                let model = try QwenTensorParallelModel.assemble(configurationData: configuration,
                    role: .shard(rank: rank, size: 2), reduction: Rank(rank, wire)) { _, keep in
                    for (name, value) in source.tensors { try keep(name, value) }
                }
                let host = try CBv2StageKVHost(model: model.model, kind: .paged, lanes: 1,
                    maximumTokensPerRequest: context, maximumChunkTokens: 512)
                return try Owner(.init(model: model, configuration: configuration, host: host, request: request,
                                       permitContiguousDiagnostic: false), host)
            }
            defer { for owner in owners { try? owner.session.retire() } }
            while owners[0].session.schedule.committedPromptTokens < prompt {
                try parallel(owners) { owner in _ = try owner.session.prefill(check: {}) }
            }
            func transient(columns: Int) throws -> Int {
                let offset = owners[0].session.state.committedTokens
                Stream.gpu.synchronize(); Memory.clearCache()
                let before = Memory.activeMemory
                Memory.peakMemory = 0
                try parallel(owners) { owner in
                    let tokens = MLXArray((0..<columns).map { Int32((offset + $0) % 256) }).reshaped([1, columns])
                    let window = try owner.session.beginWindow(tokens: tokens, offset: offset)
                    eval(window.outputs + window.roots)
                    try owner.session.confirmWindow(check: {})
                    let roots = try owner.session.settleWindow(keeping: 1)
                    eval(roots); try owner.session.confirmSettled(check: {})
                }
                Stream.gpu.synchronize()
                return max(0, Memory.peakMemory - before)
            }
            let one = try transient(columns: 1), four = try transient(columns: 4)
            // Per rank: one KV head of 256 per attention layer, two attention
            // layers (interval 4), K and V in BF16 for the whole history.
            let gatherBank = 2 * context * 256 * 2 * 2
            // The removed supplement: a full-head page bank and four
            // full-history gathers per attention layer.
            let removed = 2 * ((context + 63) / 64) * 2 * (64 * 2 * 256 * 2) + 4 * 2 * (context * 2 * 256 * 2)
            print("darkbloom-window-memory-v1 one=\(one) four=\(four) gather_bank=\(gatherBank) removed_supplement=\(removed)")
            #expect(four <= 2 * (gatherBank + 16 << 20))
            #expect(four - one <= 2 * (8 << 20))
            #expect(2 * removed > 2 * (16 << 20))
        }
    }

    @Test func actualAttentionPrefillAndMissingRecurrentCaptureRefusal() throws { try verify(hybrid: false) }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_MTP_GPU"] == "1"))
    func actualHybridShardsCommitAndRetireCapturedWindows() throws { try verify(hybrid: true) }

    private func verify(hybrid: Bool) throws {
        try Device.withDefaultDevice(gpu ? .gpu : .cpu) {
            let source = QwenTensorParallelFixtures.checkpoint(hidden: 256, layers: 4, heads: 4, kvHeads: 2, vocabulary: 256)
            var root = try JSONSerialization.jsonObject(with: source.configuration) as! [String: Any]
            var text = root["text_config"] as! [String: Any], tensors = source.tensors
            text["max_position_embeddings"] = 256
            if !hybrid {
                text["full_attention_interval"] = 1
                tensors.removeAll { $0.0.contains(".linear_attn.") }
                let attention = source.tensors.filter { $0.0.contains(".layers.3.self_attn.") }
                for layer in 0..<3 { tensors += attention.map { ($0.0.replacingOccurrences(of: ".layers.3.", with: ".layers.\(layer)."), $0.1) } }
            }
            root["text_config"] = text
            let configuration = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
            let profile = try QwenLayerStageGenerationProfile(identifier: "qwen27-tp-mtp-tiny", vocabularySize: 256,
                hiddenSize: 256, activationDType: "bfloat16", maximumPromptTokens: 128,
                maximumChunkTokens: 64, maximumOutputTokens: 32, maximumContextTokens: 256)
            let request = try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(),
                promptTokenIDs: (0..<67).map { ($0 * 7 + 3) % 256 }, chunkSize: 31, outputCount: 24, stopTokenIDs: [])
            let wire = Rendezvous()
            let owners = try (0..<2).map { rank -> Owner in
                let model = try QwenTensorParallelModel.assemble(configurationData: configuration,
                    role: .shard(rank: rank, size: 2), reduction: Rank(rank, wire)) { _, keep in
                    for (name, value) in tensors { try keep(name, value) }
                }
                let host = try CBv2StageKVHost(model: model.model, kind: gpu ? .paged : .contiguous,
                    lanes: 1, maximumTokensPerRequest: 256, maximumChunkTokens: 64)
                if !gpu {
                    #expect(throws: ProbeError.self) {
                        try QwenTensorParallelMTPSession(model: model, configuration: configuration, host: host, request: request)
                    }
                }
                return try Owner(.init(model: model, configuration: configuration, host: host, request: request,
                                       permitContiguousDiagnostic: !gpu), host)
            }
            defer { for owner in owners { try? owner.session.retire() } }
            while owners[0].session.schedule.committedPromptTokens < request.promptCount {
                try parallel(owners) { owner in
                    let output = try owner.session.prefill(check: {})
                    #expect(output.hidden.shape[0] == 1 && output.hidden.shape[2] == 256)
                    if let logits = output.logits { #expect(logits.shape == [1, 128] && all(isFinite(logits)).item(Bool.self)) }
                }
            }
            if !hybrid {
                // The production owned-state window deliberately requires
                // captured recurrent positions. An attention-only CPU model
                // proves prefill and fail-closed behavior, not hybrid rollback.
                try parallel(owners) { owner in
                    #expect(throws: ProbeError.self) {
                        try owner.session.beginWindow(tokens: MLXArray([Int32(7)]).reshaped([1, 1]),
                            offset: owner.session.state.committedTokens)
                    }
                }
            }
            for (count, kept) in (hybrid ? [(1, 1), (3, 1), (5, 2), (4, 4)] : []) {
                let offset = owners[0].session.state.committedTokens
                try parallel(owners) { owner in
                    let tokens = MLXArray((0..<count).map { Int32((offset + $0) % 256) }).reshaped([1, count])
                    let window = try owner.session.beginWindow(tokens: tokens, offset: offset)
                    eval(window.outputs + window.roots)
                    #expect(window.outputs[0].shape == [1, count, 128] && all(isFinite(window.outputs[0])).item(Bool.self))
                    try owner.session.confirmWindow(check: {})
                    // Capture the independently addressable full-window KV
                    // before settlement. Only its exact accepted prefix may remain.
                    owner.windowRows = owner.session.state.rows.compactMap { $0 }.map { row in
                        let snapshot = row.snapshot()
                        let keys = snapshot.keys[.ellipsis, 0..<(offset + kept), 0...]
                        let values = snapshot.values[.ellipsis, 0..<(offset + kept), 0...]
                        eval(keys, values)
                        return (keys.asData(access: .copy).data, values.asData(access: .copy).data)
                    }
                    let roots = try owner.session.settleWindow(keeping: kept)
                    eval(roots); try owner.session.confirmSettled(check: {})
                    #expect(owner.session.state.committedTokens == offset + kept)
                    #expect(owner.session.schedule.committedTokens == offset + kept)
                    for (row, before) in zip(owner.session.state.rows.compactMap({ $0 }), owner.windowRows) {
                        let snapshot = row.snapshot()
                        eval(snapshot.keys, snapshot.values)
                        #expect(snapshot.offset == offset + kept)
                        #expect(snapshot.keys.asData().data == before.0)
                        #expect(snapshot.values.asData().data == before.1)
                    }
                    owner.windowRows = []
                }
            }
            for owner in owners {
                try owner.session.retire()
                #expect(owner.session.retired && owner.session.state.isClosed && owner.session.state.recurrent.isReleased)
                #expect(owner.host.backend.bytesReserved == 0)
                #expect(throws: ProbeError.self) { try owner.session.prefill(check: {}) }
            }
        }
    }


    @Test func pairedPrefixRestoresActualAttentionAndAssistantHistoryOnCPU() throws {
        try verifyWarmPrefix(hybrid: false)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_MTP_GPU"] == "1"))
    func pairedPrefixPreservesHybridSpeculationAndRejectsFailedDonors() throws {
        try verifyWarmPrefix(hybrid: true)
    }

    /// MLX's process-default compile cache, emptied through mlx-c's handle API.
    private static func clearDefaultCompileCache() {
        var cache = mlx_compile_cache_new()
        defer { _ = mlx_compile_cache_free(cache) }
        if mlx_detail_compile_cache(&cache) == 0 { _ = mlx_detail_compile_clear_cache(cache) }
    }

    private func verifyWarmPrefix(hybrid: Bool) throws {
        let device = hybrid ? Device.gpu : Device.cpu
        // MLX keys compiled traces by its C++ default device, which the
        // task-scoped `withDefaultDevice` does not set: a trace an earlier GPU
        // test made would be replayed here with its operations on the GPU
        // stream, and one made here on the CPU by a later GPU test. This CPU
        // fixture starts and ends with an empty compile cache.
        if device == .cpu { Self.clearDefaultCompileCache() }
        defer { if device == .cpu { Self.clearDefaultCompileCache() } }
        try Device.withDefaultDevice(device) {
            let source = QwenTensorParallelFixtures.checkpoint(hidden: 256, layers: 4, heads: 4,
                kvHeads: 2, vocabulary: 256)
            var root = try JSONSerialization.jsonObject(with: source.configuration) as! [String: Any]
            var text = root["text_config"] as! [String: Any], tensors = source.tensors
            text["max_position_embeddings"] = 256; text["mtp_num_hidden_layers"] = 1
            if !hybrid {
                text["full_attention_interval"] = 1
                tensors.removeAll { $0.0.contains(".linear_attn.") }
                let attention = source.tensors.filter { $0.0.contains(".layers.3.self_attn.") }
                for layer in 0..<3 {
                    tensors += attention.map { ($0.0.replacingOccurrences(of: ".layers.3.", with: ".layers.\(layer)."), $0.1) }
                }
            }
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
            let weights = Dictionary(uniqueKeysWithValues: donor.parameters().flattened())
            for item in combinedCases.prefix(2) {
                let wire = Rendezvous(), groups = (0..<2).map { Rank($0, wire) }
                let models = try (0..<2).map { rank in
                    try QwenTensorParallelModel.assemble(configurationData: configuration,
                        role: .shard(rank: rank, size: 2), reduction: groups[rank]) { _, keep in
                        for (name, value) in tensors { try keep(name, value) }
                    }
                }
                let heads = try (0..<2).map { rank in
                    try QwenTensorParallelMTPHead(model: models[rank], configuration: configuration,
                        indexedWeights: weights, reduction: groups[rank])
                }
                let caches = (0..<2).map { _ in QwenTensorParallelMTPPrefixCache(enabled: true, budgetBytes: 128 << 20) }
                func owners(_ snapshots: [QwenTensorParallelMTPPrefixState]?,
                            heads loaded: [QwenTensorParallelMTPHead]? = nil) throws -> [DecoderOwner] {
                    let id = UUID()
                    return try (0..<2).map { rank in
                        let original = try combinedRequest(item, id: id)
                        let request = try original.planned(reusedPrefix: snapshots?[rank].committedTokens ?? 0,
                            splitFinalToken: false)
                        let host = try CBv2StageKVHost(model: models[rank].model, kind: hybrid ? .paged : .contiguous, lanes: 1,
                            maximumTokensPerRequest: 256, maximumChunkTokens: 64)
                        let target = try QwenTensorParallelMTPSession(model: models[rank], configuration: configuration,
                            host: host, request: request, restored: snapshots?[rank].target, permitContiguousDiagnostic: !hybrid)
                        let decoder = try QwenTensorParallelMTPDecoder(target: target, head: (loaded ?? heads)[rank],
                            group: groups[rank], depth: item.depth, restored: snapshots?[rank],
                            captureFrontier: snapshots == nil ? 62 : 0, captureLimitBytes: 64 << 20,
                            allocationBound: { (($0 + 16_383) / 16_384) * 16_384 })
                        return DecoderOwner(target: target, decoder: decoder, host: host)
                    }
                }
                func completePrompt(_ lanes: [DecoderOwner]) throws -> [Data] {
                    while lanes[0].target.state.committedTokens < 67 {
                        try parallelDecoders(lanes, device: device) { owner, _ in
                            owner.logits = try owner.decoder.prefill(check: {}) ?? owner.logits
                        }
                    }
                    return try lanes.map {
                        let logits = try #require($0.logits); eval(logits)
                        return logits.asData(access: .copy).data
                    }
                }
                func stateBytes(_ lane: DecoderOwner) throws -> [String: Data] {
                    var result: [String: Data] = [:]
                    for (index, row) in lane.target.state.rows.enumerated() {
                        guard let row else { continue }; let value = row.snapshot()
                        eval(value.keys, value.values)
                        result["k\(index)"] = value.keys.asData(access: .copy).data
                        result["v\(index)"] = value.values.asData(access: .copy).data
                    }
                    for (index, value) in lane.target.state.recurrent.confirmedStateSnapshot() ?? [:] {
                        if let conv = value.conv { eval(conv); result["c\(index)"] = conv.asData(access: .copy).data }
                        if let ssm = value.ssm { eval(ssm); result["s\(index)"] = ssm.asData(access: .copy).data }
                    }
                    return result
                }
                func generate(_ lanes: [DecoderOwner]) throws {
                    try parallelDecoders(lanes, device: device) { owner, rank in
                        let request = owner.target.request, model = owner.target.model
                        let full = model.gatheredLogits(try #require(owner.logits)); eval(full)
                        let choice = rank == 0 ? (request.sampler?.sample(full) ?? argMax(full, axis: -1)) : nil
                        let (selection, flags) = model.broadcastChoice(choice, stop: 0); eval(selection, flags)
                        let token = Int(selection.item(Int32.self))
                        if rank == 0 { request.sampler?.commit(token) }
                        try owner.decoder.begin(firstToken: token); owner.tokens = [token]; owner.logits = nil
                    }
                    while lanes[0].tokens.count < 11 {
                        try parallelDecoders(lanes, device: device) { owner, _ in
                            let round = try owner.decoder.step(lastToken: owner.tokens.last!,
                                remaining: 11 - owner.tokens.count, check: {})
                            #expect(owner.target.state.committedTokens == 67 + owner.tokens.count + round.tokens.count - 1)
                            owner.tokens += round.tokens
                        }
                    }
                    #expect(lanes[0].tokens == lanes[1].tokens)
                    #expect(lanes.allSatisfy { $0.decoder.statistics.rounds > 0 })
                }
                let cold = try owners(nil)
                defer { for lane in cold { try? lane.decoder.retire() } }
                let coldLogits = try completePrompt(cold), coldPrompt = try cold.map(stateBytes)
                #expect(cold.allSatisfy { $0.target.state.committedTokens == 67 })
                for lane in cold { #expect(throws: ProbeError.self) { try lane.decoder.takeCapturedPrefix() } }
                if hybrid { try generate(cold) }
                let coldFinal = try cold.map(stateBytes)
                var snapshots: [QwenTensorParallelMTPPrefixState] = []
                for lane in cold {
                    try lane.decoder.retire()
                    #expect(lane.host.isDrained && lane.host.backend.bytesReserved == 0)
                    let snapshot = try #require(try lane.decoder.takeCapturedPrefix())
                    #expect(snapshot.committedTokens == 62 && snapshot.assistant.targetInputCount == 62)
                    #expect(snapshot.allocatedBytes > snapshot.target.allocatedBytes)
                    #expect(try lane.decoder.takeCapturedPrefix() == nil)
                    snapshots.append(snapshot)
                }
                let prefixTokens = cold[0].target.request.promptTokenIDs
                let keys = QwenTensorParallelMTPPrefixCache.keys(scope: "exact-load-and-assistant|chunk31",
                    tokens: prefixTokens, frontiers: [31, 62])
                let key = try #require(keys[62])
                #expect(caches[0].insert(key: key, state: snapshots[0]))
                var votes = zip(caches[0].held(keys: keys, candidates: [31, 62]),
                                caches[1].held(keys: keys, candidates: [31, 62])).map(+)
                #expect(try QwenTensorParallelMTPPrefixCache.agreed(candidates: [31, 62], votes: votes) == 0)
                #expect(caches[1].insert(key: key, state: snapshots[1]))
                votes = zip(caches[0].held(keys: keys, candidates: [31, 62]),
                            caches[1].held(keys: keys, candidates: [31, 62])).map(+)
                #expect(try QwenTensorParallelMTPPrefixCache.agreed(candidates: [31, 62], votes: votes) == 62)
                let restored = try caches.map { try $0.restore(key: key, frontier: 62) }
                let immutable = restored.map { snapshot in
                    snapshot.target.attention.keys.sorted().flatMap { index in
                        let row = snapshot.target.attention[index]!
                        return [row.keys.asData(access: .copy).data, row.values.asData(access: .copy).data]
                    }
                }
                let warm = try owners(restored)
                defer { for lane in warm { try? lane.decoder.retire() } }
                #expect(warm.allSatisfy { $0.target.state.committedTokens == 62 })
                #expect(try completePrompt(warm) == coldLogits)
                #expect(try warm.map(stateBytes) == coldPrompt)
                if hybrid {
                    try generate(warm)
                    #expect(warm.map(\.tokens) == cold.map(\.tokens))
                    #expect(try warm.map(stateBytes) == coldFinal)
                }
                for (rank, lane) in warm.enumerated() {
                    try lane.decoder.retire()
                    #expect(lane.host.isDrained && lane.host.backend.bytesReserved == 0)
                    #expect(try lane.decoder.takeCapturedPrefix() == nil)
                    let snapshot = restored[rank]
                    let after = snapshot.target.attention.keys.sorted().flatMap { index in
                        let row = snapshot.target.attention[index]!
                        return [row.keys.asData(access: .copy).data, row.values.asData(access: .copy).data]
                    }
                    #expect(after == immutable[rank])
                }
                // The SSD tier: each rank's record (its target shard and the
                // assistant's trusted history), read back by a reopened tier
                // and rebound to a newly loaded head, as after a restart.
                let ssdRoot = FileManager.default.temporaryDirectory
                    .appendingPathComponent("qwen-tp-mtp-ssd-\(UUID().uuidString)", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: ssdRoot) }
                let ssdKey = Data((0..<32).map { UInt8(($0 * 29 + 5) % 256) })
                var ssdSettings = QwenStagePrefixDiskConfiguration(mode: .on(root: ssdRoot, key: ssdKey))
                ssdSettings.minimumTokens = 1; ssdSettings.minimumFreeBytes = 1 << 20
                let ssdScope = "exact-plan-and-assistant|chunk31|assistant-prefix"
                for rank in 0..<2 {
                    let tier = try QwenStagePrefixDiskTier(configuration: ssdSettings, root: ssdRoot, key: ssdKey,
                        planScope: ssdScope, rank: rank)
                    let stage = try #require(snapshots[rank].stageState(assistant: heads[rank].assistant))
                    tier.persist(scope: ssdScope, tokens: prefixTokens, states: [stage], blockTokens: 31)
                    #expect(tier.drain(timeoutSeconds: 60) && tier.recordCount == 1)
                    tier.close()
                }
                let fresh = try (0..<2).map { rank in
                    try QwenTensorParallelMTPHead(model: models[rank], configuration: configuration,
                        indexedWeights: weights, reduction: groups[rank])
                }
                let fromDisk = try (0..<2).map { rank -> QwenTensorParallelMTPPrefixState in
                    let tier = try QwenStagePrefixDiskTier(configuration: ssdSettings, root: ssdRoot, key: ssdKey,
                        planScope: ssdScope, rank: rank)
                    defer { tier.close() }
                    #expect(tier.frontiers(scope: ssdScope, tokens: prefixTokens, maximumFrontier: 66) == [62])
                    let stage = try #require(try tier.restore(scope: ssdScope, tokens: prefixTokens, frontier: 62, check: {}))
                    let state = try QwenTensorParallelMTPPrefixState(stage: stage, assistant: fresh[rank].assistant,
                        prompt: prefixTokens, allocationBound: { (($0 + 16_383) / 16_384) * 16_384 })
                    #expect(state.committedTokens == 62 && state.allocatedBytes == snapshots[rank].allocatedBytes)
                    // Bound to the head that read it, never the one that wrote it.
                    #expect(try heads[rank].assistant.restorePagedPrefixCheckpoint(state.assistant,
                        maximumSequenceLength: 78) == nil)
                    return state
                }
                let restarted = try owners(fromDisk, heads: fresh)
                defer { for lane in restarted { try? lane.decoder.retire() } }
                #expect(restarted.allSatisfy { $0.target.state.committedTokens == 62 })
                #expect(try completePrompt(restarted) == coldLogits)
                #expect(try restarted.map(stateBytes) == coldPrompt)
                if hybrid {
                    try generate(restarted)
                    #expect(restarted.map(\.tokens) == cold.map(\.tokens))
                    #expect(try restarted.map(stateBytes) == coldFinal)
                }
                for lane in restarted { try lane.decoder.retire(); #expect(lane.host.isDrained) }
                // Opaque assistant state belongs to the exact loaded head,
                // even when another head has byte-identical weights.
                let foreign = try QwenTensorParallelMTPHead(model: models[0], configuration: configuration,
                    indexedWeights: weights, reduction: groups[0])
                #expect(try foreign.assistant.restorePagedPrefixCheckpoint(snapshots[0].assistant,
                    maximumSequenceLength: 78) == nil)
                // A captured prompt followed by a checked failure never
                // becomes an eligible donor, even after later native drain.
                let failed = try owners(nil)
                defer { for lane in failed { try? lane.decoder.retire() } }
                _ = try completePrompt(failed)
                for lane in failed {
                    #expect(throws: ProbeError.self) { try lane.decoder.prefill(check: {}) }
                    try lane.decoder.retire()
                    #expect(try lane.decoder.takeCapturedPrefix() == nil)
                }
                caches.forEach { $0.sweep(); #expect($0.bytesInUse == 0) }
            }
        }
    }
}
