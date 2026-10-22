import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import Testing
@testable import DarkbloomClusterRuntime

// A tiny random Nemotron 3.5 (eleven blocks of width 64, attention heads of 64,
// the width the paged kernel takes) split into two stages, each on its own
// stage KV host: the attention rows in the paged pool, against the same stages
// on a contiguous host and on per-request storage. Paged against contiguous is
// compared by tokens, as for Qwen (`CBv2PagedBatchSyntheticTests`); the hosted
// contiguous rows equal per-request storage bit for bit.
//
// A contract test on a synthetic model, not a model or hardware result.

@Suite("Paged stage KV on a synthetic Nemotron 3.5 (no artifact)", .serialized)
struct NemotronStagePagedSyntheticTests {
    typealias Fixture = NemotronStageSyntheticTests
    static let hidden = Fixture.hidden, vocabulary = Fixture.vocabulary
    static let prompts: [[Int]] = [
        (0..<21).map { ($0 * 37 + 5) % 96 }, [3, 1, 4, 1, 5, 9, 2, 6], (0..<40).map { ($0 * 11 + 7) % 96 },
    ]
    static let outputs = 8, chunk = 8, maximumTokens = 64

    static func configuration() throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: Fixture.configuration()) as? [String: Any] else {
            throw ProbeError("Nemotron fixture configuration is not an object")
        }
        root["head_dim"] = 64
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    static func stages() throws -> (plan: QwenLayerStagePlan, models: [any LanguageModel]) {
        let configuration = try configuration()
        let complete = try Fixture.completeModel(configuration)
        let plan = try QwenLayerStagePlan(configuration: configuration, ranges: [0..<5, 5..<Fixture.pattern.count])
        return (plan, try (0...1).map { try Fixture.stage(plan, $0, from: complete) })
    }

    static func hosts(_ models: [any LanguageModel], kind: ClusterStageKVBackendKind?) throws -> [CBv2StageKVHost?] {
        try models.map { model in
            try kind.map {
                try CBv2StageKVHost(model: model, kind: $0, lanes: 1, maximumTokensPerRequest: maximumTokens,
                    maximumChunkTokens: chunk)
            }
        }
    }

    static func state(_ plan: QwenLayerStagePlan, _ index: Int, _ model: any LanguageModel, host: CBv2StageKVHost?,
                      promptCount: Int) throws -> CBv2OwnedRequestState {
        let geometry = try CBv2RequestGeometry(model: model, family: .qwen35, feedForwardKind: "dense",
            layerCount: plan.stages[index].layers.count, vocabularySize: vocabulary,
            configurationData: plan.stages[index].constructionConfiguration, maximumTokens: maximumTokens, host: host)
        #expect(geometry.host === host)
        return try CBv2OwnedRequestState(geometry: geometry, promptCount: promptCount, outputCount: outputs)
    }

    static func argmax(_ row: MLXArray) -> Int { Int(argMax(row, axis: -1).item(UInt32.self)) }

    /// Each prompt through both stages, prefilled in chunks, then greedy
    /// decode: the tokens and every logits row.
    static func generate(_ plan: QwenLayerStagePlan, _ models: [any LanguageModel], hosts: [CBv2StageKVHost?])
        throws -> [(tokens: [Int], rows: [[Float]])] {
        try prompts.map { prompt in
            let states = try (0...1).map {
                try state(plan, $0, models[$0], host: hosts[$0], promptCount: prompt.count)
            }
            var frames: [[Int]] = stride(from: 0, to: prompt.count, by: chunk).map {
                Array(prompt[$0..<min(prompt.count, $0 + chunk)])
            }
            let promptFrames = frames.count
            var tokens: [Int] = [], rows: [[Float]] = [], offset = 0, sequence = 0
            while tokens.count < outputs {
                let input = frames[sequence]
                let frame = QwenLayerStageFrame(sequence: sequence, phase: sequence < promptFrames ? .prefill : .decode,
                    tokenOffset: offset, tokenCount: input.count, finalPromptChunk: sequence == promptFrames - 1)
                let ids = MLXArray(input.map(Int32.init)).reshaped([1, input.count])
                let residual = try states[0].run(tokenCount: input.count, check: {}, forward: { caches, evaluation in
                    NemotronStageForward.run(model: models[0] as! NemotronHModel, stageIndex: 0, tokens: ids,
                        residual: nil, caches: caches, evaluation: evaluation, frame: frame)
                }, validateOutput: { _ in })
                let output = try states[1].run(tokenCount: input.count, check: {}, forward: { caches, evaluation in
                    NemotronStageForward.run(model: models[1] as! NemotronHModel, stageIndex: 1, tokens: ids,
                        residual: residual, caches: caches, evaluation: evaluation, frame: frame)
                }, validateOutput: { _ in })
                offset += input.count; sequence += 1
                if sequence >= promptFrames {
                    #expect(output.shape == [1, vocabulary])
                    tokens.append(argmax(output)); rows.append(output.asType(.float32).asArray(Float.self))
                    frames.append([tokens.last!])
                }
            }
            for state in states { try state.retire() }
            return (tokens, rows)
        }
    }

    @Test func pagedStagesGiveTheContiguousTokens() throws {
        let (plan, models) = try Self.stages()
        let paged = try Self.hosts(models, kind: .paged), contiguous = try Self.hosts(models, kind: .contiguous)
        for host in paged {
            let host = try #require(host)
            #expect(host.kind == .paged && host.caches.allSatisfy { $0 is PagedLayerCache })
            #expect(host.kvDType == .float32 && host.lanes == 1)
        }
        let a = try Self.generate(plan, models, hosts: paged)
        let b = try Self.generate(plan, models, hosts: contiguous)
        let legacy = try Self.generate(plan, models, hosts: [nil, nil])
        // Not vacuous: finite rows, tokens that vary.
        #expect(a.allSatisfy { $0.rows.allSatisfy { $0.allSatisfy(\.isFinite) } })
        #expect(Set(a.flatMap(\.tokens)).count > 2)
        let drift = zip(a.flatMap(\.rows), b.flatMap(\.rows)).map { zip($0, $1).map { abs($0 - $1) }.max() ?? 0 }.max() ?? 0
        print("nemotron-paged tokens=\(a.map(\.tokens)) max_abs_logit_diff_vs_contiguous=\(drift)")
        for index in Self.prompts.indices {
            #expect(a[index].tokens == b[index].tokens, "paged and contiguous tokens differ for request \(index)")
            #expect(b[index].tokens == legacy[index].tokens, "hosted contiguous differs from per-request storage")
            #expect(b[index].rows == legacy[index].rows, "hosted contiguous rows must equal per-request storage bit for bit")
        }
        #expect((paged + contiguous).allSatisfy { $0!.isDrained }, "every page and binding returned")
    }

    /// The host serves a Nemotron stage at one lane only (its batched decode
    /// has no Nemotron forward), and a request longer than the host is refused.
    @Test func aNemotronHostIsOneLaneAndBoundsItsRequests() throws {
        let configuration = try Self.configuration()
        let plan = try QwenLayerStagePlan(configuration: configuration, ranges: [0..<5, 5..<Fixture.pattern.count])
        let model = try NemotronStageConstruction.model(plan.stages[0].constructionConfiguration)
        #expect(CBv2StageKVHost.supports(model, lanes: 1))
        #expect(!CBv2StageKVHost.supports(model, lanes: 2))
        let host = try CBv2StageKVHost(model: model, kind: .paged, lanes: 1, maximumTokensPerRequest: 32,
            maximumChunkTokens: Self.chunk)
        #expect(host.layerKinds == (model as! NemotronHModel).cbv2LayerKinds)
        for (index, cache) in host.caches.enumerated() { #expect(cache.layerIndex == index) }
        #expect(throws: (any Error).self) {
            _ = try CBv2RequestGeometry(model: model, family: .qwen35, feedForwardKind: "dense", layerCount: 5,
                vocabularySize: Self.vocabulary, configurationData: plan.stages[0].constructionConfiguration,
                maximumTokens: 33, host: host)
        }
    }
}
