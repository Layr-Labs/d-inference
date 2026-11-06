#if QWEN_TARGET_TINY_FIXTURE
import Foundation
import MLX

/// Local fixture routing calls the actual two Session trunks. This is not a
/// replacement forward or a claim about network/bilateral protocol delivery.
final class QwenTinyTargetPair {
    struct FrameOutput { let boundary: QwenLayerStageBoundary; let value: MLXArray }
    let sessions: [QwenLayerStageSession]
    let request: QwenLayerStageGenerationRequest
    let resources: QwenTinyTargetFixtureResources

    init(resources: QwenTinyTargetFixtureResources) throws {
        try resources.requireLive()
        self.resources = resources; request = resources.request
        var values: [QwenLayerStageSession] = []
        do {
            for stage in resources.model.stages {
                try resources.requireLive()
                values.append(try .init(stage: stage, plan: stage.plan, generationRequest: request))
            }
        } catch { for value in values { try? value.cancel() }; throw error }
        sessions = values
    }

    func forward(_ frame: QwenLayerStageFrame, tokens: [Int]) throws -> FrameOutput {
        try resources.requireLive()
        let first: QwenLayerStageOutput
        if frame.phase == .prefill {
            first = try sessions[0].prefillChunk(tokens, offset: frame.tokenOffset,
                final: frame.finalPromptChunk, check: resources.requireLive)
        } else {
            first = try sessions[0].decode(tokens[0], offset: frame.tokenOffset, check: resources.requireLive)
        }
        guard case .hidden(let boundary) = first else { throw ProbeError("Tiny producer did not return its real residual") }
        let last: QwenLayerStageOutput
        if frame.phase == .prefill {
            last = try sessions[1].prefillChunk(tokens, offset: frame.tokenOffset,
                final: frame.finalPromptChunk, incoming: boundary, check: resources.requireLive)
        } else {
            last = try sessions[1].decode(tokens[0], offset: frame.tokenOffset,
                incoming: boundary, check: resources.requireLive)
        }
        switch last {
        case .logits(let value), .evaluationHandle(let value): return .init(boundary: boundary, value: value)
        case .hidden: throw ProbeError("Tiny final stage returned a residual")
        }
    }

    func prefill() throws -> MLXArray {
        var output: MLXArray?
        for sequence in 0..<request.prefillFrameCount {
            let frame = try request.frame(sequence: sequence)
            let tokens = Array(request.promptTokenIDs[frame.tokenOffset..<(frame.tokenOffset+frame.tokenCount)])
            output = try forward(frame, tokens: tokens).value
        }
        return output!
    }

    func decode(_ token: Int) throws -> MLXArray {
        let offset = sessions[0].committedTokens
        let sequence = request.prefillFrameCount + offset - request.promptCount
        return try forward(request.frame(sequence: sequence), tokens: [token]).value
    }

    func snapshots() throws -> [CBv2OwnedStateSnapshot] {
        try sessions.map { try $0.snapshot(check: resources.requireLive) }
    }

    func cancel() throws {
        var first: Error?
        for session in sessions {
            do { try session.cancel() } catch { first = first ?? error }
        }
        guard sessions.allSatisfy(\.isClosed) else { throw ProbeError("Tiny pair retained native request ownership") }
        if let first { throw first }
    }
    deinit { try? cancel() }
}

enum QwenTinyTargetAssertions {
    static func require(_ value: Bool, _ message: String) throws {
        guard value else { throw ProbeError(message) }
    }
    static func logits(_ a: MLXArray, _ b: MLXArray, check: () throws -> Void) throws -> Float {
        eval(a, b); try check()
        try require(a.shape == b.shape && a.shape == [1, 128], "Tiny target logit geometry differs")
        let left = a.asType(.float32).asArray(Float.self), right = b.asType(.float32).asArray(Float.self)
        try check()
        try require(left.allSatisfy(\.isFinite) && right.allSatisfy(\.isFinite), "Tiny logits are nonfinite")
        let difference = zip(left, right).reduce(Float(0)) { max($0, abs($1.0-$1.1)) }
        try require(difference <= 0.00001, "Actual transaction logits differ from ordinary target")
        return difference
    }
    static func token(_ value: MLXArray, check: () throws -> Void) throws -> Int {
        let selected = argMax(value, axis: -1).asType(.int32); eval(selected); try check()
        let values = selected.asArray(Int32.self)
        try require(values.count == 1 && (0..<128).contains(Int(values[0])), "Tiny greedy scalar differs")
        return Int(values[0])
    }
    static func state(_ left: QwenTinyTargetPair, _ right: QwenTinyTargetPair) throws {
        let a = try left.snapshots(), b = try right.snapshots()
        try require(a.count == 2 && b.count == 2 && zip(a, b).allSatisfy { pair in
            pair.0.committedTokens == pair.1.committedTokens && pair.0.fingerprint == pair.1.fingerprint
                && pair.0.entries.map(\.identity) == pair.1.entries.map(\.identity)
        }, "Actual transaction KV/recurrent state differs from fresh ordinary replay")
    }
}
#endif
