import DarkbloomClusterProtocol
import Foundation
import MLX
@testable import MLXLLM
import MLXLMCommon
import MLXNN
import Testing
@testable import DarkbloomClusterRuntime

/// A round's later draft steps for several requests in one assistant forward
/// (`Qwen35InlineMTPAssistant.draftHiddens` with the exact draft projections,
/// `QwenTensorParallelMTPDecoder.exactDraftProjection`): every row's hidden is
/// byte-equal to the same request's step taken alone, for two to eight rows,
/// over histories of different lengths, at the suites' geometry and at the 9B's
/// head ratio, and over two consecutive later steps (a depth-three round).
@Suite(.serialized)
struct QwenTensorParallelExactDraftRowsTests {
    private func fixtureHead(heads: Int) throws -> QwenTensorParallelMTPHead {
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
        let parameters = donor.parameters().flattened().sorted { $0.0 < $1.0 }.enumerated().map { index, entry in
            let (name, value) = entry
            let array = name.contains("norm") ? MLXArray.ones(value.shape, dtype: .bfloat16)
                : MLXArray((0..<value.size).map { Float(($0 * 13 + index * 7) % 31 - 15) / 128 })
                    .reshaped(value.shape).asType(.bfloat16)
            return (name, array)
        }
        donor.update(parameters: ModuleParameters.unflattened(parameters))
        quantize(model: donor, groupSize: 64, bits: 4); eval(donor)
        let weights = Dictionary(uniqueKeysWithValues: donor.parameters().flattened())
        let reduction = QwenTensorParallelLocalReduction(rank: 0, size: 2)
        let model = try QwenTensorParallelModel.assemble(configurationData: configuration,
            role: .shard(rank: 0, size: 2), reduction: reduction) { _, keep in
            for (name, value) in checkpoint.tensors { try keep(name, value) }
        }
        return try QwenTensorParallelMTPHead(model: model, configuration: configuration,
            indexedWeights: weights, reduction: reduction)
    }

    private func random(_ shape: [Int], seed: UInt64) -> MLXArray {
        withRandomState(MLXRandom.RandomState(seed: seed)) { (MLXRandom.normal(shape) * 0.5).asType(.bfloat16) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_MTP_GPU"] == "1"))
    func laterDraftStepsForManyRowsEqualEachRowAlone() throws {
        try Device.withDefaultDevice(.gpu) {
            for heads in [4, 8] {
                let head = try fixtureHead(heads: heads)
                let assistant = head.assistant
                #expect(assistant.draftsRowsTogether)
                for rows in [2, 4, 6, 8] {
                    // Two identical sets of requests: one steps together, one alone.
                    // Row r observes its own committed history (2 + r % 3 rows),
                    // then its round's first step runs alone, as a cohort's does.
                    func started() throws -> (states: [any CBv2MTPRequestState], tokens: [MLXArray], hiddens: [MLXArray]) {
                        var states: [any CBv2MTPRequestState] = [], tokens: [MLXArray] = [], hiddens: [MLXArray] = []
                        for row in 0..<rows {
                            let state = try assistant.makePagedRequestState(maximumSequenceLength: 128)
                            let length = 2 + row % 3, seed = UInt64(1000 * heads + 37 * row)
                            let history = MLXArray((0..<length).map { Int32((row * 11 + $0 * 5 + 3) % 256) }).reshaped([1, length])
                            assistant.observeCommittedTarget(.init(tokens: history,
                                hidden: random([1, length, 256], seed: seed)), requestState: state)
                            let carry = MLXArray([Int32((row * 17 + 9) % 256)]).reshaped([1, 1])
                            let first = assistant.draftHidden(tokens: carry, hidden: random([1, 1, 256], seed: seed + 1),
                                requestState: state)
                            let draft = MLXArray([Int32((row * 29 + 4) % 256)])
                            assistant.recordDraft(lastHidden: first, draft: draft, requestState: state)
                            eval([first] + assistant.evaluationTargets(for: state))
                            states.append(state); tokens.append(draft.reshaped([1, 1])); hiddens.append(first)
                        }
                        return (states, tokens, hiddens)
                    }
                    let together = try started(), alone = try started()
                    var feedsTogether = (tokens: together.tokens, hiddens: together.hiddens)
                    var feedsAlone = (tokens: alone.tokens, hiddens: alone.hiddens)
                    for step in 1...2 {
                        let joint = assistant.draftHiddens(tokens: feedsTogether.tokens, hiddens: feedsTogether.hiddens,
                            requestStates: together.states, project: QwenTensorParallelMTPDecoder.exactDraftProjection)
                        let single = (0..<rows).map { row in
                            assistant.draftHiddens(tokens: [feedsAlone.tokens[row]], hiddens: [feedsAlone.hiddens[row]],
                                requestStates: [alone.states[row]], project: QwenTensorParallelMTPDecoder.exactDraftProjection)
                        }
                        eval([joint] + single + together.states.flatMap { assistant.evaluationTargets(for: $0) }
                            + alone.states.flatMap { assistant.evaluationTargets(for: $0) })
                        #expect(joint.shape == [rows, 1, 256])
                        for row in 0..<rows {
                            #expect(joint[row ..< row + 1].asData(access: .copy).data == single[row].asData(access: .copy).data,
                                "heads=\(heads) rows=\(rows) step=\(step) row=\(row): the cohort step changed a row")
                        }
                        // Record each row's next proposal the same way in both sets.
                        var nextTogether: [MLXArray] = [], nextAlone: [MLXArray] = []
                        for row in 0..<rows {
                            let draft = MLXArray([Int32((row * 13 + step * 7) % 256)])
                            let jointRow = joint[row ..< row + 1]
                            assistant.recordDraft(lastHidden: jointRow, draft: draft, requestState: together.states[row])
                            assistant.recordDraft(lastHidden: single[row], draft: draft, requestState: alone.states[row])
                            nextTogether.append(jointRow); nextAlone.append(single[row])
                            feedsTogether.tokens[row] = draft.reshaped([1, 1]); feedsAlone.tokens[row] = draft.reshaped([1, 1])
                        }
                        feedsTogether.hiddens = nextTogether; feedsAlone.hiddens = nextAlone
                        eval(together.states.flatMap { assistant.evaluationTargets(for: $0) }
                            + alone.states.flatMap { assistant.evaluationTargets(for: $0) })
                    }
                    print("darkbloom-exact-draft-rows-v1 heads=\(heads) rows=\(rows) steps=2 equal=1")
                    for state in together.states + alone.states { assistant.releaseRequestState(state) }
                }
            }
        }
    }
}
