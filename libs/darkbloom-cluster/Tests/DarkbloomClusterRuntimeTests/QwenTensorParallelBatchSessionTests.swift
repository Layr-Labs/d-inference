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
    private func parallel(_ owners: [Owned], body: @escaping (Owned) throws -> Void) throws {
        let work = Work(body)
        DispatchQueue.concurrentPerform(iterations: 2) { rank in
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
    private func verify(hybrid: Bool) throws {
        try Device.withDefaultDevice(device) {
            let fixture = QwenTensorParallelPagedKVTests.checkpoint(hidden: 256, layers: 4, heads: 4, kvHeads: 2, vocabulary: 256)
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
            let profile = try QwenLayerStageGenerationProfile(identifier: "qwen27-tp-native-tiny", vocabularySize: 256,
                hiddenSize: 256, activationDType: "bfloat16", maximumPromptTokens: 128,
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
                        try parallel(reference) {
                            $0.output = try QwenTensorParallelBatchSession.decode([$0.sessions[row]], tokens: [tokens[row]], check: {})
                        }
                        for rank in 0..<2 { expected[rank].append(bytes(reference[rank].output!)) }
                    }
                    let order = (0..<width).map { (step + (step % 2 == 0 ? $0 : width - 1 - $0)) % width }
                    let before = candidateWire.step
                    try parallel(candidate) { owner in
                        owner.output = try QwenTensorParallelBatchSession.decode(order.map { owner.sessions[$0] },
                            tokens: order.map { tokens[$0] }, check: {})
                    }
                    #expect(candidateWire.step - before == 8, "one collective per row-parallel projection, independent of lane count")
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
                            #expect(left.count == (hybrid ? 3 : 0))
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
            let fixture = QwenTensorParallelPagedKVTests.checkpoint(hidden: 256, layers: 4, heads: 4, kvHeads: 2, vocabulary: 256)
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
        try Device.withDefaultDevice(device) {
            let fixture = QwenTensorParallelPagedKVTests.checkpoint(hidden: 256, layers: 4, heads: 4, kvHeads: 2, vocabulary: 256)
            var root = try JSONSerialization.jsonObject(with: fixture.configuration) as! [String: Any]
            var text = root["text_config"] as! [String: Any]
            text["max_position_embeddings"] = 4096; text["full_attention_interval"] = 1; root["text_config"] = text
            var tensors = fixture.tensors.filter { !$0.0.contains(".linear_attn.") }
            let attention = fixture.tensors.filter { $0.0.contains(".layers.3.self_attn.") }
            for layer in 0..<3 { tensors += attention.map { ($0.0.replacingOccurrences(of: ".layers.3.", with: ".layers.\(layer)."), $0.1) } }
            let configuration = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
            let profile = try QwenLayerStageGenerationProfile(identifier: "qwen27-tp-selection-tiny", vocabularySize: 256,
                hiddenSize: 256, activationDType: "bfloat16", maximumPromptTokens: 128,
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

}
