import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Testing
@testable import DarkbloomClusterRuntime

@Suite(.serialized)
struct QwenTensorParallelBatchSessionTests {
    private final class Rendezvous: @unchecked Sendable {
        let condition = NSCondition()
        var step = 0, leaving = 0
        var inputs: [Int: [Float]] = [:]
        var shapes: [Int: [Int]] = [:]
        var result: [Float] = []
        func sum(_ array: MLXArray, rank: Int) -> MLXArray {
            let values = array.asArray(Float.self)
            condition.lock()
            while leaving > 0 { condition.wait() }
            let generation = step
            precondition(inputs[rank] == nil)
            inputs[rank] = values; shapes[rank] = array.shape
            if inputs.count == 2 {
                precondition(shapes[0] == shapes[1])
                result = zip(inputs[0]!, inputs[1]!).map(+)
                leaving = 2; condition.broadcast()
            } else {
                let deadline = Date().addingTimeInterval(30)
                while leaving == 0 && step == generation {
                    precondition(condition.wait(until: deadline), "TP rank failed to meet its peer")
                }
            }
            let output = result
            leaving -= 1
            if leaving == 0 { inputs = [:]; shapes = [:]; result = []; step += 1; condition.broadcast() }
            condition.unlock()
            return MLXArray(output, array.shape)
        }
    }
    private final class Rank: QwenTensorParallelReduction, @unchecked Sendable {
        let rank: Int, size = 2
        let shared: Rendezvous
        init(_ rank: Int, _ shared: Rendezvous) { self.rank = rank; self.shared = shared }
        func allSum(_ value: MLXArray) -> MLXArray { shared.sum(value, rank: rank) }
    }
    private final class Owned: @unchecked Sendable {
        let model: QwenTensorParallelModel
        let host: CBv2StageKVHost
        var sessions: [QwenTensorParallelBatchSession] = []
        var output: MLXArray?
        var executor: QwenTensorParallelNativeBatchExecutor<SelectionReservation>?
        var nativeLanes: [QwenTensorParallelNativeBatchLane] = []
        var selected: [Int] = []
        var failure: Error?
        var releaseAttempts = 0, rejectRelease = false
        init(_ model: QwenTensorParallelModel, lanes: Int) throws {
            self.model = model
            host = try CBv2StageKVHost(model: model.model, kind: ProcessInfo.processInfo.environment["QWEN_TP_BATCH_KV"] == "paged" ? .paged : .contiguous,
                lanes: lanes, maximumTokensPerRequest: 256, maximumChunkTokens: 64)
        }
    }
    private struct SelectionReservation: QwenTensorParallelBatchReservation {
        let request: QwenLayerStageGenerationRequest
        let deadline: UInt64 = .max
        var laneStateBytes: Int { 1 }
        var joinable: Bool { true }
    }
    private var device: Device { ProcessInfo.processInfo.environment["QWEN_TP_BATCH_GPU"] == "1" ? .gpu : .cpu }
    /// Each test's own rank threads: in CPU mode a reused worker thread would
    /// replay compiled traces an earlier GPU test recorded (`TensorParallelRankThreads`).
    private let ranks = TensorParallelRankThreads()
    private func parallel(_ owners: [Owned], body: @escaping (Owned) throws -> Void) throws {
        let work = Work(body), device = self.device
        ranks.run { rank in
            Device.withDefaultDevice(device) {
                do { try work.body(owners[rank]) } catch { owners[rank].failure = error }
            }
        }
        for owner in owners { if let error = owner.failure { throw error } }
    }
    private final class Work: @unchecked Sendable {
        let body: (Owned) throws -> Void
        init(_ body: @escaping (Owned) throws -> Void) { self.body = body }
    }
    private func mediaInputs(_ model: QwenTensorParallelModel, row: Int) -> QwenTensorParallelBatchInputs? {
        guard row % 2 == 1 else { return nil }
        return .init(positions: { range in
            // Distinct three-axis request histories, including after lane
            // reorder. These are synthetic features/positions, no tower proof.
            MLXArray((0..<3).flatMap { axis in range.map { Int32($0 + row * (axis + 1)) } })
                .reshaped([3, 1, range.count])
        }, promptEmbedding: { tokens, range in
            let original = model.model.scaledInputEmbeddings(tokens)
            let feature = MLXArray(range.map { Float($0 == 1 ? row : 0) * 0.01 })
                .asType(original.dtype).reshaped([1, range.count, 1])
            return original + feature
        })
    }
    private func bytes(_ a: MLXArray) -> Data { eval(a); return a.asData(access: .copy).data }

    @Test func actualShardsBatchIndependentHistoriesWithoutMultiplyingCollectives() throws {
        try verify(hybrid: false)
    }
    // GatedDelta's production recurrence is Metal-only; no CPU substitute is
    // treated as proof for its recurrent state or kernels.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_BATCH_GPU"] == "1"))
    func actualHybridShardsPreserveAttentionConvAndSSMRows() throws {
        try verify(hybrid: true)
    }
    /// A dense geometry with the 9B's head ratios (four query heads per
    /// key/value head, two linear value heads per key head) batches exactly.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_BATCH_GPU"] == "1"))
    func nineBRatioDenseShardsBatchExactly() throws {
        let fixture = QwenTensorParallelFixtures.checkpoint(hidden: 256, layers: 4, heads: 8, kvHeads: 2,
            vocabulary: 256, linearKeyHeads: 2, linearValueHeads: 4)
        try verifyBatchedRows(configuration: fixture.configuration, tensors: fixture.tensors, hiddenSize: 256,
            recurrentLayers: 3, collectivesPerDecode: 8)
    }
    /// The A3B rows' routed-expert layout, scaled down: each row's router,
    /// shared expert and selected experts keep that row's own arithmetic,
    /// and a cohort's packed expert partials cross in one collective a layer.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_BATCH_GPU"] == "1"))
    func routedExpertShardsBatchExactly() throws {
        let fixture = try QwenTensorParallelFixtures.routedCheckpoint()
        try verifyBatchedRows(configuration: fixture.configuration, tensors: fixture.tensors, hiddenSize: 128,
            recurrentLayers: 2, collectivesPerDecode: 8)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_BATCH_GPU"] == "1"
        && ProcessInfo.processInfo.environment["QWEN_TP_BATCH_KV"] == "paged"))
    func routedExpertCapacityOneAndTwoKeepExactPagedLogitsAndHistory() throws {
        let fixture = try QwenTensorParallelFixtures.routedCheckpoint()
        try verifyCapacityParity(configuration: fixture.configuration, tensors: fixture.tensors,
            hiddenSize: 128, recurrentLayers: 2)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_BATCH_GPU"] == "1"
        && ProcessInfo.processInfo.environment["QWEN_TP_BATCH_KV"] == "paged"))
    func capacityOneAndTwoKeepExactPagedLogitsAndHistory() throws {
        let fixture = QwenTensorParallelFixtures.checkpoint(hidden: 256, layers: 4,
            heads: 4, kvHeads: 2, vocabulary: 256)
        try verifyCapacityParity(configuration: fixture.configuration, tensors: fixture.tensors,
            hiddenSize: 256, recurrentLayers: 3)
    }

    /// One request at capacity one and at capacity two: the same paged
    /// logits, keys, values and recurrent rows on both ranks at every step,
    /// so an owner that widens or narrows serves every row's bytes unchanged.
    private func verifyCapacityParity(configuration fixture: Data, tensors: [(String, MLXArray)],
                                      hiddenSize: Int, recurrentLayers: Int) throws {
        try Device.withDefaultDevice(.gpu) {
            var root = try JSONSerialization.jsonObject(with: fixture) as! [String: Any]
            var text = root["text_config"] as! [String: Any]
            text["max_position_embeddings"] = 4096; root["text_config"] = text
            let configuration = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
            let profile = try QwenLayerStageGenerationProfile(identifier: "qwen-tp-capacity-parity-tiny",
                vocabularySize: 256, hiddenSize: hiddenSize, activationDType: "bfloat16",
                maximumPromptTokens: 128, maximumChunkTokens: 64, maximumOutputTokens: 16, maximumContextTokens: 256)
            func pair(capacity: Int) throws -> [Owned] {
                let wire = Rendezvous()
                return try (0..<2).map { rank in
                    let model = try QwenTensorParallelModel.assemble(configurationData: configuration,
                        role: .shard(rank: rank, size: 2), reduction: Rank(rank, wire)) { _, keep in
                        for (name, value) in tensors { try keep(name, value) }
                    }
                    return try Owned(model, lanes: capacity)
                }
            }
            let singleton = try pair(capacity: 1), wider = try pair(capacity: 2)
            defer { for owner in singleton + wider { for session in owner.sessions { try? session.retire() } } }
            let request = try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(),
                promptTokenIDs: (0..<29).map { ($0 * 17 + 2) % 256 }, chunkSize: 5,
                outputCount: 12, stopTokenIDs: [])
            for owner in singleton + wider {
                owner.sessions = [try .init(model: owner.model, configuration: configuration, host: owner.host, request: request)]
            }
            func compare(_ label: String) throws {
                for rank in 0..<2 {
                    let a = singleton[rank], b = wider[rank]
                    let actual = try #require(a.output), expected = try #require(b.output)
                    #expect(bytes(actual) == bytes(expected), "capacity parity \(label) rank=\(rank)")
                    let x = a.sessions[0], y = b.sessions[0]
                    #expect(x.committedTokens == y.committedTokens)
                    for (left, right) in zip(x.state.rows, y.state.rows) {
                        let l = left!.snapshot(), r = right!.snapshot()
                        #expect(l.offset == r.offset && bytes(l.keys) == bytes(r.keys) && bytes(l.values) == bytes(r.values))
                    }
                    let l = x.state.recurrent.confirmedStateSnapshot() ?? [:], r = y.state.recurrent.confirmedStateSnapshot() ?? [:]
                    #expect(l.keys.sorted() == r.keys.sorted() && l.count == recurrentLayers)
                    for layer in l.keys {
                        #expect(bytes(l[layer]!.conv!) == bytes(r[layer]!.conv!))
                        #expect(bytes(l[layer]!.ssm!) == bytes(r[layer]!.ssm!))
                    }
                }
            }
            while singleton[0].sessions[0].schedule.committedPromptTokens < request.promptCount {
                let final = singleton[0].sessions[0].schedule.committedPromptTokens + request.chunkSize >= request.promptCount
                try parallel(singleton) { $0.output = try $0.sessions[0].prefill(check: {}) }
                try parallel(wider) { $0.output = try $0.sessions[0].prefill(check: {}) }
                if final { try compare("prefill") }
            }
            for step in 0..<8 {
                let token = (step * 13 + 9) % 256
                // The singleton evaluates each step at once; the wider owner
                // submits it layer by layer (the product's decode): same bits.
                try parallel(singleton) { owner in
                    try QwenTensorParallelBatchSession.$layerStride.withValue(0) {
                        owner.output = try QwenTensorParallelBatchSession.decode(owner.sessions, tokens: [token], check: {})
                    }
                }
                try parallel(wider) { $0.output = try QwenTensorParallelBatchSession.decode($0.sessions, tokens: [token], check: {}) }
                try compare("decode-\(step)")
            }
            for owner in singleton + wider {
                try owner.sessions[0].retire()
                #expect(owner.sessions[0].state.isClosed && owner.host.isDrained)
            }
        }
    }

    private func verify(hybrid: Bool) throws {
        let fixture = QwenTensorParallelFixtures.checkpoint(hidden: 256, layers: 4, heads: 4, kvHeads: 2, vocabulary: 256)
        var root = try JSONSerialization.jsonObject(with: fixture.configuration) as! [String: Any]
        var text = root["text_config"] as! [String: Any]
        var tensors = fixture.tensors
        if !hybrid {
            text["full_attention_interval"] = 1
            tensors.removeAll { $0.0.contains(".linear_attn.") }
            let attention = fixture.tensors.filter { $0.0.contains(".layers.3.self_attn.") }
            for layer in 0..<3 {
                tensors += attention.map { ($0.0.replacingOccurrences(of: ".layers.3.", with: ".layers.\(layer)."), $0.1) }
            }
        }
        root["text_config"] = text
        try verifyBatchedRows(configuration: try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]),
            tensors: tensors, hiddenSize: 256, recurrentLayers: hybrid ? 3 : 0, collectivesPerDecode: 8)
    }

    /// Rows decoded alone (the reference pair) and together in a rotating
    /// order (the candidate pair) at widths 2, 4 and 8: every row's logits,
    /// keys, values and recurrent rows equal byte for byte on both ranks, a
    /// departed row's slot restarts cold, and one decode's collectives do not
    /// grow with its width. Odd rows carry request-owned media positions.
    private func verifyBatchedRows(configuration fixture: Data, tensors: [(String, MLXArray)], hiddenSize: Int,
                                   recurrentLayers: Int, collectivesPerDecode: Int) throws {
        try Device.withDefaultDevice(device) {
            var root = try JSONSerialization.jsonObject(with: fixture) as! [String: Any]
            var text = root["text_config"] as! [String: Any]
            text["max_position_embeddings"] = 4096; root["text_config"] = text
            let configuration = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
            let profile = try QwenLayerStageGenerationProfile(identifier: "qwen-tp-native-tiny", vocabularySize: 256,
                hiddenSize: hiddenSize, activationDType: "bfloat16", maximumPromptTokens: 128,
                maximumChunkTokens: 64, maximumOutputTokens: 16, maximumContextTokens: 256)
            for width in [2, 4, 8] {
                let referenceWire = Rendezvous(), candidateWire = Rendezvous()
                func pair(_ wire: Rendezvous) throws -> [Owned] {
                    try (0..<2).map { rank in
                        let model = try QwenTensorParallelModel.assemble(configurationData: configuration,
                            role: .shard(rank: rank, size: 2), reduction: Rank(rank, wire)) { _, keep in
                            for (name, value) in tensors { try keep(name, value) }
                        }
                        return try Owned(model, lanes: width)
                    }
                }
                let reference = try pair(referenceWire), candidate = try pair(candidateWire)
                defer { for owner in reference + candidate { for session in owner.sessions { try? session.retire() } } }
                for row in 0..<width {
                    let request = try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(),
                        promptTokenIDs: (0..<(3 + row * 2)).map { ($0 * 17 + row * 7 + 2) % 256 },
                        chunkSize: 5, outputCount: 12, stopTokenIDs: [])
                    for owner in reference + candidate {
                        owner.sessions.append(try .init(model: owner.model, configuration: configuration,
                            host: owner.host, request: request, inputs: mediaInputs(owner.model, row: row)))
                    }
                    while reference[0].sessions[row].schedule.committedPromptTokens < request.promptCount {
                        try parallel(reference) { $0.output = try $0.sessions[row].prefill(check: {}) }
                        try parallel(candidate) { $0.output = try $0.sessions[row].prefill(check: {}) }
                        for rank in 0..<2 {
                            if let expected = reference[rank].output {
                                #expect(bytes(expected) == bytes(candidate[rank].output!))
                            }
                        }
                    }
                }
                for step in 0..<6 {
                    if step == 3 {
                        // A departed request relinquishes its own storage while
                        // batchmates retain their frontiers. A new request in
                        // that slot starts with a different prompt and no state.
                        let row = width - 1
                        let request = try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(),
                            promptTokenIDs: [31, 17, 7, 43, 2, 5, 19], chunkSize: 5,
                            outputCount: 12, stopTokenIDs: [])
                        for owner in reference + candidate {
                            let retired = owner.sessions[row]
                            try retired.retire()
                            #expect(retired.retired && retired.state.rows.isEmpty)
                            owner.sessions[row] = try .init(model: owner.model, configuration: configuration,
                                host: owner.host, request: request, inputs: mediaInputs(owner.model, row: row))
                            #expect(owner.sessions[row].committedTokens == 0)
                        }
                        while reference[0].sessions[row].schedule.committedPromptTokens < request.promptCount {
                            try parallel(reference) { $0.output = try $0.sessions[row].prefill(check: {}) }
                            try parallel(candidate) { $0.output = try $0.sessions[row].prefill(check: {}) }
                        }
                    }
                    let tokens = (0..<width).map { ($0 * 23 + step * 13 + 9) % 256 }
                    var expected = [[Data]](repeating: [], count: 2)
                    for row in 0..<width {
                        try parallel(reference) { owner in
                            // Alone and in one evaluation; the cohort is submitted layer by layer.
                            try QwenTensorParallelBatchSession.$layerStride.withValue(0) {
                                owner.output = try QwenTensorParallelBatchSession.decode([owner.sessions[row]],
                                    tokens: [tokens[row]], check: {})
                            }
                        }
                        for rank in 0..<2 { expected[rank].append(bytes(reference[rank].output!)) }
                    }
                    let order = (0..<width).map { (step + (step % 2 == 0 ? $0 : width - 1 - $0)) % width }
                    let before = candidateWire.step
                    try parallel(candidate) { owner in
                        owner.output = try QwenTensorParallelBatchSession.decode(order.map { owner.sessions[$0] },
                            tokens: order.map { tokens[$0] }, check: {})
                    }
                    #expect(candidateWire.step - before == collectivesPerDecode,
                        "one collective per row-parallel projection, independent of lane count")
                    for rank in 0..<2 {
                        for (slot, row) in order.enumerated() {
                            let a = reference[rank].sessions[row], b = candidate[rank].sessions[row]
                            #expect(expected[rank][row] == bytes(candidate[rank].output![slot..<slot + 1]),
                                "width=\(width) rank=\(rank) step=\(step) row=\(row) logits")
                            #expect(a.committedTokens == b.committedTokens)
                            for (left, right) in zip(a.state.rows, b.state.rows) {
                                let x = left!.snapshot(), y = right!.snapshot()
                                #expect(x.offset == y.offset && bytes(x.keys) == bytes(y.keys) && bytes(x.values) == bytes(y.values))
                            }
                            let left = a.state.recurrent.confirmedStateSnapshot() ?? [:], right = b.state.recurrent.confirmedStateSnapshot() ?? [:]
                            #expect(left.keys.sorted() == right.keys.sorted())
                            #expect(left.count == recurrentLayers)
                            for layer in left.keys {
                                #expect(bytes(left[layer]!.conv!) == bytes(right[layer]!.conv!))
                                #expect(bytes(left[layer]!.ssm!) == bytes(right[layer]!.ssm!))
                            }
                        }
                    }
                }
                for owner in reference + candidate {
                    for session in owner.sessions { try session.retire(); #expect(session.retired && session.state.isClosed) }
                    #expect(owner.host.isDrained)
                }
            }
        }
    }
    @Test func nativeGreedyTiesAndResourceReleaseFailureRemainExact() throws {
        try verifySelectionBoundary(nonfinite: false)
    }

    @Test func nativeNonfiniteRowsFailBeforeSelection() throws {
        try verifySelectionBoundary(nonfinite: true)
    }

    private func verifySelectionBoundary(nonfinite: Bool) throws {
        try Device.withDefaultDevice(device) {
            let fixture = QwenTensorParallelFixtures.checkpoint(hidden: 256, layers: 4, heads: 4, kvHeads: 2, vocabulary: 256)
            var root = try JSONSerialization.jsonObject(with: fixture.configuration) as! [String: Any]
            var text = root["text_config"] as! [String: Any]
            text["max_position_embeddings"] = 4096; text["full_attention_interval"] = 1; root["text_config"] = text
            var tensors = fixture.tensors.filter { !$0.0.contains(".linear_attn.") }
            let attention = fixture.tensors.filter { $0.0.contains(".layers.3.self_attn.") }
            for layer in 0..<3 { tensors += attention.map { ($0.0.replacingOccurrences(of: ".layers.3.", with: ".layers.\(layer)."), $0.1) } }
            tensors = tensors.map { name, value in
                guard name.hasPrefix("language_model.lm_head."), value.dtype != .uint32 else { return (name, value) }
                return (name, MLXArray.full(value.shape, values: MLXArray(nonfinite ? Float.nan : Float(0)), dtype: value.dtype))
            }
            let configuration = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
            let profile = try QwenLayerStageGenerationProfile(identifier: "qwen27-tp-boundary-tiny", vocabularySize: 256,
                hiddenSize: 256, activationDType: "bfloat16", maximumPromptTokens: 128,
                maximumChunkTokens: 64, maximumOutputTokens: 16, maximumContextTokens: 256)
            let wire = Rendezvous()
            let owners = try (0..<2).map { rank -> Owned in
                let reduction = Rank(rank, wire)
                let model = try QwenTensorParallelModel.assemble(configurationData: configuration,
                    role: .shard(rank: rank, size: 2), reduction: reduction) { _, keep in
                    for (name, value) in tensors { try keep(name, value) }
                }
                let owned = try Owned(model, lanes: 8)
                owned.executor = try .init(model: model, configuration: configuration, host: owned.host, group: reduction,
                    prepare: { _, _ in nil }, completedDecode: { _ in }, completedPrefill: {},
                    releaseResources: { [unowned owned] _ in
                        owned.releaseAttempts += 1
                        if owned.rejectRelease { throw ProbeError("Synthetic host resource still owned") }
                    })
                return owned
            }
            defer { for owner in owners { for lane in owner.nativeLanes { try? lane.session.retire() } } }
            for row in 0..<(nonfinite ? 1 : 8) {
                let request = try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(),
                    promptTokenIDs: [1, 2, row + 3], chunkSize: 5, outputCount: 12, stopTokenIDs: [])
                for owner in owners { owner.nativeLanes.append(try owner.executor!.open(.init(request: request), check: {})) }
                let body: (Owned) throws -> Void = { owner in
                    let lane = owner.nativeLanes[row]
                    owner.selected.append(try owner.executor!.prefill(lane, frame: lane.nextFrame!, check: {})!)
                }
                if nonfinite {
                    #expect(throws: ProbeError.self) { try parallel(owners, body: body) }
                    #expect(owners.allSatisfy { $0.failure != nil && $0.selected.isEmpty })
                } else {
                    try parallel(owners, body: body)
                }
            }
            if !nonfinite {
                // Every local and cross-rank vocabulary logit is zero. Exact
                // scalar TP tie semantics choose the lowest global ID.
                #expect(owners.allSatisfy { $0.selected == [Int](repeating: 0, count: 8) })
                try parallel(owners) { owner in
                    owner.selected = try owner.executor!.decode(Array(owner.nativeLanes.reversed()),
                        tokens: [Int](repeating: 0, count: 8), check: {})
                }
                #expect(owners.allSatisfy { $0.selected == [Int](repeating: 0, count: 8) })
            }
            for owner in owners {
                let lane = owner.nativeLanes[0]
                owner.rejectRelease = true
                #expect(throws: ProbeError.self) { try owner.executor!.retire(lane, reason: nil, selected: 0, last: nil) }
                #expect(lane.session.retired && lane.session.state.isClosed && !lane.isClosed && owner.releaseAttempts == 1)
                owner.rejectRelease = false
                try owner.executor!.retire(lane, reason: nil, selected: 0, last: nil)
                #expect(lane.isClosed && owner.releaseAttempts == 2)
                for rest in owner.nativeLanes.dropFirst() { try owner.executor!.retire(rest, reason: nil, selected: 0, last: nil) }
                #expect(owner.host.isDrained)
            }
        }
    }

    @Test func actualNativeMixedSamplingKeepsSeedsHistoryLogprobsAndRowsIndependent() throws {
        let fixture = QwenTensorParallelFixtures.checkpoint(hidden: 256, layers: 4, heads: 4, kvHeads: 2, vocabulary: 256)
        var root = try JSONSerialization.jsonObject(with: fixture.configuration) as! [String: Any]
        var text = root["text_config"] as! [String: Any]
        text["full_attention_interval"] = 1; root["text_config"] = text
        var tensors = fixture.tensors.filter { !$0.0.contains(".linear_attn.") }
        let attention = fixture.tensors.filter { $0.0.contains(".layers.3.self_attn.") }
        for layer in 0..<3 { tensors += attention.map { ($0.0.replacingOccurrences(of: ".layers.3.", with: ".layers.\(layer)."), $0.1) } }
        try verifyMixedSampling(configuration: try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]),
            tensors: tensors, hiddenSize: 256)
    }

    /// Routed experts on the native executor: greedy, sampled and
    /// logprob rows of one cohort select what each selects alone, on the GPU
    /// (the product backend), as the hybrid fixtures run.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_BATCH_GPU"] == "1"))
    func routedExpertNativeMixedSamplingKeepsRowsIndependent() throws {
        let fixture = try QwenTensorParallelFixtures.routedCheckpoint(fullAttentionInterval: 1)
        try verifyMixedSampling(configuration: fixture.configuration, tensors: fixture.tensors, hiddenSize: 128)
    }

    private func verifyMixedSampling(configuration fixture: Data, tensors: [(String, MLXArray)], hiddenSize: Int) throws {
        try Device.withDefaultDevice(device) {
            var root = try JSONSerialization.jsonObject(with: fixture) as! [String: Any]
            var text = root["text_config"] as! [String: Any]
            text["max_position_embeddings"] = 4096; root["text_config"] = text
            let configuration = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
            let profile = try QwenLayerStageGenerationProfile(identifier: "qwen-tp-selection-tiny", vocabularySize: 256,
                hiddenSize: hiddenSize, activationDType: "bfloat16", maximumPromptTokens: 128,
                maximumChunkTokens: 64, maximumOutputTokens: 16, maximumContextTokens: 256)
            for width in [2, 4, 8] {
                func pair(_ wire: Rendezvous) throws -> [Owned] {
                    try (0..<2).map { rank in
                        let reduction = Rank(rank, wire)
                        let model = try QwenTensorParallelModel.assemble(configurationData: configuration,
                            role: .shard(rank: rank, size: 2), reduction: reduction) { _, keep in
                            for (name, value) in tensors { try keep(name, value) }
                        }
                        let owned = try Owned(model, lanes: width)
                        owned.executor = try .init(model: model, configuration: configuration, host: owned.host, group: reduction,
                            prepare: { _, _ in nil }, completedDecode: { _ in }, completedPrefill: {}, releaseResources: { _ in })
                        return owned
                    }
                }
                let reference = try pair(Rendezvous()), candidate = try pair(Rendezvous())
                defer { for owner in reference + candidate { for lane in owner.nativeLanes { try? lane.session.retire() } } }
                for row in 0..<width {
                    let id = UUID()
                    for owner in reference + candidate {
                        // Every owner and request has its own sampler; no shared
                        // reference RNG can accidentally advance the candidate.
                        let sampling: ClusterWorkerSampling? = row % 3 == 0 ? nil : .init(
                            temperature: row % 3 == 1 ? 0.7 : 0, topP: 0.9, topK: 32, minP: 0.01,
                            repetitionPenalty: 1.1, repetitionContextSize: 12, frequencyPenalty: 0.15,
                            presencePenalty: 0.2, seed: UInt64(77 + row), stream: UInt64(5 * row + 1),
                            logitBias: [.init(tokenID: row + 3, bias: 0.5)], topLogprobs: 5)
                        let request = try QwenLayerStageGenerationRequest(profile: profile, requestID: id,
                            promptTokenIDs: (0..<(3 + row * 2)).map { ($0 * 17 + row * 7 + 2) % 256 },
                            chunkSize: 5, outputCount: 12, stopTokenIDs: [], sampling: sampling)
                        owner.nativeLanes.append(try owner.executor!.open(.init(request: request), check: {}))
                    }
                    while let frame = reference[0].nativeLanes[row].nextFrame, frame.phase == .prefill {
                        for owners in [reference, candidate] {
                            try parallel(owners) { owner in
                                if let token = try owner.executor!.prefill(owner.nativeLanes[row], frame: frame, check: {}) {
                                    owner.selected.append(token)
                                }
                            }
                        }
                    }
                    for rank in 0..<2 { #expect(reference[rank].selected[row] == candidate[rank].selected[row]) }
                    #expect(try reference[0].executor!.takeLogprobs(reference[0].nativeLanes[row])
                        == candidate[0].executor!.takeLogprobs(candidate[0].nativeLanes[row]))
                }
                for step in 0..<6 {
                    var expected = [Int](repeating: 0, count: width)
                    for row in 0..<width {
                        try parallel(reference) { owner in
                            let token = try owner.executor!.decode([owner.nativeLanes[row]], tokens: [owner.selected[row]], check: {})[0]
                            owner.selected[row] = token
                        }
                        expected[row] = reference[0].selected[row]
                        #expect(reference[1].selected[row] == expected[row])
                    }
                    let order = (0..<width).map { (step + width - 1 - $0) % width }
                    try parallel(candidate) { owner in
                        let output = try owner.executor!.decode(order.map { owner.nativeLanes[$0] },
                            tokens: order.map { owner.selected[$0] }, check: {})
                        for (slot, row) in order.enumerated() { owner.selected[row] = output[slot] }
                    }
                    for rank in 0..<2 { #expect(candidate[rank].selected == expected, "width=\(width) step=\(step) rank=\(rank)") }
                    for row in 0..<width {
                        #expect(try reference[0].executor!.takeLogprobs(reference[0].nativeLanes[row])
                            == candidate[0].executor!.takeLogprobs(candidate[0].nativeLanes[row]))
                        #expect(try candidate[0].executor!.takeLogprobs(candidate[0].nativeLanes[row]) == nil)
                    }
                }
                for owner in reference + candidate {
                    for lane in owner.nativeLanes { try owner.executor!.retire(lane, reason: nil, selected: 7, last: nil) }
                    #expect(owner.host.isDrained)
                }
            }
        }
    }

    @Test func warmAttentionPrefixesPreserveMixedHistoriesAndRetirement() throws {
        try verifyWarmPrefixes(hybrid: false)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_BATCH_GPU"] == "1"))
    func warmHybridPrefixesPreserveConvSSMAndMixedPositions() throws {
        try verifyWarmPrefixes(hybrid: true)
    }
    /// The warm-prefix fixture: a tiny dense shard pair, attention-only
    /// unless `hybrid` (then with its linear-attention layers).
    private func warmFixture(hybrid: Bool) throws -> (configuration: Data, tensors: [(String, MLXArray)],
                                                      profile: QwenLayerStageGenerationProfile) {
        let fixture = QwenTensorParallelFixtures.checkpoint(hidden: 256, layers: 4,
            heads: 4, kvHeads: 2, vocabulary: 256)
        var root = try JSONSerialization.jsonObject(with: fixture.configuration) as! [String: Any]
        var text = root["text_config"] as! [String: Any]
        text["max_position_embeddings"] = 4096
        var tensors = fixture.tensors
        if !hybrid {
            text["full_attention_interval"] = 1
            tensors.removeAll { $0.0.contains(".linear_attn.") }
            let attention = fixture.tensors.filter { $0.0.contains(".layers.3.self_attn.") }
            for layer in 0..<3 {
                tensors += attention.map { ($0.0.replacingOccurrences(of: ".layers.3.", with: ".layers.\(layer)."), $0.1) }
            }
        }
        root["text_config"] = text
        let configuration = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        let profile = try QwenLayerStageGenerationProfile(identifier: "qwen-tp-warm-tiny", vocabularySize: 256,
            hiddenSize: 256, activationDType: "bfloat16", maximumPromptTokens: 128,
            maximumChunkTokens: 64, maximumOutputTokens: 16, maximumContextTokens: 256)
        return (configuration, tensors, profile)
    }

    private func verifyWarmPrefixes(hybrid: Bool) throws {
        try Device.withDefaultDevice(device) {
            let (configuration, tensors, profile) = try warmFixture(hybrid: hybrid)
            for width in [2, 4, 8] {
                let coldWire = Rendezvous(), warmWire = Rendezvous()
                let caches = (0..<2).map { _ in QwenTensorParallelBatchPrefixCache(enabled: true, budgetBytes: 64 << 20) }
                func pair(_ wire: Rendezvous, warm: Bool) throws -> [Owned] {
                    try (0..<2).map { rank in
                        let reduction = Rank(rank, wire)
                        let model = try QwenTensorParallelModel.assemble(configurationData: configuration,
                            role: .shard(rank: rank, size: 2), reduction: reduction) { _, keep in
                            for (name, value) in tensors { try keep(name, value) }
                        }
                        let owner = try Owned(model, lanes: width)
                        owner.executor = try .init(model: model, configuration: configuration, host: owner.host,
                            group: reduction, prepare: { reservation, _ in
                                self.mediaInputs(model, row: reservation.request.promptTokenIDs[0] - 10)
                            }, completedDecode: { _ in }, completedPrefill: {}, releaseResources: { _ in },
                            prefix: warm ? caches[rank] : nil,
                            prefixBudget: warm ? .init(maximumTokens: 128, captureBytes: 8 << 20, residentBytes: 64 << 20) : nil,
                            prefixScope: warm ? { _ in "same-authenticated-load-and-media-policy" } : nil,
                            allocationBound: warm ? { (($0 + 16383) / 16384) * 16384 } : nil)
                        return owner
                    }
                }
                let cold = try pair(coldWire, warm: false), warm = try pair(warmWire, warm: true)
                func request(_ row: Int) throws -> QwenLayerStageGenerationRequest {
                    try .init(profile: profile, requestID: UUID(),
                        promptTokenIDs: [row + 10] + (1..<((row == 0 ? 72 : 11) + row * 2)).map { ($0 * 17 + row * 7) % 256 },
                        chunkSize: 5, outputCount: 12, stopTokenIDs: [])
                }
                // Donate only after clean local retirement and the caller's
                // bilateral vote; native page bindings must already be gone.
                for row in 0..<width {
                    let r = try request(row)
                    try parallel(warm) { $0.nativeLanes = [try $0.executor!.open(.init(request: r), check: {})] }
                    while warm[0].nativeLanes[0].nextFrame?.phase == .prefill {
                        try parallel(warm) { owner in
                            let lane = owner.nativeLanes[0]
                            if let token = try owner.executor!.prefill(lane, frame: lane.nextFrame!, check: {}) { owner.selected = [token] }
                        }
                    }
                    for owner in warm {
                        let lane = owner.nativeLanes[0]
                        #expect(throws: (any Error).self) { try lane.session.takeCapturedPrefix() }
                        try owner.executor!.retire(lane, reason: .clientStop, selected: 1, last: owner.selected[0])
                        #expect(owner.host.isDrained)
                    }
                    for owner in warm { try owner.executor!.confirmedRetirement(owner.nativeLanes[0], clean: true) }
                }
                #expect(caches.allSatisfy { $0.bytesInUse > 0 })
                for owner in warm { owner.nativeLanes.removeAll() }
                for row in 0..<width {
                    let r = try request(row)
                    try parallel(cold) { $0.nativeLanes.append(try $0.executor!.open(.init(request: r), check: {})) }
                    try parallel(warm) { $0.nativeLanes.append(try $0.executor!.open(.init(request: r), check: {})) }
                    #expect(warm.allSatisfy { $0.nativeLanes[row].committedTokens == (r.promptCount - 1) / 5 * 5 })
                    for pair in [cold, warm] {
                        while pair[0].nativeLanes[row].nextFrame?.phase == .prefill {
                            try parallel(pair) { owner in
                                let lane = owner.nativeLanes[row]
                                owner.output = try lane.session.prefill(check: {})
                            }
                        }
                    }
                    for rank in 0..<2 { #expect(bytes(cold[rank].output!) == bytes(warm[rank].output!)) }
                }
                for step in 0..<4 {
                    let order = (0..<width).map { (step + width - 1 - $0) % width }
                    let tokens = order.map { ($0 * 11 + step * 7 + 3) % 256 }
                    for pair in [cold, warm] {
                        try parallel(pair) { owner in
                            owner.output = try QwenTensorParallelBatchSession.decode(order.map { owner.nativeLanes[$0].session },
                                tokens: tokens, check: {})
                        }
                    }
                    for rank in 0..<2 {
                        #expect(bytes(cold[rank].output!) == bytes(warm[rank].output!), "warm width=\(width) step=\(step) rank=\(rank)")
                        for row in 0..<width {
                            let a = cold[rank].nativeLanes[row].session.state, b = warm[rank].nativeLanes[row].session.state
                            #expect(a.committedTokens == b.committedTokens)
                            for (x, y) in zip(a.rows, b.rows) {
                                #expect(bytes(x!.snapshot().keys) == bytes(y!.snapshot().keys))
                                #expect(bytes(x!.snapshot().values) == bytes(y!.snapshot().values))
                            }
                            let x = a.recurrent.confirmedStateSnapshot() ?? [:], y = b.recurrent.confirmedStateSnapshot() ?? [:]
                            #expect(x.keys.sorted() == y.keys.sorted())
                            for index in x.keys {
                                #expect(bytes(x[index]!.conv!) == bytes(y[index]!.conv!))
                                #expect(bytes(x[index]!.ssm!) == bytes(y[index]!.ssm!))
                            }
                        }
                    }
                }
                for owner in cold + warm {
                    for lane in owner.nativeLanes { try owner.executor!.retire(lane, reason: nil, selected: 0, last: nil) }
                    owner.nativeLanes.removeAll(); #expect(owner.host.isDrained)
                }
                // A one-sided cache loss must produce a bilateral cold miss.
                caches[0].sweep()
                let r = try request(0)
                try parallel(warm) { $0.nativeLanes = [try $0.executor!.open(.init(request: r), check: {})] }
                #expect(warm.allSatisfy { $0.nativeLanes[0].committedTokens == 0 })
                for owner in warm { try owner.executor!.retire(owner.nativeLanes[0], reason: nil, selected: 0, last: nil) }
                for cache in caches { cache.sweep(); #expect(cache.bytesInUse == 0) }
            }
        }
    }

    @Test func ssdAttentionPrefixesRestoreAfterTheTiersReopen() throws {
        try verifySSDPrefixes(hybrid: false)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_BATCH_GPU"] == "1"))
    func ssdHybridPrefixesRestoreConvSSMAfterTheTiersReopen() throws {
        try verifySSDPrefixes(hybrid: true)
    }
    /// A request's prefix partition on both tiers, through the owner's own
    /// scope rule (`QwenTensorParallelResidentRuntime.batchPrefixScope`): a
    /// tenant's prompt is restored by that tenant alone, from the resident
    /// tier and, once that is gone, from the SSD, never by another tenant or
    /// a request without one, though each holds the same prompt; a request
    /// whose cache is off votes nothing, keeps nothing and writes nothing.
    /// Every request selects the cold pair's first token.
    @Test func partitionedPrefixesNeverCrossTenantsAndADisabledRequestKeepsNothing() throws {
        try Device.withDefaultDevice(device) {
            let (configuration, tensors, profile) = try warmFixture(hybrid: false)
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("qwen-tp-tenant-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let key = Data((0..<32).map { UInt8(($0 * 29 + 5) % 256) })
            var settings = QwenStagePrefixDiskConfiguration(mode: .on(root: root, key: key))
            settings.minimumTokens = 1
            settings.minimumFreeBytes = 1 << 20
            let planScope = "qwen-tp-tenant-tiny|shares=1:1", load = UUID().uuidString
            let disks = try (0..<2).map { rank in
                QwenTensorParallelPrefixDisk(tier: try QwenStagePrefixDiskTier(configuration: settings, root: root, key: key,
                    planScope: planScope, rank: rank), planScope: planScope)
            }
            defer { for disk in disks { disk.tier.close() } }
            let caches = (0..<2).map { _ in QwenTensorParallelBatchPrefixCache(enabled: true, budgetBytes: 64 << 20) }
            func pair(warm: Bool) throws -> [Owned] {
                let wire = Rendezvous()
                return try (0..<2).map { rank in
                    let reduction = Rank(rank, wire)
                    let model = try QwenTensorParallelModel.assemble(configurationData: configuration,
                        role: .shard(rank: rank, size: 2), reduction: reduction) { _, keep in
                        for (name, value) in tensors { try keep(name, value) }
                    }
                    let owner = try Owned(model, lanes: 1), kind = owner.host.kind
                    func suffix(_ reservation: SelectionReservation) -> String? {
                        QwenTensorParallelResidentRuntime.batchPrefixScope(reservation.request, kind: kind, mediaIdentity: nil)
                    }
                    owner.executor = try .init(model: model, configuration: configuration, host: owner.host,
                        group: reduction, prepare: { _, _ in nil }, completedDecode: { _ in }, completedPrefill: {},
                        releaseResources: { _ in }, prefix: warm ? caches[rank] : nil,
                        prefixBudget: warm ? .init(maximumTokens: 128, captureBytes: 8 << 20, residentBytes: 64 << 20) : nil,
                        prefixScope: warm ? { reservation in suffix(reservation).map { load + "|" + $0 } } : nil,
                        prefixDisk: warm ? disks[rank] : nil,
                        prefixDiskScope: warm ? { reservation in suffix(reservation).map(disks[rank].scope) } : nil,
                        allocationBound: warm ? { (($0 + 16383) / 16384) * 16384 } : nil)
                    return owner
                }
            }
            let prompt = [10] + (1..<72).map { ($0 * 17) % 256 }, frontier = (prompt.count - 1) / 5 * 5
            /// Opens, prefills and cleanly retires one request: what each rank
            /// restored at open, what it stored, and the first selected token.
            func serve(_ owners: [Owned], _ partition: ClusterWorkerPrefixCache?) throws
                -> (restored: [Int], stored: [[Int]], token: Int) {
                let request = try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(),
                    promptTokenIDs: prompt, chunkSize: 5, outputCount: 12, stopTokenIDs: [], prefixCache: partition)
                try parallel(owners) { $0.nativeLanes = [try $0.executor!.open(.init(request: request), check: {})] }
                let restored = owners.map { $0.nativeLanes[0].committedTokens }
                while owners[0].nativeLanes[0].nextFrame?.phase == .prefill {
                    try parallel(owners) { owner in
                        let lane = owner.nativeLanes[0]
                        if let token = try owner.executor!.prefill(lane, frame: lane.nextFrame!, check: {}) { owner.selected = [token] }
                    }
                }
                for owner in owners {
                    try owner.executor!.retire(owner.nativeLanes[0], reason: .clientStop, selected: 1, last: owner.selected[0])
                }
                for owner in owners { try owner.executor!.confirmedRetirement(owner.nativeLanes[0], clean: true) }
                #expect(owners[0].selected == owners[1].selected && owners.allSatisfy { $0.host.isDrained })
                return (restored, owners.map { $0.nativeLanes[0].storedPrefixFrontiers }, owners[0].selected[0])
            }
            func drained() -> [Int] {
                disks.map { disk in
                    #expect(disk.tier.drain(timeoutSeconds: 60))
                    return disk.tier.recordCount
                }
            }
            let tenantA = ClusterWorkerPrefixCache.tenant(ClusterWorkerPrefixCache.tenantDigest(salt: "tenant-a"))
            let tenantB = ClusterWorkerPrefixCache.tenant(ClusterWorkerPrefixCache.tenantDigest(salt: "tenant-b"))
            let tenantC = ClusterWorkerPrefixCache.tenant(ClusterWorkerPrefixCache.tenantDigest(salt: "tenant-c"))
            let expected = try serve(pair(warm: false), nil).token
            let warm = try pair(warm: true)
            // Tenant A's capture is kept on both tiers.
            let first = try serve(warm, tenantA)
            #expect(first.restored == [0, 0] && first.stored == [[frontier], [frontier]] && first.token == expected)
            #expect(drained() == [1, 1])
            // Another tenant, and a request without one, find nothing of it; each keeps its own.
            for (partition, records) in [(tenantB, [2, 2]), (nil, [3, 3])] as [(ClusterWorkerPrefixCache?, [Int])] {
                let other = try serve(warm, partition)
                #expect(other.restored == [0, 0] && other.stored == [[frontier], [frontier]] && other.token == expected)
                #expect(drained() == records)
            }
            // A request whose cache is off restores, keeps and writes nothing.
            let resident = caches.map(\.bytesInUse), persisted = disks.map(\.tier.stats.persisted)
            let off = try serve(warm, .disabled)
            #expect(off.restored == [0, 0] && off.stored == [[], []] && off.token == expected)
            #expect(caches.map(\.bytesInUse) == resident && drained() == [3, 3] && disks.map(\.tier.stats.persisted) == persisted)
            // The same tenant still hits, resident.
            let again = try serve(warm, tenantA)
            #expect(again.restored == [frontier, frontier] && again.token == expected)
            // Without the resident tier: a new tenant finds none of the three
            // records of its prompt; tenant A restores its own from the SSD;
            // a request whose cache is off reads nothing.
            for cache in caches { cache.sweep() }
            let restores = disks.map(\.tier.stats.restores)
            let stranger = try serve(warm, tenantC)
            #expect(stranger.restored == [0, 0] && stranger.token == expected)
            #expect(disks.map(\.tier.stats.restores) == restores)
            for cache in caches { cache.sweep() }
            let quiet = try serve(warm, .disabled)
            #expect(quiet.restored == [0, 0] && quiet.stored == [[], []] && disks.map(\.tier.stats.restores) == restores)
            let fromDisk = try serve(warm, tenantA)
            #expect(fromDisk.restored == [frontier, frontier] && fromDisk.token == expected)
            #expect(zip(disks.map(\.tier.stats.restores), restores).allSatisfy { $0 == $1 + 1 })
        }
    }

    /// The SSD tier across a restart: records written behind a cleanly
    /// retired pair are offered by reopened tiers to a new pair with empty
    /// resident tiers, restored on both ranks bit-exactly against a cold
    /// prefill, and promoted to the resident tier; a record one rank cannot
    /// read after offering it makes both ranks prefill from zero.
    private func verifySSDPrefixes(hybrid: Bool) throws {
        try Device.withDefaultDevice(device) {
            let (configuration, tensors, profile) = try warmFixture(hybrid: hybrid)
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("qwen-tp-ssd-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let key = Data((0..<32).map { UInt8(($0 * 37 + 11) % 256) })
            var settings = QwenStagePrefixDiskConfiguration(mode: .on(root: root, key: key))
            settings.minimumTokens = 1
            settings.minimumFreeBytes = 1 << 20
            let planScope = "qwen-tp-ssd-tiny|shares=1:1"
            func tiers() throws -> [QwenTensorParallelPrefixDisk] {
                try (0..<2).map { rank in
                    .init(tier: try QwenStagePrefixDiskTier(configuration: settings, root: root, key: key,
                        planScope: planScope, rank: rank), planScope: planScope)
                }
            }
            let width = 3
            func pair(_ wire: Rendezvous, caches: [QwenTensorParallelBatchPrefixCache]?,
                      disks: [QwenTensorParallelPrefixDisk]?) throws -> [Owned] {
                // Each load has its own resident scope (its load agreement);
                // the SSD scope outlives it.
                let load = UUID().uuidString
                return try (0..<2).map { rank in
                    let reduction = Rank(rank, wire)
                    let model = try QwenTensorParallelModel.assemble(configurationData: configuration,
                        role: .shard(rank: rank, size: 2), reduction: reduction) { _, keep in
                        for (name, value) in tensors { try keep(name, value) }
                    }
                    let owner = try Owned(model, lanes: width)
                    let warm = caches != nil
                    owner.executor = try .init(model: model, configuration: configuration, host: owner.host,
                        group: reduction, prepare: { reservation, _ in
                            self.mediaInputs(model, row: reservation.request.promptTokenIDs[0] - 10)
                        }, completedDecode: { _ in }, completedPrefill: {}, releaseResources: { _ in },
                        prefix: caches?[rank],
                        prefixBudget: warm ? .init(maximumTokens: 128, captureBytes: 8 << 20, residentBytes: 64 << 20) : nil,
                        prefixScope: warm ? { _ in load } : nil,
                        prefixDisk: disks?[rank], prefixDiskScope: disks == nil ? nil : { _ in planScope + "|chunk=5|text" },
                        allocationBound: warm ? { (($0 + 16383) / 16384) * 16384 } : nil)
                    return owner
                }
            }
            func request(_ row: Int) throws -> QwenLayerStageGenerationRequest {
                try .init(profile: profile, requestID: UUID(),
                    promptTokenIDs: [row + 10] + (1..<((row == 0 ? 72 : 11) + row * 2)).map { ($0 * 17 + row * 7) % 256 },
                    chunkSize: 5, outputCount: 12, stopTokenIDs: [])
            }
            func prefill(_ owners: [Owned], row: Int) throws {
                while owners[0].nativeLanes[row].nextFrame?.phase == .prefill {
                    try parallel(owners) { owner in owner.output = try owner.nativeLanes[row].session.prefill(check: {}) }
                }
            }
            // The first pair stores every prompt, resident and written behind.
            let first = try tiers()
            let stored = (0..<2).map { _ in QwenTensorParallelBatchPrefixCache(enabled: true, budgetBytes: 64 << 20) }
            let writer = try pair(Rendezvous(), caches: stored, disks: first)
            for row in 0..<width {
                let r = try request(row)
                try parallel(writer) { $0.nativeLanes = [try $0.executor!.open(.init(request: r), check: {})] }
                while writer[0].nativeLanes[0].nextFrame?.phase == .prefill {
                    try parallel(writer) { owner in
                        let lane = owner.nativeLanes[0]
                        if let token = try owner.executor!.prefill(lane, frame: lane.nextFrame!, check: {}) { owner.selected = [token] }
                    }
                }
                for owner in writer {
                    try owner.executor!.retire(owner.nativeLanes[0], reason: .clientStop, selected: 1, last: owner.selected[0])
                }
                for owner in writer { try owner.executor!.confirmedRetirement(owner.nativeLanes[0], clean: true) }
                #expect(writer.allSatisfy { $0.nativeLanes[0].storedPrefixFrontiers == [(r.promptCount - 1) / 5 * 5] })
            }
            for disk in first {
                #expect(disk.tier.drain(timeoutSeconds: 60))
                #expect(disk.tier.recordCount == width && disk.tier.stats.persisted == width)
                disk.tier.close()
            }
            // A restarted pair: empty resident tiers, reopened SSD tiers.
            let second = try tiers()
            #expect(second.allSatisfy { $0.tier.recordCount == width })
            let resident = (0..<2).map { _ in QwenTensorParallelBatchPrefixCache(enabled: true, budgetBytes: 64 << 20) }
            let cold = try pair(Rendezvous(), caches: nil, disks: nil)
            let warm = try pair(Rendezvous(), caches: resident, disks: second)
            for row in 0..<width {
                let r = try request(row)
                try parallel(cold) { $0.nativeLanes.append(try $0.executor!.open(.init(request: r), check: {})) }
                try parallel(warm) { $0.nativeLanes.append(try $0.executor!.open(.init(request: r), check: {})) }
                #expect(warm.allSatisfy { $0.nativeLanes[row].committedTokens == (r.promptCount - 1) / 5 * 5 })
                #expect(cold.allSatisfy { $0.nativeLanes[row].committedTokens == 0 })
                try prefill(cold, row: row); try prefill(warm, row: row)
                for rank in 0..<2 { #expect(bytes(cold[rank].output!) == bytes(warm[rank].output!), "ssd row=\(row) rank=\(rank)") }
            }
            #expect(second.allSatisfy { $0.tier.stats.restores == width })
            #expect(resident.allSatisfy { $0.bytesInUse > 0 })
            for step in 0..<4 {
                let order = (0..<width).map { (step + width - 1 - $0) % width }
                let tokens = order.map { ($0 * 11 + step * 7 + 3) % 256 }
                for pair in [cold, warm] {
                    try parallel(pair) { owner in
                        owner.output = try QwenTensorParallelBatchSession.decode(order.map { owner.nativeLanes[$0].session },
                            tokens: tokens, check: {})
                    }
                }
                for rank in 0..<2 {
                    #expect(bytes(cold[rank].output!) == bytes(warm[rank].output!), "ssd step=\(step) rank=\(rank)")
                    for row in 0..<width {
                        let a = cold[rank].nativeLanes[row].session.state, b = warm[rank].nativeLanes[row].session.state
                        #expect(a.committedTokens == b.committedTokens)
                        for (x, y) in zip(a.rows, b.rows) {
                            #expect(bytes(x!.snapshot().keys) == bytes(y!.snapshot().keys))
                            #expect(bytes(x!.snapshot().values) == bytes(y!.snapshot().values))
                        }
                        let x = a.recurrent.confirmedStateSnapshot() ?? [:], y = b.recurrent.confirmedStateSnapshot() ?? [:]
                        #expect(x.keys.sorted() == y.keys.sorted())
                        for index in x.keys {
                            #expect(bytes(x[index]!.conv!) == bytes(y[index]!.conv!))
                            #expect(bytes(x[index]!.ssm!) == bytes(y[index]!.ssm!))
                        }
                    }
                }
            }
            for owner in cold + warm {
                for lane in owner.nativeLanes { try owner.executor!.retire(lane, reason: nil, selected: 0, last: nil) }
                owner.nativeLanes.removeAll(); #expect(owner.host.isDrained)
            }
            for disk in second { disk.tier.close() }
            // Offered, then unreadable on rank 0 (its records' wrapped keys
            // damaged after the index loaded): both ranks prefill from zero,
            // and rank 1 keeps the state it read in its resident tier.
            let third = try tiers()
            let rankZero = root.appendingPathComponent(QwenStagePrefixDiskTier.planDirectoryName(scope: planScope))
                .appendingPathComponent("rank0")
            for name in try FileManager.default.contentsOfDirectory(atPath: rankZero.path) where name.hasSuffix(".dbpx") {
                let handle = try FileHandle(forUpdating: rankZero.appendingPathComponent(name))
                try handle.seek(toOffset: 20)
                let byte = try #require(try handle.read(upToCount: 1))
                try handle.seek(toOffset: 20); try handle.write(contentsOf: Data([byte[0] ^ 0xFF])); try handle.close()
            }
            let declined = (0..<2).map { _ in QwenTensorParallelBatchPrefixCache(enabled: true, budgetBytes: 64 << 20) }
            let lossy = try pair(Rendezvous(), caches: declined, disks: third)
            let r = try request(0)
            try parallel(lossy) { $0.nativeLanes = [try $0.executor!.open(.init(request: r), check: {})] }
            #expect(lossy.allSatisfy { $0.nativeLanes[0].committedTokens == 0 })
            #expect(declined[0].bytesInUse == 0 && declined[1].bytesInUse > 0)
            #expect(third[0].tier.stats.failedRestores == 1 && third[1].tier.stats.restores == 1)
            #expect(third[0].tier.recordCount == width - 1)
            for owner in lossy { try owner.executor!.retire(owner.nativeLanes[0], reason: nil, selected: 0, last: nil) }
            for disk in third { disk.tier.close() }
        }
    }
}
