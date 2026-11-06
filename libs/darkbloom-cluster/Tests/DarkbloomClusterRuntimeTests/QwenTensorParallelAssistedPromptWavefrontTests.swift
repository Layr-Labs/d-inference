import Foundation
import MLX
@testable import MLXLLM
import MLXLMCommon
import MLXNN
import Testing
@testable import DarkbloomClusterRuntime

/// An assisted lane's prompt steps merge consecutive frames into the same
/// wavefront an unassisted lane runs (`QwenTensorParallelMTPDecoder.prefill(frames:)`):
/// the target's logits and every attention row are the unassisted wavefront's
/// bytes, the step ends at the assistant's capture frontier, and the assistant
/// takes each frame's rows in order, so its drafts and the tokens are those of
/// one frame a step. Two in-process ranks: attention layers on the CPU
/// (contiguous KV); the 27B's hybrid layout on the GPU (paged KV, opt-in),
/// whose conv and SSM states are compared too.
@Suite(.serialized)
struct QwenTensorParallelAssistedPromptWavefrontTests {
    private typealias Wire = QwenTensorParallelPromptWavefrontTests

    private enum Mode { case unassisted, assistedOneFrame, assistedMerged }

    private struct Outcome: Equatable {
        var logits = Data()
        var rows: [Data] = []
        var steps = 0
        var captured = 0
        var tokens: [Int] = []
        var drafts: [[Int]] = []
        var examined: [Int] = []
        var accepted: [Int] = []
        var assistant: [Data] = []
    }

    private final class Results: @unchecked Sendable {
        var outcomes: [Outcome?] = [nil, nil]
        var failures: [Error?] = [nil, nil]
    }

    private static func bytes(_ a: MLXArray) -> Data { eval(a); return a.asData(access: .copy).data }

    @Test func anAssistedPromptMergesFramesIntoTheUnassistedWavefront() throws { try verify(hybrid: false) }

    /// The 27B's hybrid layout on the GPU, then ten tokens of speculation:
    /// the same drafts, acceptance and tokens as one frame a step.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_MTP_GPU"] == "1"))
    func anAssistedHybridPromptMergesFramesAndSpeculatesAlikeOnGPU() throws { try verify(hybrid: true) }

    private func verify(hybrid: Bool) throws {
        let device = hybrid ? Device.gpu : Device.cpu
        // Emptied before and after: a GPU test's compiled traces would replay on the GPU stream here.
        QwenTensorParallelMTPSessionTests.clearDefaultCompileCache()
        defer { QwenTensorParallelMTPSessionTests.clearDefaultCompileCache() }
        // The random checkpoint is built on `device` too: built outside it, its
        // weights would be drawn on the GPU in the CPU leg.
        let source = Device.withDefaultDevice(device) {
            QwenTensorParallelFixtures.checkpoint(hidden: 256, layers: 4, heads: 4, kvHeads: 2, vocabulary: 256)
        }
        var root = try JSONSerialization.jsonObject(with: source.configuration) as! [String: Any]
        // On the CPU, attention layers only (the Gated DeltaNet prompt kernel and
        // a speculative window's recurrent capture need the GPU); `hybrid` is the 27B's layout.
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
        let config = try JSONDecoder().decode(Qwen35TextConfiguration.self, from: JSONSerialization.data(withJSONObject: text))
        let (models, heads, groups) = try Device.withDefaultDevice(device) { () -> ([QwenTensorParallelModel], [QwenTensorParallelMTPHead], [Wire.Rank]) in
            MLXRandom.seed(817)
            let donor = Qwen35MTPModule(config)
            donor.update(parameters: ModuleParameters.unflattened(donor.parameters().flattened().map {
                ($0.0, $0.1.asType(.bfloat16))
            }))
            quantize(model: donor, groupSize: 64, bits: 4); eval(donor)
            let weights = Dictionary(uniqueKeysWithValues: donor.parameters().flattened())
            let wire = Wire.Rendezvous(), groups = (0..<2).map { Wire.Rank($0, wire) }
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
            return (models, heads, groups)
        }
        // 70 prompt tokens in frames of 16 (16, 16, 16, 16, 6); the assistant captures at 32.
        let profile = try QwenLayerStageGenerationProfile(identifier: "qwen-tp-assisted-wavefront", vocabularySize: 256,
            hiddenSize: 256, activationDType: "bfloat16", maximumPromptTokens: 128, maximumChunkTokens: 16,
            maximumOutputTokens: 16, maximumContextTokens: 256)
        let prompt = (0..<70).map { ($0 * 7 + 3) % 256 }, outputs = 11, captureFrontier = 32

        func run(_ mode: Mode) throws -> [Outcome] {
            let id = UUID(), results = Results()
            let boxes = (models, heads)
            DispatchQueue.concurrentPerform(iterations: 2) { rank in
                Device.withDefaultDevice(device) {
                    do {
                        let model = boxes.0[rank]
                        let request = try QwenLayerStageGenerationRequest(profile: profile, requestID: id,
                            promptTokenIDs: prompt, chunkSize: 16, outputCount: outputs, stopTokenIDs: [])
                        let host = try CBv2StageKVHost(model: model.model, kind: hybrid ? .paged : .contiguous, lanes: 1,
                            maximumTokensPerRequest: 128, maximumChunkTokens: 16)
                        let session = try QwenTensorParallelBatchSession(model: model, configuration: configuration,
                            host: host, request: request)
                        let decoder = mode == .unassisted ? nil : try QwenTensorParallelMTPDecoder(target: session,
                            head: boxes.1[rank], group: groups[rank], depth: 2, captureFrontier: captureFrontier,
                            captureLimitBytes: 64 << 20, allocationBound: { (($0 + 16_383) / 16_384) * 16_384 })
                        var outcome = Outcome(), logits: MLXArray?
                        while session.state.committedTokens < prompt.count {
                            outcome.steps += 1
                            switch mode {
                            case .unassisted:
                                let step = try #require(QwenTensorParallelPromptWavefront.step(
                                    session.promptFrames(limit: QwenTensorParallelPromptWavefront.maximumFrames)))
                                logits = try session.prefill(step: step, check: {}) ?? logits
                            case .assistedOneFrame:
                                logits = try decoder!.prefill(frames: 1, check: {}) ?? logits
                            case .assistedMerged:
                                let frames = session.promptFrames(limit: QwenTensorParallelPromptWavefront.maximumFrames,
                                    frontiers: decoder!.promptStepFrontiers)
                                logits = try decoder!.prefill(frames: frames.count, check: {}) ?? logits
                            }
                        }
                        let last = try #require(logits)
                        outcome.logits = Self.bytes(last)
                        for row in session.state.rows {
                            guard let row else { continue }
                            let snapshot = row.snapshot()
                            outcome.rows += [Self.bytes(snapshot.keys), Self.bytes(snapshot.values)]
                        }
                        let recurrent = session.state.recurrent.confirmedStateSnapshot() ?? [:]
                        for layer in recurrent.keys.sorted() {
                            outcome.rows += [Self.bytes(recurrent[layer]!.conv!), Self.bytes(recurrent[layer]!.ssm!)]
                        }
                        if let decoder {
                            outcome.assistant = decoder.assistantStateArrays.map(Self.bytes)
                        }
                        if let decoder, hybrid {
                            let full = model.gatheredLogits(last); eval(full)
                            let (selection, flags) = model.broadcastChoice(rank == 0 ? argMax(full, axis: -1) : nil, stop: 0)
                            eval(selection, flags)
                            let first = Int(selection.item(Int32.self))
                            try decoder.begin(firstToken: first)
                            outcome.tokens = [first]
                            while outcome.tokens.count < outputs {
                                let round = try decoder.step(lastToken: outcome.tokens.last!,
                                    remaining: outputs - outcome.tokens.count, check: {})
                                outcome.tokens += round.tokens
                                outcome.drafts.append(decoder.lastDraftIDs)
                            }
                            outcome.examined = decoder.statistics.examinedByPosition
                            outcome.accepted = decoder.statistics.acceptedByPosition
                        }
                        if let decoder {
                            try decoder.retire()
                            outcome.captured = try decoder.takeCapturedPrefix()?.committedTokens ?? 0
                        } else {
                            try session.retire()
                        }
                        results.outcomes[rank] = outcome
                    } catch { results.failures[rank] = error }
                }
            }
            for failure in results.failures { if let failure { throw failure } }
            return try results.outcomes.map { try #require($0) }
        }

        let unassisted = try run(.unassisted), oneFrame = try run(.assistedOneFrame), merged = try run(.assistedMerged)
        for rank in 0...1 {
            // The target: the unassisted wavefront's logits and attention rows, bit for bit.
            #expect(merged[rank].logits == unassisted[rank].logits, "rank \(rank): final prompt logits")
            #expect(merged[rank].rows == unassisted[rank].rows && merged[rank].rows.count > 2, "rank \(rank): attention rows and recurrent states")
            // Merged steps: 0..<32 (ending at the capture), then 32..<70; one frame a step takes five.
            #expect(unassisted[rank].steps == 1 && oneFrame[rank].steps == 5 && merged[rank].steps == 2,
                    "rank \(rank): steps \(unassisted[rank].steps) / \(oneFrame[rank].steps) / \(merged[rank].steps)")
            #expect(merged[rank].captured == captureFrontier && oneFrame[rank].captured == captureFrontier)
            // The assistant took the same history: its whole request state and the carried row, bit for bit.
            #expect(merged[rank].assistant == oneFrame[rank].assistant && !merged[rank].assistant.isEmpty, "rank \(rank): assistant state")
            if hybrid {
                // Then the same drafts, acceptance and tokens.
                #expect(merged[rank].tokens == oneFrame[rank].tokens && merged[rank].tokens.count == outputs)
                #expect(merged[rank].drafts == oneFrame[rank].drafts && !merged[rank].drafts.isEmpty)
                #expect(merged[rank].examined == oneFrame[rank].examined && merged[rank].accepted == oneFrame[rank].accepted)
            }
        }
        // Each rank holds its own shard; both select the same tokens.
        #expect(merged[0].tokens == merged[1].tokens && merged[0].steps == merged[1].steps)
    }
}
