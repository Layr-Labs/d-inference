import Foundation
import MLX
@testable import MLXLLM
import MLXLMCommon
import MLXNN
import Testing
@testable import DarkbloomClusterRuntime

/// A tensor-parallel prompt step that merges consecutive frames into one
/// wavefront graph (`QwenTensorParallelPromptWavefront`) leaves the bytes the
/// frames leave run one at a time: logits, every attention row, every conv and
/// SSM state and the prefix capture, on both ranks, with the same collectives.
@Suite(.serialized)
struct QwenTensorParallelPromptWavefrontTests {
    private static func request(prompt: Int, chunk: Int = 512, output: Int = 16, reused: Int = 0) throws
        -> QwenLayerStageGenerationRequest {
        let chunk = min(chunk, prompt)
        let profile = try QwenLayerStageGenerationProfile(identifier: "qwen-tp-prompt-wavefront", vocabularySize: 256,
            hiddenSize: 2048, activationDType: "bfloat16", maximumPromptTokens: prompt, maximumChunkTokens: chunk,
            maximumOutputTokens: output, maximumContextTokens: prompt + output)
        let request = try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(),
            promptTokenIDs: (0..<prompt).map { ($0 * 37 + 5) % 256 }, chunkSize: chunk, outputCount: output,
            stopTokenIDs: [])
        return reused == 0 ? request : try request.planned(reusedPrefix: reused, splitFinalToken: false)
    }

    /// Steps merge up to the limit, end at the prompt's last (partial) frame
    /// and at a capture frontier, start after a reused prefix, and describe
    /// their frames' offset, tokens and final flag.
    @Test func stepsMergeFramesUpToTheLimitAndStopAtFrontiers() throws {
        let wavefront = QwenTensorParallelPromptWavefront.self
        let long = try Self.request(prompt: 5_000)
        let eight = wavefront.frames(request: long, from: 0, frontiers: [], limit: 8)
        #expect(eight.map(\.tokenOffset) == [0, 512, 1024, 1536, 2048, 2560, 3072, 3584])
        #expect(wavefront.step(eight) == .init(sequence: 0, phase: .prefill, tokenOffset: 0, tokenCount: 4096,
            finalPromptChunk: false))
        let rest = wavefront.frames(request: long, from: 8, frontiers: [], limit: 8)
        #expect(rest.map(\.tokenCount) == [512, 392] && wavefront.step(rest)?.finalPromptChunk == true)
        #expect(wavefront.frames(request: long, from: 0, frontiers: [1536, 4096], limit: 8).count == 3)
        #expect(wavefront.frames(request: long, from: 3, frontiers: [1536, 4096], limit: 8).count == 5)
        #expect(wavefront.frames(request: long, from: 0, frontiers: [], limit: 2).count == 2)
        #expect(wavefront.frames(request: long, from: 0, frontiers: [], limit: 1).count == 1)
        // A planned reuse starts on the grid; decode frames never merge.
        let restored = try Self.request(prompt: 1_100, reused: 512)
        let suffix = wavefront.frames(request: restored, from: 0, frontiers: [], limit: 8)
        #expect(suffix.map(\.tokenOffset) == [512, 1024] && wavefront.step(suffix)?.tokenCount == 588)
        #expect(wavefront.frames(request: restored, from: 2, frontiers: [], limit: 8).isEmpty)
        #expect(wavefront.step([]) == nil)
    }

    /// Two ranks in one process, summing by meeting each other (FP32, rank
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
                let deadline = Date().addingTimeInterval(120)
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
        var collectives = 0
        init(_ rank: Int, _ shared: Rendezvous) { self.rank = rank; self.shared = shared }
        func allSum(_ value: MLXArray) -> MLXArray { collectives += 1; return shared.sum(value, rank: rank) }
    }

    /// One rank's outcome: the last logits, every row's keys and values, every
    /// recurrent state, the prefix capture, the decoding lane's logits per step
    /// and the collectives the prompt's steps issued.
    struct Outcome: Equatable {
        var logits = Data()
        var rows: [Data] = []
        var recurrent: [Data] = []
        var capture: [Data] = []
        var decoded: [Data] = []
        var collectives = 0
        var steps = 0
    }

    private static func bytes(_ a: MLXArray) -> Data { eval(a); return a.asData(access: .copy).data }

    private static func state(of session: QwenTensorParallelBatchSession) -> (rows: [Data], recurrent: [Data]) {
        var rows: [Data] = []
        for row in session.state.rows {
            let snapshot = row!.snapshot()
            rows += [Data("\(snapshot.offset)".utf8), bytes(snapshot.keys), bytes(snapshot.values)]
        }
        let committed = session.state.recurrent.confirmedStateSnapshot() ?? [:]
        let recurrent = committed.keys.sorted().flatMap { [bytes(committed[$0]!.conv!), bytes(committed[$0]!.ssm!)] }
        return (rows, recurrent)
    }

    /// A prompt of `prompt` tokens on both ranks, each step merging up to
    /// `limit` frames (1: today's one frame a step, through `prefill(check:)`).
    /// With `decodeBeside`, a 300-token lane is prefilled first and decodes one
    /// fixed token before each prompt step and after the last. With
    /// `restoreAt`, the prompt resumes from the state a donor run one frame a
    /// step kept there (a prefix-cache hit).
    private static func run(_ models: [QwenTensorParallelModel], _ ranks: [Rank], configuration: Data,
                            kind: ClusterStageKVBackendKind, prompt: Int, limit: Int, captureFrontier: Int = 0,
                            decodeBeside: Bool = false, restoreAt: Int = 0) throws -> [Outcome] {
        let threads = TensorParallelRankThreads()
        let id = UUID(), besideID = UUID()
        let results = (0..<2).map { _ in RankResult() }
        for rank in ranks { rank.collectives = 0 }
        threads.run { rank in
            Device.withDefaultDevice(.gpu) {
                do {
                    let model = models[rank]
                    let host = try CBv2StageKVHost(model: model.model, kind: kind, lanes: decodeBeside ? 2 : 1,
                        maximumTokensPerRequest: prompt + 16, maximumChunkTokens: 512)
                    var target = try Self.request(prompt: prompt)
                    target = try QwenLayerStageGenerationRequest(profile: target.profile, requestID: id,
                        promptTokenIDs: target.promptTokenIDs, chunkSize: 512, outputCount: 16, stopTokenIDs: [])
                    let bound: (Int) throws -> Int = { (($0 + 16_383) / 16_384) * 16_384 }
                    var restored: QwenTensorParallelBatchPrefixState?
                    if restoreAt > 0 {
                        let donorHost = try CBv2StageKVHost(model: model.model, kind: kind, lanes: 1,
                            maximumTokensPerRequest: prompt + 16, maximumChunkTokens: 512)
                        let donor = try QwenTensorParallelBatchSession(model: model, configuration: configuration,
                            host: donorHost, request: target,
                            capture: QwenTensorParallelPrefixCapture(frontiers: [restoreAt], limitBytes: 256 << 20, allocationBound: bound))
                        while donor.schedule.committedPromptTokens < prompt { _ = try donor.prefill(check: {}) }
                        try donor.retire()
                        restored = try #require(try donor.takeCapturedPrefix()?.states.first(where: { $0.committedTokens == restoreAt }))
                        target = try target.planned(reusedPrefix: restoreAt, splitFinalToken: false)
                    }
                    let session = try QwenTensorParallelBatchSession(model: model, configuration: configuration,
                        host: host, request: target, restored: restored,
                        capture: captureFrontier > 0
                            ? QwenTensorParallelPrefixCapture(frontiers: [captureFrontier], limitBytes: 256 << 20, allocationBound: bound) : nil)
                    var beside: QwenTensorParallelBatchSession?
                    if decodeBeside {
                        let short = try Self.request(prompt: 300)
                        let other = try QwenLayerStageGenerationRequest(profile: short.profile, requestID: besideID,
                            promptTokenIDs: short.promptTokenIDs, chunkSize: short.chunkSize, outputCount: 16,
                            stopTokenIDs: [])
                        beside = try QwenTensorParallelBatchSession(model: model, configuration: configuration,
                            host: host, request: other)
                        _ = try beside!.prefill(check: {})
                    }
                    var outcome = Outcome()
                    func decodeBesideStep() throws {
                        guard let beside else { return }
                        let token = 11 + outcome.decoded.count
                        outcome.decoded.append(bytes(try QwenTensorParallelBatchSession.decode([beside],
                            tokens: [token], check: {})))
                    }
                    var last: MLXArray?
                    while session.schedule.committedPromptTokens < prompt {
                        try decodeBesideStep()
                        let issued = ranks[rank].collectives
                        defer { outcome.collectives += ranks[rank].collectives - issued; outcome.steps += 1 }
                        if limit == 1 {
                            last = try session.prefill(check: {}) ?? last
                        } else {
                            let step = try #require(QwenTensorParallelPromptWavefront.step(session.promptFrames(limit: limit)))
                            last = try session.prefill(step: step, check: {}) ?? last
                        }
                    }
                    try decodeBesideStep()
                    outcome.logits = bytes(try #require(last))
                    (outcome.rows, outcome.recurrent) = state(of: session)
                    try session.retire()
                    if let captured = try session.takeCapturedPrefix() {
                        // Every kept boundary's state, beside the one attention copy they share.
                        outcome.capture = [Data("\(captured.sharedBytes)".utf8)]
                        for kept in captured.states {
                            outcome.capture.append(Data("\(kept.committedTokens)".utf8))
                            outcome.capture += kept.attention.keys.sorted().flatMap { [bytes(kept.attention[$0]!.keys),
                                bytes(kept.attention[$0]!.values)] }
                            outcome.capture += kept.recurrent.keys.sorted().flatMap { [bytes(kept.recurrent[$0]!.conv),
                                bytes(kept.recurrent[$0]!.ssm)] }
                        }
                    }
                    try beside?.retire()
                    results[rank].outcome = outcome
                } catch { results[rank].failure = error }
            }
        }
        for result in results { if let failure = result.failure { throw failure } }
        return try results.map { try #require($0.outcome) }
    }

    /// One rank thread's own result.
    final class RankResult: @unchecked Sendable {
        var outcome: Outcome?
        var failure: Error?
    }

    /// Hybrid shards of one synthetic checkpoint (six recurrent, two attention
    /// layers) on two in-process ranks that sum by meeting each other.
    private static func pair() throws -> (configuration: Data, ranks: [Rank], models: [QwenTensorParallelModel]) {
        let fixture = QwenTensorParallelFixtures.checkpoint(hidden: 2048, layers: 8, heads: 8, kvHeads: 2,
            vocabulary: 256)
        var root = try JSONSerialization.jsonObject(with: fixture.configuration) as! [String: Any]
        var text = root["text_config"] as! [String: Any]
        text["max_position_embeddings"] = 8192; root["text_config"] = text
        let configuration = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        let wire = Rendezvous()
        let ranks = (0..<2).map { Rank($0, wire) }
        let models = try (0..<2).map { rank in
            try QwenTensorParallelModel.assemble(configurationData: configuration,
                role: .shard(rank: rank, size: 2), reduction: ranks[rank]) { _, keep in
                for (name, value) in fixture.tensors { try keep(name, value) }
            }
        }
        return (configuration, ranks, models)
    }

    /// Both ranks' temporaries per prompt step of `limit` frames (the largest
    /// step's peak above the settled allocation before and after it).
    private static func promptTransient(_ models: [QwenTensorParallelModel], configuration: Data, prompt: Int,
                                        limit: Int) throws -> Int {
        let threads = TensorParallelRankThreads()
        let id = UUID()
        let sessions = try (0..<2).map { rank -> QwenTensorParallelBatchSession in
            let host = try CBv2StageKVHost(model: models[rank].model, kind: .paged, lanes: 1,
                maximumTokensPerRequest: prompt + 16, maximumChunkTokens: 512)
            let shape = try Self.request(prompt: prompt)
            let request = try QwenLayerStageGenerationRequest(profile: shape.profile, requestID: id,
                promptTokenIDs: shape.promptTokenIDs, chunkSize: 512, outputCount: 16, stopTokenIDs: [])
            return try QwenTensorParallelBatchSession(model: models[rank], configuration: configuration, host: host,
                request: request)
        }
        defer { for session in sessions { try? session.retire() } }
        var largest = 0
        while sessions[0].schedule.committedPromptTokens < prompt {
            Stream.gpu.synchronize(); Memory.clearCache()
            let before = Memory.activeMemory
            Memory.peakMemory = 0
            let results = (0..<2).map { _ in RankResult() }
            threads.run { rank in
                Device.withDefaultDevice(.gpu) {
                    do {
                        let session = sessions[rank]
                        let step = try #require(QwenTensorParallelPromptWavefront.step(session.promptFrames(limit: limit)))
                        if let logits = try session.prefill(step: step, check: {}) { eval(logits) }
                    } catch { results[rank].failure = error }
                }
            }
            for result in results { if let failure = result.failure { throw failure } }
            Stream.gpu.synchronize()
            largest = max(largest, Memory.peakMemory - max(before, Memory.activeMemory))
            Memory.clearCache()
        }
        return largest
    }

    /// A merged step of eight frames allocates no more temporaries than the
    /// largest lone frame plus the further frames' charge
    /// (`QwenTensorParallelPromptWavefront.inFlightBytes`, which LOAD and each
    /// request's charge add to the shared prompt workspace), measured on both
    /// in-process ranks of a paged one-lane host at a 4,096-token prompt.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_BATCH_GPU"] == "1"))
    func mergedStepTemporariesStayWithinTheirCharge() throws {
        try Device.withDefaultDevice(.gpu) {
            let (configuration, _, models) = try Self.pair()
            let single = try Self.promptTransient(models, configuration: configuration, prompt: 4096, limit: 1)
            let merged = try Self.promptTransient(models, configuration: configuration, prompt: 4096,
                limit: QwenTensorParallelPromptWavefront.maximumFrames)
            let charge = try QwenTensorParallelPromptWavefront.inFlightBytes(plan: models[0].plan, chunkTokens: 512,
                allocationBound: { (($0 + 16_383) / 16_384) * 16_384 })
            print("darkbloom-tp-wavefront-memory-v1 frames=\(QwenTensorParallelPromptWavefront.maximumFrames)"
                + " single_pair=\(single) merged_pair=\(merged) in_flight_per_rank=\(charge)")
            #expect(single > 0 && merged <= single + 2 * charge, "a merged step exceeded a frame and its charge")
        }
    }

    /// Hybrid shards (six recurrent, two attention layers) over the in-process
    /// pair. Each case runs today's one frame a step, then merged steps:
    /// - a prompt ending mid-frame (1,100 tokens: one step of three frames),
    ///   paged (the one-lane host's prefill mirror) and contiguous;
    /// - a capture frontier inside the prompt (2,600 tokens, kept at 1,024:
    ///   steps of two and four frames, the capture taken between them);
    /// - beside a decoding lane on a two-lane paged host (each prompt history
    ///   gathered from its pages): two frames a step, the decoding lane's
    ///   logits unchanged at every step;
    /// - after a prefix restored at 1,024 tokens: the suffix's four frames in one step.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_BATCH_GPU"] == "1"))
    func mergedFramesKeepEveryBit() throws {
        try Device.withDefaultDevice(.gpu) {
            let (configuration, ranks, models) = try Self.pair()
            #expect(Qwen35PromptWavefront.supports(models[0].model))
            let cases: [(name: String, kind: ClusterStageKVBackendKind, prompt: Int, limit: Int, capture: Int, beside: Bool,
                         restore: Int)] = [
                ("mid-frame end, paged", .paged, 1_100, 8, 0, false, 0),
                ("mid-frame end, contiguous", .contiguous, 1_100, 8, 0, false, 0),
                ("capture frontier", .paged, 2_600, 8, 1_024, false, 0),
                ("beside a decoding lane", .paged, 1_100, QwenTensorParallelPromptWavefront.framesBesideDecoding, 0, true, 0),
                ("restored prefix", .paged, 2_600, 8, 0, false, 1_024),
            ]
            for item in cases {
                let before = try Self.run(models, ranks, configuration: configuration, kind: item.kind,
                    prompt: item.prompt, limit: 1, captureFrontier: item.capture, decodeBeside: item.beside,
                    restoreAt: item.restore)
                let after = try Self.run(models, ranks, configuration: configuration, kind: item.kind,
                    prompt: item.prompt, limit: item.limit, captureFrontier: item.capture, decodeBeside: item.beside,
                    restoreAt: item.restore)
                for rank in 0..<2 {
                    let x = before[rank], y = after[rank]
                    #expect(x.logits == y.logits, "\(item.name): final logits, rank \(rank)")
                    #expect(x.rows == y.rows && x.rows.count == 6, "\(item.name): attention rows, rank \(rank)")
                    #expect(x.recurrent == y.recurrent && x.recurrent.count == 12, "\(item.name): conv/SSM, rank \(rank)")
                    #expect(x.capture == y.capture && x.capture.isEmpty == (item.capture == 0),
                        "\(item.name): prefix capture, rank \(rank)")
                    #expect(x.collectives == y.collectives && x.collectives > 0,
                        "\(item.name): the prompt's collectives, rank \(rank)")
                    #expect(y.steps < x.steps, "\(item.name): \(y.steps) merged steps against \(x.steps) frames")
                    // Two merged steps (three decodes) against three frames (four): each decode is the lane's own.
                    #expect(y.decoded.count == (item.beside ? 3 : 0) && x.decoded.prefix(y.decoded.count).elementsEqual(y.decoded),
                        "\(item.name): the decoding lane's logits, rank \(rank)")
                }
                #expect(before[0].logits != before[1].logits, "\(item.name): ranks hold distinct vocabulary halves")
            }
        }
    }

    struct Reservation: QwenTensorParallelBatchReservation {
        let request: QwenLayerStageGenerationRequest
        let deadline: UInt64 = .max
        var laneStateBytes: Int { 1 }
        var joinable: Bool { true }
    }

    /// The native executor runs the leader's planned step: a 1,100-token
    /// prompt in one merged step selects the token one frame a step selects,
    /// on both ranks, and a lane takes a planned token count only where it
    /// ends one of its own steps (`promptStep(tokens:)`).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_BATCH_GPU"] == "1"))
    func executorRunsThePlannedMergedStep() throws {
        try Device.withDefaultDevice(.gpu) {
            let (configuration, ranks, models) = try Self.pair()
            let shape = try Self.request(prompt: 1_100)
            let request = try QwenLayerStageGenerationRequest(profile: shape.profile, requestID: UUID(),
                promptTokenIDs: shape.promptTokenIDs, chunkSize: 512, outputCount: 16, stopTokenIDs: [])
            func selected(limit: Int) throws -> [(token: Int, steps: Int)] {
                let results = (0..<2).map { _ in ExecutorResult() }
                let lanes = try (0..<2).map { rank -> QwenTensorParallelNativeBatchLane in
                    let host = try CBv2StageKVHost(model: models[rank].model, kind: .paged, lanes: 1,
                        maximumTokensPerRequest: 1_116, maximumChunkTokens: 512)
                    let executor = try QwenTensorParallelNativeBatchExecutor<Reservation>(model: models[rank],
                        configuration: configuration, host: host, group: ranks[rank], prepare: { _, _ in nil },
                        completedDecode: { _ in }, completedPrefill: {}, releaseResources: { _ in })
                    let lane = try executor.open(.init(request: request), check: {})
                    if rank == 0 {
                        #expect(lane.promptStep(tokens: 1_100) == QwenTensorParallelPromptWavefront.step(
                            lane.session.promptFrames(limit: 3)))
                        #expect(lane.promptStep(tokens: 1_024)?.finalPromptChunk == false)
                        #expect(lane.promptStep(tokens: 700) == nil && lane.promptStep(tokens: 2_048) == nil)
                    }
                    results[rank].executor = executor
                    return lane
                }
                defer { for lane in lanes { try? lane.session.retire() } }
                let threads = TensorParallelRankThreads()
                threads.run { rank in
                    Device.withDefaultDevice(.gpu) {
                        do {
                            let lane = lanes[rank], executor = try #require(results[rank].executor)
                            var steps = 0, token: Int?
                            while lane.nextFrame?.phase == .prefill {
                                let step = try #require(lane.promptStep(frames: limit))
                                token = try executor.prefill(lane, frame: step, check: {}); steps += 1
                            }
                            results[rank].selection = (try #require(token), steps)
                        } catch { results[rank].failure = error }
                    }
                }
                for result in results { if let failure = result.failure { throw failure } }
                return try results.map { try #require($0.selection) }
            }
            let one = try selected(limit: 1)
            let merged = try selected(limit: QwenTensorParallelPromptWavefront.maximumFrames)
            #expect(one.map(\.steps) == [3, 3] && merged.map(\.steps) == [1, 1])
            #expect(one.map(\.token) == merged.map(\.token) && one[0].token == one[1].token)
        }
    }

    /// One rank thread's executor and selection.
    final class ExecutorResult: @unchecked Sendable {
        var executor: QwenTensorParallelNativeBatchExecutor<Reservation>?
        var selection: (token: Int, steps: Int)?
        var failure: Error?
    }
}
