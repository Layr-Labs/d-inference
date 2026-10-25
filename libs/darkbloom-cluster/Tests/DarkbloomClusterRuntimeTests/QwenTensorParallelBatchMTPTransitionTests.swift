import DarkbloomClusterProtocol
import DarkbloomClusterPlacement
import Foundation
import MLX
@testable import MLXLLM
import MLXLMCommon
import MLXNN
import Testing
@testable import DarkbloomClusterRuntime

/// Real native shards and a real assistant, with eager in-process paired sums.
/// A tied output head makes every proposed token accepted so one-credit output
/// custody is exercised deterministically. This is not RDMA or model quality
/// evidence; the separate nonzero-head MTP suite owns acceptance arithmetic.
@Suite(.serialized)
struct QwenTensorParallelBatchMTPTransitionTests {
    private final class Wire: @unchecked Sendable {
        private let condition = NSCondition()
        private var values: [Int: [Float]] = [:], shapes: [Int: [Int]] = [:]
        private var result: [Float] = []
        private var leaving = 0, generation = 0
        private(set) var reductions = 0
        func sum(_ value: MLXArray, rank: Int) -> MLXArray {
            let bytes = value.asArray(Float.self)
            condition.lock()
            let deadline = Date().addingTimeInterval(30)
            while leaving > 0 { precondition(condition.wait(until: deadline), "Previous paired sum did not drain") }
            let entered = generation
            precondition(values[rank] == nil)
            values[rank] = bytes; shapes[rank] = value.shape
            if values.count == 2 {
                precondition(shapes[0] == shapes[1])
                result = zip(values[0]!, values[1]!).map(+); leaving = 2; condition.broadcast()
            } else {
                while leaving == 0 && generation == entered {
                    precondition(condition.wait(until: deadline), "Assistant transition peer did not arrive")
                }
            }
            let output = result; leaving -= 1
            if leaving == 0 {
                values = [:]; shapes = [:]; result = []; generation += 1; reductions += 1; condition.broadcast()
            }
            condition.unlock()
            return MLXArray(output, value.shape)
        }
    }
    private final class Rank: QwenTensorParallelReduction, @unchecked Sendable {
        let rank: Int, size = 2, wire: Wire
        init(_ rank: Int, _ wire: Wire) { self.rank = rank; self.wire = wire }
        func allSum(_ value: MLXArray) -> MLXArray { wire.sum(value, rank: rank) }
    }
    private struct Reservation: QwenTensorParallelBatchReservation {
        let request: QwenLayerStageGenerationRequest
        let deadline: UInt64 = .max
        var joinable: Bool { true }
        var laneStateBytes: Int { 1 }
    }
    private final class Owner: @unchecked Sendable {
        let rank: Int, model: QwenTensorParallelModel, host: CBv2StageKVHost, head: QwenTensorParallelMTPHead
        var executor: QwenTensorParallelNativeBatchExecutor<Reservation>!
        var lanes: [Int: QwenTensorParallelNativeBatchLane] = [:], tokens: [Int: [Int]] = [:]
        var widths: [Int] = [], rounds: [UUID: [QwenMTPStatistics]] = [:]
        var verifiedWidths: [UUID: [Int]] = [:], routes: [UUID: String] = [:]
        var captures: [Int: Int] = [:], released = Set<UUID>()
        var failResourceRelease = false
        var failure: Error?
        init(rank: Int, model: QwenTensorParallelModel, host: CBv2StageKVHost, head: QwenTensorParallelMTPHead) {
            self.rank = rank; self.model = model; self.host = host; self.head = head
        }
    }
    private final class Work: @unchecked Sendable {
        let body: (Owner) throws -> Void
        init(_ body: @escaping (Owner) throws -> Void) { self.body = body }
    }
    private func paired(_ owners: [Owner], _ body: @escaping (Owner) throws -> Void) throws {
        let work = Work(body)
        for owner in owners { owner.failure = nil }
        DispatchQueue.concurrentPerform(iterations: 2) { rank in
            Device.withDefaultDevice(.gpu) {
                do { try work.body(owners[rank]) } catch { owners[rank].failure = error }
            }
        }
        for owner in owners { if let error = owner.failure { throw error } }
    }

    private struct Retained: Decodable {
        struct Tensor: Decodable { let name: String; let shape: [Int]; let sourceDType: String; let byteCount: Int }
        struct Profile: Decodable { let configuration: Data; let canonicalTensors: [Tensor] }
        let twentySeven: Profile
    }
    private func cohortQuote(capacity: Int) throws -> QwenTensorParallelBatchMTPBudget {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("StageMetadataChecks/Inputs/qwen-retained-inputs.json")
        let input = try JSONDecoder().decode(Retained.self, from: Data(contentsOf: url)).twentySeven
        let family = try QwenDensePlacementFamily(configuration: input.configuration)
        let tensors = try family.requireRegisteredInventory(input.canonicalTensors.map {
            ClusterPlacementStoredTensor(name: $0.name, byteCount: $0.byteCount, dtype: $0.sourceDType, shape: $0.shape)
        })
        // The tiny four-layer target intentionally uses a complete production
        // Qwen27 quote as a conservative admission fixture. This tests custody
        // and execution, not measured allocation or a tiny-model estimator.
        let plan = try #require(family.tensorParallel)
        return try .derive(geometry: family.geometry, plan: plan, tensors: tensors,
            maximumTokens: 256, promptTokens: 256, chunkSize: 64, lanes: capacity, depth: 4,
            maximumSpeculativeWidth: capacity, allocationBound: { $0 })
    }

    /// The target's output head. `accepting` zeroes it, so every logit is 0,
    /// every token is 0 and every proposal is accepted (custody). `twoChoice`
    /// keeps zero scales but gives each vocabulary row its own constant bias,
    /// so a row's logits are bias times its input's sum: every choice is the
    /// highest or the lowest index by that sum's sign, and the assistant's
    /// proposals (the same head over its own hidden) are accepted some rounds
    /// and rejected at various positions in others, deterministically.
    enum HeadFixture { case accepting, twoChoice }

    /// `heads` query heads over two key/value heads: four is the suites'
    /// tiny geometry, eight the 9B's ratio of four query heads per KV head.
    private func pair(capacity: Int, cohort: Bool = false, heads: Int = 4, head kind: HeadFixture = .accepting,
                      joinsAhead: Bool = true, batchesDrafts: Bool = true) throws -> (owners: [Owner], wire: Wire) {
        let budget: QwenTensorParallelBatchMTPBudget?
        if cohort { budget = try cohortQuote(capacity: capacity) } else { budget = nil }
        let checkpoint = QwenTensorParallelFixtures.checkpoint(hidden: 256, layers: 4,
            heads: heads, kvHeads: 2, vocabulary: 256)
        var root = try JSONSerialization.jsonObject(with: checkpoint.configuration) as! [String: Any]
        var text = root["text_config"] as! [String: Any]
        text["max_position_embeddings"] = 256; text["mtp_num_hidden_layers"] = 1
        root["text_config"] = text
        root["mtplx_mtp"] = ["included": true, "prefix": "mtp.", "block_size": 3]
        root["mtplx_mtp_quantization"] = ["group_size": 64, "bits": 4, "mode": "affine"]
        let configuration = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        let config = try JSONDecoder().decode(Qwen35TextConfiguration.self,
            from: JSONSerialization.data(withJSONObject: text))
        let donor = Qwen35MTPModule(config)
        // Deterministic explicit parameters avoid changing the global RNG seed.
        let parameters = donor.parameters().flattened().sorted { $0.0 < $1.0 }.enumerated().map { index, entry in
            let (name, value) = entry
            let array = name.contains("norm") ? MLXArray.ones(value.shape, dtype: .bfloat16)
                : MLXArray((0..<value.size).map { Float(($0 * 13 + index * 7) % 31 - 15) / 128 })
                    .reshaped(value.shape).asType(.bfloat16)
            return (name, array)
        }
        donor.update(parameters: ModuleParameters.unflattened(parameters))
        quantize(model: donor, groupSize: 64, bits: 4); eval(donor)
        let assistantWeights = Dictionary(uniqueKeysWithValues: donor.parameters().flattened())
        let tensors = checkpoint.tensors.map { name, value -> (String, MLXArray) in
            guard name.hasPrefix("language_model.lm_head.") && value.dtype != .uint32 else { return (name, value) }
            guard kind == .twoChoice, name.hasSuffix(".biases") else { return (name, MLXArray.zeros(value.shape, dtype: value.dtype)) }
            let rows = value.dim(0), groups = value.dim(1)
            let bias = MLXArray((0..<rows).map { Float($0 - rows / 2) / 4096 }).reshaped([rows, 1])
            return (name, broadcast(bias, to: [rows, groups]).asType(value.dtype))
        }
        let wire = Wire()
        let owners = try (0..<2).map { rank -> Owner in
            let reduction = Rank(rank, wire)
            let model = try QwenTensorParallelModel.assemble(configurationData: configuration,
                role: .shard(rank: rank, size: 2), reduction: reduction) { _, keep in
                for (name, value) in tensors { try keep(name, value) }
            }
            let host = try CBv2StageKVHost(model: model.model, kind: .paged, lanes: capacity,
                maximumTokensPerRequest: 256, maximumChunkTokens: 64)
            let head = try QwenTensorParallelMTPHead(model: model, configuration: configuration,
                indexedWeights: assistantWeights, reduction: reduction)
            let owner = Owner(rank: rank, model: model, host: host, head: head)
            let prefixBudget = QwenTensorParallelMTPPrefixBudget(maximumTokens: 0, targetCaptureBytes: 0,
                assistantCaptureBytes: 0, captureBytes: 0, residentBytes: 0)
            owner.executor = try .init(model: model, configuration: configuration, host: host, group: reduction,
                prepare: { _, _ in nil }, completedDecode: { [unowned owner] in owner.widths.append($0) },
                completedPrefill: {}, releaseResources: { [unowned owner] reservation in
                    if owner.failResourceRelease { throw ProbeError("Injected host-resource drain failure") }
                    #expect(owner.released.insert(reservation.request.requestID).inserted)
                }, assistant: .init(head: head, depth: 4, prefix: nil, prefixBudget: prefixBudget,
                    allocationBound: { $0 }, cohortBudget: budget),
                openedLane: { [unowned owner] id, route in owner.routes[id] = route },
                completedSpeculation: { [unowned owner] id, width, stats in
                    owner.rounds[id, default: []].append(stats)
                    owner.verifiedWidths[id, default: []].append(width)
                }, cohortJoinsAhead: joinsAhead, cohortBatchesDrafts: batchesDrafts)
            return owner
        }
        return (owners, wire)
    }

    private func request(id: UUID, row: Int, outputs: Int, capture: Bool, history: Bool) throws -> QwenLayerStageGenerationRequest {
        let profile = try QwenLayerStageGenerationProfile(identifier: "qwen-tp-resident-mtp-transition",
            vocabularySize: 256, hiddenSize: 256, activationDType: "bfloat16",
            maximumPromptTokens: 128, maximumChunkTokens: 64, maximumOutputTokens: 64, maximumContextTokens: 256)
        let sampling: ClusterWorkerSampling? = capture || history ? .init(temperature: 0, topP: 1, topK: 0,
            minP: 0, repetitionPenalty: history ? 1.1 : 1, repetitionContextSize: 32,
            frequencyPenalty: 0, presencePenalty: 0, seed: 918, stream: 0, logitBias: [], topLogprobs: capture ? 2 : 0) : nil
        return try .init(profile: profile, requestID: id,
            promptTokenIDs: (0..<(7 + row * 2)).map { ($0 * 7 + row + 3) % 256 }, chunkSize: 5,
            outputCount: outputs, stopTokenIDs: [], sampling: sampling)
    }

    private func open(_ owners: [Owner], row: Int, outputs: Int = 48, capture: Bool = false, history: Bool = false,
                      zeroTokens: Bool = true) throws {
        let id = UUID()
        try paired(owners) { owner in
            // Each process has its own sampler, even though identity is shared.
            let value = try request(id: id, row: row, outputs: outputs, capture: capture, history: history)
            owner.lanes[row] = try owner.executor.open(.init(request: value), check: {})
            owner.tokens[row] = []
            #expect((owner.lanes[row]!.assistant != nil) == (!capture && !history))
        }
        while owners[0].lanes[row]!.nextFrame?.phase == .prefill {
            try paired(owners) { owner in
                let lane = owner.lanes[row]!
                if let token = try owner.executor.prefill(lane, frame: lane.nextFrame!, check: {}) {
                    if zeroTokens { #expect(token == 0) }
                    owner.tokens[row]!.append(token)
                    if owner.rank == 0 { try recordLogprobs(owner, row: row) }
                }
            }
        }
        for owner in owners { #expect(owner.tokens[row]!.count == 1) }
    }

    private func recordLogprobs(_ owner: Owner, row: Int) throws {
        let lane = owner.lanes[row]!, capture = (lane.session.request.sampling?.wire.topLogprobs ?? 0) > 0
        if capture {
            let captured = try owner.executor.takeLogprobs(lane)
            let value = try #require(captured)
            #expect(value.logprob.isFinite && value.top.count == 2)
            owner.captures[row, default: 0] += 1
        } else { #expect(try owner.executor.takeLogprobs(lane) == nil) }
    }

    private func decode(_ owners: [Owner], rows: [Int]) throws {
        try paired(owners) { owner in
            let lanes = rows.map { owner.lanes[$0]! }
            let selected = try owner.executor.decode(lanes, tokens: rows.map { owner.tokens[$0]!.last! }, check: {})
            #expect(selected == Array(repeating: 0, count: rows.count))
            for (row, token) in zip(rows, selected) {
                owner.tokens[row]!.append(token)
                let lane = owner.lanes[row]!
                #expect(lane.session.committedTokens == lane.session.request.promptCount
                    + owner.tokens[row]!.count + lane.accepted.count - 1)
                #expect(lane.session.schedule.committedTokens == lane.session.state.committedTokens)
                if owner.rank == 0 { try recordLogprobs(owner, row: row) }
            }
        }
        for row in rows { #expect(owners[0].tokens[row] == owners[1].tokens[row]) }
    }

    private func state(_ lane: QwenTensorParallelNativeBatchLane) throws -> [Data] {
        var roots: [MLXArray] = []
        for row in lane.session.state.rows.compactMap({ $0 }) {
            let snapshot = row.snapshot(); roots += [snapshot.keys, snapshot.values]
        }
        let recurrent = try #require(lane.session.state.recurrent.confirmedStateSnapshot())
        #expect(recurrent.count == 3)
        for layer in recurrent.keys.sorted() { roots += [try #require(recurrent[layer]!.conv), try #require(recurrent[layer]!.ssm)] }
        eval(roots)
        return roots.map { $0.asData(access: .copy).data }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_MTP_GPU"] == "1"))
    func oneResidentAssistantSurvivesCreditJoinsRectanglesAndResumedSpeculation() throws {
        try residentAssistantSurvivesCreditJoins(capacities: [2, 4, 8], heads: 4)
    }

    /// The same transitions on a dense geometry other than the suites' own
    /// (the 9B's head ratio): the assistant and its rectangles follow the
    /// shard's heads, not a registered row's constants.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_MTP_GPU"] == "1"))
    func nineBRatioAssistantSurvivesCreditJoinsRectanglesAndResumedSpeculation() throws {
        try residentAssistantSurvivesCreditJoins(capacities: [2, 4], heads: 8)
    }

    private func residentAssistantSurvivesCreditJoins(capacities: [Int], heads: Int) throws {
        try Device.withDefaultDevice(.gpu) {
            for capacity in capacities {
                let (owners, _) = try pair(capacity: capacity, heads: heads)
                defer {
                    for owner in owners {
                        owner.failResourceRelease = false
                        for lane in owner.lanes.values where !lane.isClosed {
                            try? owner.executor.retire(lane, reason: nil, selected: 0, last: nil)
                        }
                    }
                }
                let heads = owners.map { ObjectIdentifier($0.head) }
                try open(owners, row: 0)
                try decode(owners, rows: [0])
                let settled = try owners.map { try state($0.lanes[0]!) }
                for owner in owners {
                    #expect(owner.lanes[0]!.accepted.count == 4)
                    #expect(owner.lanes[0]!.assistant!.statistics.rounds == 1)
                }
                for row in 1..<capacity {
                    try open(owners, row: row, capture: capacity >= 4 && row == capacity - 1,
                        history: capacity >= 4 && row == capacity - 2)
                }
                // A is already settled and awaits four credits. Other lanes
                // run native target work while A publishes its exact suffix.
                for remaining in stride(from: 3, through: 0, by: -1) {
                    try decode(owners, rows: Array((0..<capacity).reversed()))
                    for (rank, owner) in owners.enumerated() {
                        #expect(owner.lanes[0]!.accepted.count == remaining)
                        #expect(try state(owner.lanes[0]!) == settled[rank])
                        #expect(owner.widths.last == capacity - 1)
                    }
                }
                for step in 0..<3 {
                    try decode(owners, rows: (0..<capacity).map { ($0 + step) % capacity })
                    for owner in owners {
                        #expect(owner.widths.last == capacity)
                        #expect(owner.lanes[0]!.assistant!.statistics.rounds == 1)
                        #expect(owner.lanes[1]!.assistant!.statistics.rounds == 0)
                    }
                }
                try decode(owners, rows: [0])
                for (rank, owner) in owners.enumerated() {
                    let lane = owner.lanes[0]!, id = lane.session.request.requestID
                    #expect(ObjectIdentifier(owner.head) == heads[rank])
                    #expect(lane.assistant!.statistics.rounds == 2 && lane.accepted.count == 4)
                    #expect(owner.rounds[id]?.map(\.rounds) == [1, 2])
                    #expect(owner.verifiedWidths[id] == [1, 1])
                    // Wrong finish reason must fail before it can discard a
                    // verified suffix or retire this request's native state.
                    #expect(throws: ProbeError.self) {
                        try owner.executor.retire(lane, reason: .length,
                            selected: owner.tokens[0]!.count, last: owner.tokens[0]!.last)
                    }
                    #expect(!lane.session.retired && lane.accepted.count == 4)
                    if capacity == 4 {
                        owner.failResourceRelease = true
                        #expect(throws: ProbeError.self) {
                            try owner.executor.retire(lane, reason: .clientStop,
                                selected: owner.tokens[0]!.count, last: owner.tokens[0]!.last)
                        }
                        #expect(lane.session.retired && lane.session.state.isClosed)
                        #expect(!lane.isClosed && !lane.resourcesReleased && lane.accepted.count == 4)
                        owner.failResourceRelease = false
                    }
                    try owner.executor.retire(lane, reason: .clientStop,
                        selected: owner.tokens[0]!.count, last: owner.tokens[0]!.last)
                    try owner.executor.confirmedRetirement(lane, clean: true)
                    #expect(lane.isClosed && lane.accepted.isEmpty && !owner.host.isDrained)
                }
                try decode(owners, rows: Array(1..<capacity))
                for owner in owners {
                    for row in 1..<capacity {
                        let lane = owner.lanes[row]!
                        if let sampler = lane.session.request.sampler {
                            #expect(sampler.nextOutputIndex == (owner.rank == 0 ? owner.tokens[row]!.count : 0))
                        }
                        if capacity >= 4 && row == capacity - 1 && owner.rank == 0 {
                            #expect(owner.captures[row] == owner.tokens[row]!.count)
                        }
                        try owner.executor.retire(lane, reason: nil, selected: 0, last: nil)
                        try owner.executor.confirmedRetirement(lane, clean: false)
                    }
                    #expect(owner.host.isDrained && owner.host.backend.bytesReserved == 0)
                    #expect(owner.released.count == capacity)
                }
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_MTP_GPU"] == "1"))
    func finalNativeWindowStillPublishesEveryAcceptedTokenUnderSeparateCredits() throws {
        try Device.withDefaultDevice(.gpu) {
            let (owners, wire) = try pair(capacity: 2)
            defer { for owner in owners { for lane in owner.lanes.values where !lane.isClosed {
                try? owner.executor.retire(lane, reason: nil, selected: 0, last: nil)
            } } }
            try open(owners, row: 0, outputs: 6)
            try decode(owners, rows: [0])
            let settled = try owners.map { try state($0.lanes[0]!) }, reductions = wire.reductions
            for owner in owners {
                #expect(owner.lanes[0]!.nextFrame == nil)
                #expect(owner.lanes[0]!.canSelectNext && owner.lanes[0]!.accepted.count == 4)
            }
            for _ in 0..<4 { try decode(owners, rows: [0]) }
            #expect(wire.reductions == reductions, "Credited suffix must execute no target or assistant reductions")
            for (rank, owner) in owners.enumerated() {
                let lane = owner.lanes[0]!
                #expect(owner.tokens[0]!.count == 6 && lane.accepted.isEmpty && !lane.canSelectNext)
                #expect(try state(lane) == settled[rank])
                try owner.executor.retire(lane, reason: .length, selected: 6, last: 0)
                #expect(lane.isClosed && owner.host.isDrained && owner.host.backend.bytesReserved == 0)
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_MTP_GPU"] == "1"))
    func concurrentRoundsKeepIndependentCreditsAndSurviveCohortRetirement() throws {
        try Device.withDefaultDevice(.gpu) {
            for capacity in [2, 4, 8] {
                let (owners, wire) = try pair(capacity: capacity, cohort: true)
                defer { for owner in owners { for lane in owner.lanes.values where !lane.isClosed {
                    try? owner.executor.retire(lane, reason: nil, selected: 0, last: nil)
                } } }
                for row in 0..<capacity { try open(owners, row: row) }
                try decode(owners, rows: Array((0..<capacity).reversed()))
                let snapshots = try owners.map { owner in try (0..<capacity).map { try state(owner.lanes[$0]!) } }
                let reductions = wire.reductions
                for owner in owners {
                    #expect(owner.widths == [capacity])
                    for row in 0..<capacity {
                        let id = owner.lanes[row]!.session.request.requestID
                        #expect(owner.verifiedWidths[id] == [capacity] && owner.routes[id] == "assistant")
                        #expect(owner.lanes[row]!.assistant!.statistics.rounds == 1)
                        #expect(owner.lanes[row]!.accepted.count == 4)
                    }
                }
                // A peer with four accepted tokens still queued may retire;
                // surviving row views must retain the old cohort backing.
                for owner in owners {
                    let row = capacity - 1, lane = owner.lanes[row]!
                    try owner.executor.retire(lane, reason: .clientStop,
                        selected: owner.tokens[row]!.count, last: owner.tokens[row]!.last)
                    try owner.executor.confirmedRetirement(lane, clean: true)
                    #expect(lane.isClosed && lane.accepted.isEmpty && !owner.host.isDrained)
                }
                // Credits arrive for different subsets. They must publish
                // the retained suffix without another target or head call.
                for row in 0..<(capacity - 1) {
                    for _ in 0..<4 { try decode(owners, rows: [row]) }
                }
                #expect(wire.reductions == reductions)
                for (rank, owner) in owners.enumerated() {
                    for row in 0..<(capacity - 1) {
                        let current = try state(owner.lanes[row]!)
                        #expect(current == snapshots[rank][row])
                        #expect(owner.tokens[row]!.count == 6 && owner.lanes[row]!.accepted.isEmpty)
                    }
                }
                try decode(owners, rows: Array((0..<(capacity - 1)).reversed()))
                for owner in owners {
                    #expect(owner.widths == [capacity, capacity - 1])
                    for row in 0..<(capacity - 1) {
                        let lane = owner.lanes[row]!
                        #expect(lane.assistant!.statistics.rounds == 2 && lane.accepted.count == 4)
                        #expect(owner.verifiedWidths[lane.session.request.requestID] == [capacity, capacity - 1])
                        try owner.executor.retire(lane, reason: .clientStop,
                            selected: owner.tokens[row]!.count, last: owner.tokens[row]!.last)
                        try owner.executor.confirmedRetirement(lane, clean: true)
                    }
                    #expect(owner.host.isDrained && owner.host.backend.bytesReserved == 0)
                    #expect(owner.released.count == capacity)
                }
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_MTP_GPU"] == "1"))
    func eligibleCohortCoexistsWithOrdinaryHistoryAndLogprobLanes() throws {
        try Device.withDefaultDevice(.gpu) {
            let (owners, _) = try pair(capacity: 4, cohort: true)
            defer { for owner in owners { for lane in owner.lanes.values where !lane.isClosed {
                try? owner.executor.retire(lane, reason: nil, selected: 0, last: nil)
            } } }
            try open(owners, row: 0); try open(owners, row: 1)
            try open(owners, row: 2, history: true); try open(owners, row: 3, capture: true)
            try decode(owners, rows: [3, 1, 2, 0])
            for owner in owners {
                #expect(owner.widths == [2, 2])
                #expect(owner.lanes[0]!.assistant!.statistics.rounds == 1)
                #expect(owner.lanes[1]!.assistant!.statistics.rounds == 1)
            }
            for _ in 0..<4 { try decode(owners, rows: [1, 3, 0, 2]) }
            try decode(owners, rows: [0, 2, 1, 3])
            for owner in owners {
                #expect(owner.widths == [2, 2, 2, 2, 2, 2, 2, 2])
                for row in [0, 1] { #expect(owner.lanes[row]!.assistant!.statistics.rounds == 2) }
                for row in [0, 1] {
                    let id = owner.lanes[row]!.session.request.requestID
                    #expect(owner.verifiedWidths[id] == [2, 2] && owner.routes[id] == "assistant")
                }
                for row in [2, 3] {
                    let id = owner.lanes[row]!.session.request.requestID
                    #expect(owner.verifiedWidths[id] == nil && owner.routes[id] == "ordinary_sampler")
                    let sampler = try #require(owner.lanes[row]!.session.request.sampler)
                    #expect(sampler.nextOutputIndex == (owner.rank == 0 ? owner.tokens[row]!.count : 0))
                }
                if owner.rank == 0 { #expect(owner.captures[3] == owner.tokens[3]!.count) }
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_MTP_GPU"] == "1"))
    func concurrentFinalWindowsDrainWithoutFurtherNativeWork() throws {
        try Device.withDefaultDevice(.gpu) {
            let (owners, wire) = try pair(capacity: 2, cohort: true)
            defer { for owner in owners { for lane in owner.lanes.values where !lane.isClosed {
                try? owner.executor.retire(lane, reason: nil, selected: 0, last: nil)
            } } }
            for row in 0..<2 { try open(owners, row: row, outputs: 6) }
            try decode(owners, rows: [0, 1])
            let reductions = wire.reductions
            for owner in owners { for row in 0..<2 {
                #expect(owner.lanes[row]!.nextFrame == nil && owner.lanes[row]!.canSelectNext)
            } }
            for _ in 0..<4 { try decode(owners, rows: [1, 0]) }
            #expect(wire.reductions == reductions)
            for owner in owners {
                for row in 0..<2 {
                    let lane = owner.lanes[row]!
                    #expect(owner.tokens[row]!.count == 6 && !lane.canSelectNext)
                    try owner.executor.retire(lane, reason: .length, selected: 6, last: 0)
                }
                #expect(owner.host.isDrained && owner.host.backend.bytesReserved == 0)
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_MTP_GPU"] == "1"))
    func failedConcurrentDraftPublishesNothingAndRetainsAllRowsForCheckedRetirement() throws {
        try Device.withDefaultDevice(.gpu) {
            let (owners, _) = try pair(capacity: 2, cohort: true)
            defer { for owner in owners { for lane in owner.lanes.values where !lane.isClosed {
                try? owner.executor.retire(lane, reason: nil, selected: 0, last: nil)
            } } }
            for row in 0..<2 { try open(owners, row: row) }
            try paired(owners) { owner in
                let lanes = [owner.lanes[0]!, owner.lanes[1]!]
                #expect(throws: ProbeError.self) {
                    try owner.executor.decode(lanes, tokens: [0, 0], check: {
                        throw ProbeError("Injected shared draft boundary cancellation")
                    })
                }
                #expect(owner.widths.isEmpty && owner.rounds.isEmpty && owner.verifiedWidths.isEmpty)
                for lane in lanes {
                    #expect(lane.accepted.isEmpty && lane.selectedCount == 1)
                    #expect(lane.session.committedTokens == lane.session.request.promptCount)
                    #expect(!lane.assistant!.canSpeculate(lastToken: 0, remaining: 47))
                    #expect(!lane.isClosed && !lane.resourcesReleased)
                    try owner.executor.retire(lane, reason: .clientStop, selected: 1, last: 0)
                    try owner.executor.confirmedRetirement(lane, clean: false)
                }
                #expect(owner.host.isDrained && owner.host.backend.bytesReserved == 0)
                #expect(owner.released.count == 2)
            }
        }
    }

    /// One driver step for `rows` (any tokens), as the TP batch driver takes it.
    private func step(_ owners: [Owner], rows: [Int]) throws {
        try paired(owners) { owner in
            let lanes = rows.map { owner.lanes[$0]! }
            let selected = try owner.executor.decode(lanes, tokens: rows.map { owner.tokens[$0]!.last! }, check: {})
            for (row, token) in zip(rows, selected) {
                owner.tokens[row]!.append(token)
                let lane = owner.lanes[row]!
                // The decoder may be ahead of the driver by one queued suffix
                // plus one round; native history is that far ahead, no further.
                #expect(lane.session.committedTokens == lane.session.request.promptCount
                    + owner.tokens[row]!.count + lane.accepted.count - 1)
                #expect(lane.accepted.count <= QwenTensorParallelAcceptedSelections.capacity(depth: 4))
            }
        }
        for row in rows { #expect(owners[0].tokens[row] == owners[1].tokens[row]) }
    }

    private struct RowRun: Equatable {
        let tokens: [Int]
        let rounds: Int, plainSteps: Int, emitted: Int
        let examined: [Int], accepted: [Int]
        let state: [[Data]]
    }

    private func finish(_ owners: [Owner], row: Int) throws -> RowRun {
        let decoder = owners[0].lanes[row]!.assistant!
        let statistics = decoder.statistics
        for owner in owners { #expect(owner.lanes[row]!.assistant!.statistics.emittedTokens == statistics.emittedTokens) }
        let run = RowRun(tokens: owners[0].tokens[row]!, rounds: statistics.rounds, plainSteps: statistics.plainSteps,
            emitted: statistics.emittedTokens, examined: statistics.examinedByPosition,
            accepted: statistics.acceptedByPosition, state: try owners.map { try state($0.lanes[row]!) })
        for owner in owners {
            let lane = owner.lanes[row]!
            #expect(lane.accepted.isEmpty)
            try owner.executor.retire(lane, reason: .length, selected: owner.tokens[row]!.count, last: owner.tokens[row]!.last)
            try owner.executor.confirmedRetirement(lane, clean: true)
            #expect(lane.isClosed)
        }
        return run
    }

    /// Rows whose rounds start a step apart (each request joins while the
    /// previous one's accepted suffix still waits for credit) verify as one
    /// cohort from the next round on, instead of alternately one row per
    /// round for as long as they run. Every row's tokens, MTP statistics and
    /// final native state (paged K/V and recurrent bytes on both ranks) equal
    /// that row's solo run, with every proposal accepted and with proposals
    /// rejected at varying positions; the earlier empty-queue-only cohort is
    /// the control, and neither leaves native memory behind.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_MTP_GPU"] == "1"))
    func staggeredRowsVerifyAsOneCohortAndMatchTheirSoloRuns() throws {
        try Device.withDefaultDevice(.gpu) {
            for head in [HeadFixture.accepting, .twoChoice] {
                for capacity in [2, 4] {
                    let outputs = 30
                    var solo: [RowRun] = []
                    for row in 0..<capacity {
                        let (owners, _) = try pair(capacity: capacity, cohort: true, head: head)
                        try open(owners, row: row, outputs: outputs, zeroTokens: head == .accepting)
                        while owners[0].tokens[row]!.count < outputs { try step(owners, rows: [row]) }
                        solo.append(try finish(owners, row: row))
                        for owner in owners { #expect(owner.host.isDrained && owner.host.backend.bytesReserved == 0) }
                    }
                    var rounds: [Bool: (calls: Int, oneRow: Int)] = [:]
                    for joinsAhead in [false, true] {
                        let (owners, wire) = try pair(capacity: capacity, cohort: true, head: head, joinsAhead: joinsAhead)
                        defer { for owner in owners { for lane in owner.lanes.values where !lane.isClosed {
                            try? owner.executor.retire(lane, reason: nil, selected: 0, last: nil)
                        } } }
                        var runs = [RowRun?](repeating: nil, count: capacity)
                        func active() -> [Int] { (0..<capacity).filter { runs[$0] == nil && owners[0].lanes[$0] != nil } }
                        func advance() throws {
                            let rows = active()
                            guard !rows.isEmpty else { return }
                            try step(owners, rows: rows)
                            for row in rows where owners[0].tokens[row]!.count == outputs { runs[row] = try finish(owners, row: row) }
                        }
                        // Stagger: each request opens after the earlier ones took a step.
                        for row in 0..<capacity { try open(owners, row: row, outputs: outputs, zeroTokens: head == .accepting); try advance() }
                        let opened = owners[0].widths.count
                        while !active().isEmpty { try advance() }
                        for row in 0..<capacity {
                            let run = try #require(runs[row])
                            #expect(run == solo[row], "\(head) capacity \(capacity) row \(row) joinsAhead \(joinsAhead) differs from its solo run")
                        }
                        for owner in owners {
                            #expect(owner.widths == owners[0].widths)
                            #expect(owner.host.isDrained && owner.host.backend.bytesReserved == 0)
                            #expect(owner.released.count == capacity)
                        }
                        let after = owners[0].widths[opened...]
                        rounds[joinsAhead] = (owners[0].widths.count, after.filter { $0 == 1 }.count)
                        print("darkbloom-cohort-sync-test head=\(head) capacity=\(capacity) joins_ahead=\(joinsAhead)"
                            + " native_calls=\(owners[0].widths.count) one_row_after_open=\(after.filter { $0 == 1 }.count)"
                            + " widths=\(owners[0].widths.map(String.init).joined(separator: ",")) reductions=\(wire.reductions)"
                            + " emitted=\(solo.map { "\($0.emitted)/\($0.rounds)" }.joined(separator: ","))")
                    }
                    // The same tokens with fewer, wider native verifications. With every
                    // proposal accepted the control alternates one row per round for good.
                    let control = try #require(rounds[false]), synchronized = try #require(rounds[true])
                    #expect(synchronized.calls <= control.calls && synchronized.oneRow <= control.oneRow)
                    if head == .accepting { #expect(synchronized.calls < control.calls && synchronized.oneRow < control.oneRow) }
                }
            }
        }
    }

    /// A row that ran ahead (two settled rounds queued) can still stop at a
    /// client's request: its unpublished selections are discarded with its
    /// native history, its resources drain, and the cohort's other row runs
    /// on to exactly its solo tokens and state.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_MTP_GPU"] == "1"))
    func aheadRowStopsCleanlyAndItsCohortContinues() throws {
        try Device.withDefaultDevice(.gpu) {
            let outputs = 30
            let (soloOwners, _) = try pair(capacity: 2, cohort: true)
            try open(soloOwners, row: 1, outputs: outputs)
            while soloOwners[0].tokens[1]!.count < outputs { try step(soloOwners, rows: [1]) }
            let solo = try finish(soloOwners, row: 1)
            let (owners, _) = try pair(capacity: 2, cohort: true)
            defer { for owner in owners { for lane in owner.lanes.values where !lane.isClosed {
                try? owner.executor.retire(lane, reason: nil, selected: 0, last: nil)
            } } }
            try open(owners, row: 0, outputs: outputs); try step(owners, rows: [0])
            try open(owners, row: 1, outputs: outputs); try step(owners, rows: [0, 1])
            // Row 0 joined row 1's first round with four queued: two rounds queued now.
            for owner in owners {
                #expect(owner.lanes[0]!.accepted.count == 8 && owner.lanes[1]!.accepted.count == 4)
                #expect(owner.widths == [1, 2])
            }
            for owner in owners {
                let lane = owner.lanes[0]!
                try owner.executor.retire(lane, reason: .clientStop, selected: owner.tokens[0]!.count, last: owner.tokens[0]!.last)
                try owner.executor.confirmedRetirement(lane, clean: true)
                #expect(lane.isClosed && lane.accepted.isEmpty && !owner.host.isDrained)
            }
            while owners[0].tokens[1]!.count < outputs { try step(owners, rows: [1]) }
            let run = try finish(owners, row: 1)
            #expect(run == solo)
            for owner in owners {
                #expect(owner.host.isDrained && owner.host.backend.bytesReserved == 0 && owner.released.count == 2)
            }
        }
    }

    /// A cohort's proposals through one head call per draft step: the same
    /// drafts (hence the same MTP statistics), tokens and final native state
    /// per row as each row drafting alone, with two collectives per draft step
    /// for the whole cohort instead of two per row.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_MTP_GPU"] == "1"))
    func batchedCohortDraftsMatchRowByRowDraftsWithOneHeadCallPerStep() throws {
        try Device.withDefaultDevice(.gpu) {
            for capacity in [2, 4, 8] {
                let outputs = 26
                var runs: [Bool: (rows: [RowRun], reductions: Int, rounds: Int)] = [:]
                for batched in [false, true] {
                    let (owners, wire) = try pair(capacity: capacity, cohort: true, head: .twoChoice, batchesDrafts: batched)
                    defer { for owner in owners { for lane in owner.lanes.values where !lane.isClosed {
                        try? owner.executor.retire(lane, reason: nil, selected: 0, last: nil)
                    } } }
                    for row in 0..<capacity { try open(owners, row: row, outputs: outputs, zeroTokens: false) }
                    let opened = wire.reductions
                    var runsByRow = [RowRun?](repeating: nil, count: capacity)
                    while runsByRow.contains(where: { $0 == nil }) {
                        let rows = (0..<capacity).filter { runsByRow[$0] == nil }
                        try step(owners, rows: rows)
                        for row in rows where owners[0].tokens[row]!.count == outputs { runsByRow[row] = try finish(owners, row: row) }
                    }
                    for owner in owners { #expect(owner.host.isDrained && owner.host.backend.bytesReserved == 0) }
                    runs[batched] = (runsByRow.map { $0! }, wire.reductions - opened, owners[0].widths.count)
                    print("darkbloom-cohort-draft-test capacity=\(capacity) batched=\(batched) reductions=\(wire.reductions - opened)"
                        + " native_calls=\(owners[0].widths.count) widths=\(owners[0].widths.map(String.init).joined(separator: ","))")
                }
                let alone = try #require(runs[false]), together = try #require(runs[true])
                #expect(together.rows == alone.rows, "capacity \(capacity): batched drafts changed a row")
                #expect(together.rounds == alone.rounds)
                #expect(together.reductions < alone.reductions)
            }
        }
    }
}
