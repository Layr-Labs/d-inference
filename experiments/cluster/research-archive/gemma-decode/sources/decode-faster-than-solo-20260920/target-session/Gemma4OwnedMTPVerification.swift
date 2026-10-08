import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// One evaluated target window. The request owner alone can reconcile it.
/// Returned arrays remain charged to that request until the caller releases them.
final class Gemma4OwnedMTPWindow {
    fileprivate weak var owner: Gemma4OwnedForwardSession?
    let base: Int
    let inputTokens: [Int]
    let logits: MLXArray
    let hidden: MLXArray
    fileprivate var retainedInputs: Int?

    fileprivate init(owner: Gemma4OwnedForwardSession, base: Int, inputTokens: [Int],
                     logits: MLXArray, hidden: MLXArray) {
        self.owner = owner; self.base = base; self.inputTokens = inputTokens
        self.logits = logits; self.hidden = hidden
    }
}

/// Fenced conditioning views at one reconciled target frontier. Transport must
/// finish reading them before this value is released. A local assistant retains
/// them for its explicitly bounded branch; its extra lifetime needs admission.
struct Gemma4OwnedMTPConditioning {
    let frontier: Int
    let hidden: MLXArray
    let fullKeys: MLXArray, fullValues: MLXArray
    let slidingKeys: MLXArray, slidingValues: MLXArray
    var evaluationRoots: [MLXArray] { [hidden, fullKeys, fullValues, slidingKeys, slidingValues] }
}

extension Gemma4OwnedForwardSession {
    /// Width one primes the assistant using the first ordinary generated token.
    /// Wider windows verify [confirmed seed, candidate proposals] in one forward.
    /// Target argmax/acceptance and output publication belong to the caller.
    func evaluateMTPInputs(_ tokens: [Int], offset: Int,
        admit: (CBv2AttentionVerificationPlan) throws -> Void,
        check: () throws -> Void
    ) throws -> Gemma4OwnedMTPWindow {
        do {
            return try MLX.withError { native in
                func checked() throws { try native.check(); try check(); try native.check() }
                do {
                    try checked(); try state.requireOpen()
                    guard activeMTPWindow == nil, case .full(let full) = loaded.model,
                          let capture = full.textModel.cbv2MTPCaptureLayers,
                          offset >= request.promptCount, offset == state.committedTokens,
                          offset == schedule.committedTokens, (1...4).contains(tokens.count),
                          tokens.allSatisfy({ (0..<request.profile.vocabularySize).contains($0) }) else {
                        throw ProbeError("Gemma MTP input lacks a full target at its committed frontier")
                    }
                    // Preflight the WHOLE width before opening any native write.
                    // KV capacity includes the final unfed output token; the
                    // generation schedule intentionally ends one input earlier.
                    var preview = schedule
                    for index in 0..<tokens.count {
                        let frame = try preview.admitDecode(offset: offset + index)
                        try preview.commit(frame)
                    }
                    try state.beginAttentionVerification(steps: tokens.count,
                        captureLayerIndices: [capture.sliding, capture.full], admit: admit, check: checked)
                    var hidden: MLXArray?
                    let logits = try state.stageAttentionVerification(check: checked,
                        additionalTargets: { hidden.map { [$0] } ?? [] }, forward: { caches in
                            let input = MLXArray(tokens.map(Int32.init)).reshaped([1, tokens.count])
                            let output = full.textModel.cbv2ForwardWithHidden(input,
                                caches: caches.map { $0 as! any KVCache })
                            hidden = output.lastHidden
                            return output.logits
                        }, validateOutput: { output in
                            guard output.shape == [1, tokens.count, self.request.profile.vocabularySize],
                                  let hidden, hidden.shape == [1, tokens.count, self.request.profile.hiddenSize],
                                  [.float16, .bfloat16, .float32].contains(output.dtype),
                                  [.float16, .bfloat16, .float32].contains(hidden.dtype) else {
                                throw ProbeError("Gemma rectangular target output geometry differs")
                            }
                        })
                    try checked()
                    guard let hidden else { throw ProbeError("Gemma target omitted its evaluated hidden root") }
                    let window = Gemma4OwnedMTPWindow(owner: self, base: offset,
                        inputTokens: tokens, logits: logits, hidden: hidden)
                    activeMTPWindow = window
                    return window
                } catch { try native.check(); throw error }
            }
        } catch { try retireMTPFailure(error) }
    }

    /// Reconcile actual cache writes before advancing the public generation
    /// schedule. The correction/bonus output itself remains the next unfed seed.
    func reconcileMTP(_ window: Gemma4OwnedMTPWindow, keeping count: Int,
                      check: () throws -> Void) throws -> Int {
        do {
            return try MLX.withError { native in
                func checked() throws { try native.check(); try check(); try native.check() }
                do {
                    guard window.owner === self, activeMTPWindow === window,
                          window.retainedInputs == nil, (0...window.inputTokens.count).contains(count),
                          schedule.committedTokens == window.base else {
                        throw ProbeError("Gemma MTP reconcile is foreign, replayed or out of order")
                    }
                    let frontier = try state.reconcileAttentionVerification(keeping: count, check: checked)
                    guard frontier == window.base + count else { throw ProbeError("Gemma MTP frontier differs") }
                    for offset in window.base..<frontier {
                        let frame = try schedule.admitDecode(offset: offset)
                        try schedule.commit(frame)
                    }
                    try checked()
                    window.retainedInputs = count; activeMTPWindow = nil
                    return frontier
                } catch { try native.check(); throw error }
            }
        } catch { try retireMTPFailure(error) }
    }

    func mtpConditioning(after window: Gemma4OwnedMTPWindow,
                         check: () throws -> Void) throws -> Gemma4OwnedMTPConditioning {
        do {
            return try MLX.withError { native in
                func checked() throws { try native.check(); try check(); try native.check() }
                do {
                    try state.requireOpen(); try checked()
                    guard window.owner === self, let kept = window.retainedInputs, kept > 0,
                          state.committedTokens == window.base + kept,
                          case .full(let full) = loaded.model,
                          let indices = full.textModel.cbv2MTPCaptureLayers,
                          state.rows.indices.contains(indices.full), state.rows.indices.contains(indices.sliding),
                          let fullRow = state.rows[indices.full], let slidingRow = state.rows[indices.sliding],
                          fullRow.absoluteOffset == state.committedTokens,
                          slidingRow.absoluteOffset == state.committedTokens else {
                        throw ProbeError("Gemma assistant conditioning lacks an exact reconciled target capture")
                    }
                    let f = fullRow.snapshot(), s = slidingRow.snapshot()
                    let result = Gemma4OwnedMTPConditioning(frontier: state.committedTokens,
                        hidden: window.hidden[0..., (kept - 1)..<kept, 0...],
                        fullKeys: f.keys, fullValues: f.values, slidingKeys: s.keys, slidingValues: s.values)
                    eval(result.evaluationRoots); try checked()
                    return result
                } catch { try native.check(); throw error }
            }
        } catch { try retireMTPFailure(error) }
    }

    private func retireMTPFailure(_ error: Error) throws -> Never {
        do { try cancel(); activeMTPWindow = nil }
        catch let cleanup { throw ProbeError("Gemma MTP failed (\(error)); retirement failed (\(cleanup))") }
        throw error
    }
}
