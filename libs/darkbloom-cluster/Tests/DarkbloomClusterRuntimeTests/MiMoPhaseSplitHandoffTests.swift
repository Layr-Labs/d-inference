import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Testing
@testable import DarkbloomClusterRuntime

// A MiMo phase split on the four-layer random model of
// `MiMoStagePipelineEquivalenceTests` (full and sliding-window attention, a
// window shorter than the prompt frames): the producer stage prefills the
// prompt with the consumer stage, as the pair does; its caches are then
// exported as bytes, adopted into a fresh producer cache list (another rank's
// copy of the stage, as rank 1 holds it), and decoding continues there. Every
// decoded logits row must equal, bit for bit, the row the producer's own
// caches give when decoding simply continues: the hand-off moves state and
// changes no arithmetic. Also: the derived component shapes and rotations are
// exactly the caches' own for prompts shorter than, equal to and longer than
// the window and the frame. No artifact, no transport; a pass here is not a
// hardware pass.

@Suite("MiMo phase split: the hand-off adopts the producer's caches bit for bit (tiny random model)")
struct MiMoPhaseSplitHandoffTests {
    typealias Equivalence = MiMoStagePipelineEquivalenceTests

    /// Prefill `prompt` through both stages in frames of `chunk`; returns the
    /// caches and the first selected token.
    static func prefill(_ stages: [MiMoV26TextModel], prompt: [Int], chunk: Int) throws -> (caches: [[KVCache]], token: Int, frames: [Int]) {
        let caches = stages.map { $0.newCache() }
        let last = stages[0].configuration.numHiddenLayers - 1
        var offset = 0, frames: [Int] = [], token = -1
        while offset < prompt.count {
            let part = Array(prompt[offset..<min(prompt.count, offset + chunk)])
            let out = try stages[0].forward(inputIDs: MLXArray(part.map(Int32.init)).reshaped([1, part.count]),
                                            cache: caches[0], captureLayers: [last])
            let residual = try #require(out.layerFeatures[last])
            eval([residual] + caches[0].flatMap { $0.innerState() })
            let received = MLXArray(residual.asData().data, residual.shape, dtype: residual.dtype)
            let row = try stages[1].forward(embeddings: received, cache: caches[1], logitsStart: part.count - 1)
                .logits[0..., -1, 0...]
            eval([row] + caches[1].flatMap { $0.innerState() })
            offset += part.count; frames.append(part.count)
            if offset == prompt.count { token = Int(argMax(row, axis: -1).item(UInt32.self)) }
        }
        return (caches, token, frames)
    }

    /// Greedy decode from `token` with these caches; one row per step.
    static func decode(_ stages: [MiMoV26TextModel], producer: [KVCache], consumer: [KVCache], token first: Int,
                       steps: Int) throws -> [MLXArray] {
        let last = stages[0].configuration.numHiddenLayers - 1
        var token = first, rows: [MLXArray] = []
        for _ in 0..<steps {
            let out = try stages[0].forward(inputIDs: MLXArray([Int32(token)]).reshaped([1, 1]), cache: producer,
                                            captureLayers: [last])
            let residual = try #require(out.layerFeatures[last])
            eval([residual] + producer.flatMap { $0.innerState() })
            let received = MLXArray(residual.asData().data, residual.shape, dtype: residual.dtype)
            let row = try stages[1].forward(embeddings: received, cache: consumer, logitsStart: 0).logits[0..., -1, 0...]
            eval([row] + consumer.flatMap { $0.innerState() })
            rows.append(row)
            token = Int(argMax(row, axis: -1).item(UInt32.self))
        }
        return rows
    }

    /// The producer's caches as the adopting rank receives them: bytes, then
    /// fresh owned arrays, then installed into a fresh cache list.
    static func handOver(_ producer: [KVCache], stage: MiMoV26TextModel, frames: [Int]) throws -> [KVCache] {
        let prompt = frames.reduce(0, +)
        let shapes = try MiMoPhaseSplitState.expectedShapes(stage: stage.configuration, firstGlobalLayer: 0, frames: frames,
                                                            activationDType: "bfloat16")
        let arrays = try MiMoPhaseSplitState.exportArrays(caches: producer, configuration: stage.configuration,
                                                          frames: frames, shapes: shapes)
        let received = zip(arrays, shapes).map { array, shape in
            MLXArray(array.asData().data, shape.shape, dtype: array.dtype)
        }
        var attention: [Int: (keys: MLXArray, values: MLXArray)] = [:]
        for layer in 0..<producer.count { attention[layer] = (received[2 * layer], received[2 * layer + 1]) }
        let fresh = stage.newCache()
        try MiMoPhaseSplitState.install(.init(committedTokens: prompt, attention: attention, recurrent: [:]),
                                        into: fresh, shapes: shapes, frames: frames, configuration: stage.configuration)
        return fresh
    }

    @Test(arguments: [(11, 4), (1, 4), (2, 4), (3, 4), (4, 4), (9, 2), (13, 4), (17, 5)])
    func adoptedProducerDecodesBitForBit(prompt length: Int, chunk: Int) throws {
        let data = Equivalence.configuration(dtype: "bfloat16")
        let whole = try Equivalence.whole(data, dtype: .bfloat16)
        let prompt = (0..<length).map { (7 * $0 + 5) % Equivalence.vocabulary }
        for cut in 1..<Equivalence.layers {
            let plan = try MiMoLayerStagePlan(configuration: data, cut: cut)
            let stages = try Equivalence.stages(plan, from: whole, dtype: .bfloat16)
            // Reference: the producer keeps its own caches and decoding continues.
            let kept = try Self.prefill(stages, prompt: prompt, chunk: chunk)
            let reference = try Self.decode(stages, producer: kept.caches[0], consumer: kept.caches[1],
                                            token: kept.token, steps: 6)
            // Phase split: the same prompt, the producer's caches handed over.
            let split = try Self.prefill(stages, prompt: prompt, chunk: chunk)
            #expect(split.token == kept.token, "cut \(cut): the first token precedes the hand-off")
            let adopted = try Self.handOver(split.caches[0], stage: stages[0], frames: split.frames)
            let rows = try Self.decode(stages, producer: adopted, consumer: split.caches[1], token: split.token, steps: 6)
            for (index, row) in rows.enumerated() {
                let same = row.asData().data == reference[index].asData().data
                #expect(same, "prompt \(length) chunk \(chunk) cut \(cut) row \(index): the adopted producer changed the logits")
            }
        }
    }

    @Test func derivedShapesAreTheCachesOwn() throws {
        let data = Equivalence.configuration(dtype: "bfloat16")
        let whole = try Equivalence.whole(data, dtype: .bfloat16)
        let plan = try MiMoLayerStagePlan(configuration: data, cut: 3)
        let stages = try Equivalence.stages(plan, from: whole, dtype: .bfloat16)
        // Single-token frames (a prompt of one token, a last frame of one) are written in place, not concatenated.
        for (length, chunk) in [(1, 4), (2, 1), (3, 3), (5, 2), (6, 4), (13, 4), (12, 3), (7, 3)] {
            let prompt = (0..<length).map { (3 * $0 + 1) % Equivalence.vocabulary }
            let run = try Self.prefill(stages, prompt: prompt, chunk: chunk)
            let shapes = try MiMoPhaseSplitState.expectedShapes(stage: stages[0].configuration, firstGlobalLayer: 0,
                frames: run.frames, activationDType: "bfloat16")
            // exportArrays refuses any array or rotation that differs from the derivation.
            let arrays = try MiMoPhaseSplitState.exportArrays(caches: run.caches[0], configuration: stages[0].configuration,
                                                              frames: run.frames, shapes: shapes)
            #expect(zip(arrays, shapes).allSatisfy { $0.shape == $1.shape && $0.nbytes == $1.byteCount },
                    "prompt \(length) chunk \(chunk)")
        }
        // A frame grid other than the one that ran is refused, not silently adopted.
        let run = try Self.prefill(stages, prompt: Array(0..<13), chunk: 4)
        let other = try MiMoPhaseSplitState.expectedShapes(stage: stages[0].configuration, firstGlobalLayer: 0,
            frames: [13], activationDType: "bfloat16")
        #expect(throws: (any Error).self) {
            _ = try MiMoPhaseSplitState.exportArrays(caches: run.caches[0], configuration: stages[0].configuration,
                                                     frames: [13], shapes: other)
        }
    }

    @Test func retainedLengthFollowsTheRotatingCachesRule() throws {
        #expect(try MiMoPhaseSplitState.slidingRetainedTokens(window: 128, frames: [512, 512, 100]) == 227)
        #expect(try MiMoPhaseSplitState.slidingRetainedTokens(window: 128, frames: [512]) == 512)
        #expect(try MiMoPhaseSplitState.slidingRetainedTokens(window: 128, frames: [27]) == 27)
        #expect(try MiMoPhaseSplitState.slidingRetainedTokens(window: 128, frames: [100, 20]) == 120)
        #expect(try MiMoPhaseSplitState.slidingRetainedTokens(window: 128, frames: [100, 20, 30]) == 150)
        #expect(throws: (any Error).self) { _ = try MiMoPhaseSplitState.slidingRetainedTokens(window: 128, frames: []) }
        // A last frame of one token goes in place: the buffer is cut to the window and rotates.
        #expect(try MiMoPhaseSplitState.slidingState(window: 128, step: 256, frames: [512, 1]) == (length: 128, index: 1))
        #expect(try MiMoPhaseSplitState.slidingState(window: 128, step: 256, frames: [1]) == (length: 1, index: 1))
        #expect(try MiMoPhaseSplitState.slidingState(window: 128, step: 256, frames: [100, 1]) == (length: 101, index: 101))
        #expect(try MiMoPhaseSplitState.slidingState(window: 3, step: 256, frames: [2, 2, 2, 2, 1]) == (length: 3, index: 1))
    }
}
