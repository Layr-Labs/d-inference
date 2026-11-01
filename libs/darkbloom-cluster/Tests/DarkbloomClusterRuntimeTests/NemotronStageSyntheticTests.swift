import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import Testing
@testable import DarkbloomClusterRuntime

// A tiny random Nemotron (eleven blocks of width 64, unquantized) through the
// runtime's own Plan, stage construction, inert modules, request geometry,
// owned request state and stage forward, against the same model run whole
// through the pinned class's serving entry points. Both sides run the same
// operations on the same values, so every comparison is exact.
//
// This is a contract test on a synthetic model. It shows that the stage seam
// and the runtime's use of it split the arithmetic and the request state
// without changing either. It is not a model or hardware result: the
// registered artifact's runs are recorded in the handoff.

@Suite("Nemotron layer stages on a synthetic model (no artifact)", .serialized)
struct NemotronStageSyntheticTests {
    static let pattern = ["mamba", "moe", "mamba", "attention", "moe", "mamba", "moe", "attention", "moe", "mamba", "moe"]
    static let hidden = 64, vocabulary = 96
    /// Prompt chunks of 5 and 3 tokens, then two decode tokens.
    static let frames: [[Int]] = [[3, 1, 4, 1, 5], [9, 2, 6], [5], [35]]

    static func configuration() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "model_type": "nemotron_h", "vocab_size": vocabulary, "hidden_size": hidden,
            "num_hidden_layers": pattern.count, "layers_block_type": pattern,
            "num_attention_heads": 4, "num_key_value_heads": 2, "head_dim": 16,
            "mamba_num_heads": 4, "mamba_head_dim": 16, "ssm_state_size": 32, "conv_kernel": 4, "n_groups": 2,
            "intermediate_size": 64, "moe_intermediate_size": 32, "moe_shared_expert_intermediate_size": 32,
            "n_routed_experts": 4, "n_shared_experts": 1, "num_experts_per_tok": 2,
            "mamba_ssm_cache_dtype": "float32", "max_position_embeddings": 8320, "tie_word_embeddings": false,
        ] as [String: Any], options: [.sortedKeys])
    }

    /// The complete model with seeded random weights, routers included (the
    /// pinned constructor starts a router at zero, which would route every
    /// token alike).
    static func completeModel(_ configuration: Data) throws -> any LanguageModel {
        let model = try withRandomState(MLXRandom.RandomState(seed: 11)) { () -> any LanguageModel in
            let model = try NemotronStageConstruction.model(configuration)
            var routers: [String: MLXArray] = [:]
            for (name, value) in model.parameters().flattened() where name.hasSuffix(".gate.weight") {
                routers[name] = MLXRandom.normal(value.shape) * 0.2
            }
            try model.update(parameters: ModuleParameters.unflattened(routers), verify: [.noUnusedKeys, .shapeMismatch])
            return model
        }
        eval(model)
        return model
    }

    /// One stage as the loader builds it: the pinned class over the stage's
    /// configuration, its inert modules installed, then the complete model's
    /// tensors placed by the Plan's own name mapping.
    static func stage(_ plan: QwenLayerStagePlan, _ index: Int, from complete: any LanguageModel) throws -> any LanguageModel {
        let descriptor = plan.stages[index]
        let model = try NemotronStageConstruction.model(descriptor.constructionConfiguration)
        try NemotronStageConstruction.validate(model, layerCount: descriptor.layers.count)
        let inert = try NemotronStageConstruction.installInertParameters(model: model, stage: descriptor,
            hiddenSize: hidden, activationDType: .float32)
        let source = Dictionary(uniqueKeysWithValues: complete.parameters().flattened())
        var placed: [String: MLXArray] = [:]
        for mapping in try plan.parameters(canonicalSourceNames: Array(source.keys)) where mapping.stage == index {
            placed[mapping.localName] = source[mapping.sourceName]!
        }
        try model.update(parameters: ModuleParameters.unflattened(placed), verify: [.noUnusedKeys, .shapeMismatch])
        // Active and inert parameters together are exactly the stage's own.
        let inertNames = Set(inert.flatMap(\.parameters).map(\.localName))
        #expect(Set(model.parameters().flattened().map(\.0)) == Set(placed.keys).union(inertNames))
        #expect(inert.map(\.path) == descriptor.inertModules.map(\.path).sorted())
        model.freeze(); eval(model)
        return model
    }

    static func state(_ model: any LanguageModel, layers: Int, configuration: Data) throws -> CBv2OwnedRequestState {
        let total = frames.joined().count
        let geometry = try CBv2RequestGeometry(model: model, family: .qwen35, feedForwardKind: "dense",
            layerCount: layers, vocabularySize: vocabulary, configurationData: configuration, maximumTokens: total)
        #expect(geometry.layerCount == layers && geometry.kvDType == .float32)
        return try CBv2OwnedRequestState(geometry: geometry, promptCount: 8, outputCount: total - 8)
    }

    static func frame(_ sequence: Int) -> QwenLayerStageFrame {
        let offset = frames[..<sequence].joined().count
        return .init(sequence: sequence, phase: sequence < 2 ? .prefill : .decode, tokenOffset: offset,
                     tokenCount: frames[sequence].count, finalPromptChunk: sequence == 1)
    }

    static func rows(_ sequence: Int) -> MLXArray {
        MLXArray(frames[sequence].map(Int32.init)).reshaped([1, frames[sequence].count])
    }

    /// The complete model through the entry points the product serves with.
    static func serve(_ model: any LanguageModel, configuration: Data) throws -> ([Data], CBv2OwnedRequestState) {
        let nemotron = try #require(model as? NemotronHModel)
        let state = try Self.state(model, layers: pattern.count, configuration: configuration)
        var outputs: [Data] = []
        for sequence in frames.indices {
            let input = rows(sequence)
            let output = try state.run(tokenCount: frames[sequence].count, check: {}, forward: { caches, evaluation in
                let kv = caches.map { $0 as! any KVCache }
                switch sequence {
                case 0:
                    return nemotron.cbv2RecurrentPrefill(input, inputEmbedding: nil, cache: kv, recurrentState: [evaluation],
                        positionIds: nil, requirement: .evaluationOnly)
                case 1:
                    return nemotron.cbv2RecurrentPrefill(input, inputEmbedding: nil, cache: kv, recurrentState: [evaluation],
                        positionIds: nil, requirement: .lastPositionLogits)
                default:
                    return nemotron.cbv2Forward(input, caches: kv, recurrentState: [evaluation])[0..., -1, 0...]
                }
            }, validateOutput: { _ in })
            outputs.append(output.asData().data)
        }
        return (outputs, state)
    }

    /// The same frames through two stages joined only by the residual.
    static func staged(_ plan: QwenLayerStagePlan, from complete: any LanguageModel)
        throws -> (outputs: [Data], residuals: [MLXArray], states: [CBv2OwnedRequestState], models: [any LanguageModel]) {
        let models = try (0...1).map { try stage(plan, $0, from: complete) }
        let states = try (0...1).map {
            try state(models[$0], layers: plan.stages[$0].layers.count, configuration: plan.stages[$0].constructionConfiguration)
        }
        var outputs: [Data] = [], residuals: [MLXArray] = []
        for sequence in frames.indices {
            let input = rows(sequence), frame = Self.frame(sequence), count = frames[sequence].count
            let residual = try states[0].run(tokenCount: count, check: {}, forward: { caches, evaluation in
                NemotronStageForward.run(model: models[0] as! NemotronHModel, stageIndex: 0, tokens: input, residual: nil,
                    caches: caches, evaluation: evaluation, frame: frame)
            }, validateOutput: { #expect($0.shape == [1, count, hidden] && $0.dtype == .float32) })
            residuals.append(residual)
            let output = try states[1].run(tokenCount: count, check: {}, forward: { caches, evaluation in
                NemotronStageForward.run(model: models[1] as! NemotronHModel, stageIndex: 1, tokens: input, residual: residual,
                    caches: caches, evaluation: evaluation, frame: frame)
            }, validateOutput: { #expect($0.shape == (sequence == 0 ? [1, 1] : [1, vocabulary])) })
            outputs.append(output.asData().data)
        }
        return (outputs, residuals, states, models)
    }

    @Test func twoStagesEqualTheCompleteModelInOutputAndState() throws {
        let configuration = try Self.configuration()
        let complete = try Self.completeModel(configuration)
        let (served, servedState) = try Self.serve(complete, configuration: configuration)
        let whole = try servedState.snapshot(globalLayerIndices: Array(Self.pattern.indices), includeBytes: false, check: {})
        // Six state-bearing blocks: four Mamba (2 entries each), two attention (3 each).
        #expect(whole.entries.count == 4 * 2 + 2 * 3 && whole.committedTokens == 10)
        var routes = Set<Data>()
        for cut in [5, 7] {
            let plan = try QwenLayerStagePlan(configuration: configuration, ranges: [0..<cut, cut..<Self.pattern.count])
            let run = try Self.staged(plan, from: complete)
            #expect(run.outputs == served, "cut \(cut): a frame's output differs from the complete model's")
            let snapshots = try (0...1).map {
                try run.states[$0].snapshot(globalLayerIndices: plan.stages[$0].layers.map(\.globalIndex),
                                            includeBytes: false, check: {})
            }
            // Each stage holds exactly its own blocks' state, under the complete model's indices.
            let joined = snapshots.flatMap(\.entries).map(\.identity).sorted()
            #expect(joined == whole.entries.map(\.identity).sorted(), "cut \(cut): request state differs")
            for (index, snapshot) in snapshots.enumerated() {
                #expect(snapshot.entries.allSatisfy { plan.stages[index].sourceRange.contains($0.globalLayerIndex) })
                _ = try QwenLayerStageRankStateCapture(snapshot: snapshot, stage: plan.stages[index], committedTokens: 10)
            }
            let recorded = try QwenRecordedState(snapshots: snapshots, plan: plan, committedTokens: 10)
            try QwenRecordedState(snapshots: [whole], plan: plan, committedTokens: 10).requireExact(recorded)
            routes.insert(run.residuals[1].asData().data)
        }
        // The two cuts hand over different residuals and still agree on every output.
        #expect(routes.count == 2)
    }

    /// What a phase-split hand-off expects of the producer stage is what that
    /// stage actually holds, and a state rebuilt from those bytes continues
    /// exactly as the original does.
    @Test func producerStateIsWhatAHandoffExpectsAndAdoptsExactly() throws {
        let configuration = try Self.configuration()
        let complete = try Self.completeModel(configuration)
        let cut = 5, total = Self.frames.joined().count
        let plan = try QwenLayerStagePlan(configuration: configuration, ranges: [0..<cut, cut..<Self.pattern.count])
        let producer = try Self.stage(plan, 0, from: complete)
        let nemotron = try #require(producer as? NemotronHModel)
        func step(_ state: CBv2OwnedRequestState, _ sequence: Int) throws -> Data {
            try state.run(tokenCount: Self.frames[sequence].count, check: {}, forward: { caches, evaluation in
                NemotronStageForward.run(model: nemotron, stageIndex: 0, tokens: Self.rows(sequence), residual: nil,
                    caches: caches, evaluation: evaluation, frame: Self.frame(sequence))
            }, validateOutput: { _ in }).asData().data
        }
        let original = try Self.state(producer, layers: cut, configuration: plan.stages[0].constructionConfiguration)
        _ = try step(original, 0); _ = try step(original, 1)
        let snapshot = try original.snapshot(globalLayerIndices: plan.stages[0].layers.map(\.globalIndex),
                                             includeBytes: true, check: {})
        let root = try #require(try JSONSerialization.jsonObject(with: configuration) as? [String: Any])
        let declared = try NemotronStageMetadata.geometry(root: root)
        let geometry = try NemotronRegisteredLightning.stateGeometry(declared, kinds: declared.kinds)
        let expected = try QwenPhaseSplitPlan.expectedShapes(stage: plan.stages[0], geometry: geometry,
            committedTokens: 8, activationDType: "float32")
        #expect(expected.map(\.identity) == snapshot.entries.map {
            QwenPhaseSplitStateShape(globalLayerIndex: $0.globalLayerIndex, component: $0.component, shape: $0.shape,
                                     dtype: $0.dtype, byteCount: $0.byteCount).identity
        })
        // Rebuild the state from the snapshot's bytes alone, by the stage's own indices.
        let local = Dictionary(uniqueKeysWithValues: plan.stages[0].layers.map { ($0.globalIndex, $0.localIndex) })
        var parts: [Int: [String: MLXArray]] = [:]
        for entry in snapshot.entries where entry.component != QwenPhaseSplitStateShape.positionOffsets {
            let bytes = try #require(entry.bytes)
            parts[try #require(local[entry.globalLayerIndex]), default: [:]][entry.component] =
                MLXArray(bytes, entry.shape, dtype: .float32)
        }
        var attention: [Int: (keys: MLXArray, values: MLXArray)] = [:], recurrent: [Int: (conv: MLXArray, ssm: MLXArray)] = [:]
        for (layer, components) in parts {
            if let keys = components["kv.keys"], let values = components["kv.values"] { attention[layer] = (keys, values) }
            if let conv = components["conv"], let ssm = components["ssm"] { recurrent[layer] = (conv, ssm) }
        }
        #expect(attention.count == 1 && recurrent.count == 2)
        let adopted = try CBv2OwnedRequestState(geometry: try CBv2RequestGeometry(model: producer, family: .qwen35,
                feedForwardKind: "dense", layerCount: cut, vocabularySize: Self.vocabulary,
                configurationData: plan.stages[0].constructionConfiguration, maximumTokens: total),
            promptCount: 8, outputCount: total - 8, adoptingCommittedTokens: 8, attention: attention, recurrent: recurrent)
        #expect(try adopted.snapshot(globalLayerIndices: plan.stages[0].layers.map(\.globalIndex), includeBytes: false,
                                     check: {}).fingerprint == snapshot.fingerprint)
        for sequence in 2...3 { #expect(try step(adopted, sequence) == (try step(original, sequence))) }
        try original.retire(); try adopted.retire()
    }

    @Test func aStageRefusesWhatItDoesNotOwn() throws {
        let configuration = try Self.configuration()
        let complete = try Self.completeModel(configuration)
        let plan = try QwenLayerStagePlan(configuration: configuration, ranges: [0..<5, 5..<Self.pattern.count])
        let consumer = try Self.stage(plan, 1, from: complete)
        // The consumer's embedding is a placeholder: one bounded row, no lookup table.
        let parameters = Dictionary(uniqueKeysWithValues: consumer.parameters().flattened())
        #expect(parameters["backbone.embeddings.weight"]?.shape == [1, Self.hidden])
        let producer = try Self.stage(plan, 0, from: complete)
        let held = Dictionary(uniqueKeysWithValues: producer.parameters().flattened())
        #expect(held["lm_head.weight"]?.shape == [1, Self.hidden] && held["backbone.norm_f.weight"]?.shape == [Self.hidden])
        // A geometry asked for another layer count than the stage's block list is refused.
        #expect(throws: (any Error).self) {
            _ = try CBv2RequestGeometry(model: producer, family: .qwen35, feedForwardKind: "dense", layerCount: 6,
                vocabularySize: Self.vocabulary, configurationData: plan.stages[0].constructionConfiguration, maximumTokens: 16)
        }
        // The complete configuration's block list does not describe a stage's model.
        #expect(throws: (any Error).self) {
            _ = try CBv2RequestGeometry(model: producer, family: .qwen35, feedForwardKind: "dense", layerCount: Self.pattern.count,
                vocabularySize: Self.vocabulary, configurationData: configuration, maximumTokens: 16)
        }
        #expect(throws: (any Error).self) { try NemotronStageConstruction.validate(producer, layerCount: 6) }
    }
}
