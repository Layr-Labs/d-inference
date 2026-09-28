import Foundation
import MLX

private func checkTokenSelectionFrames() throws -> Int {
    func combined(_ left: [Int32], _ right: [Int32]) -> [Int32] { zip(left, right).map { $0.0 + $0.1 } }
    let original = TokenSelectionSequence(sequence: 9, vocabularySize: 8, outputCount: 2)
    let good = combined(original.payload(localArgmax: 3, sequence: 9, step: 0, rank: 0),
                        original.payload(localArgmax: 7, sequence: 9, step: 0, rank: 1))
    var valid = original
    guard try valid.accept(good, sequence: 9, step: 0) == 3 else { throw ProbeError("Rank zero selection was not preserved") }
    var rejected = 0
    func requireRejected(_ frame: [Int32], state: TokenSelectionSequence? = nil,
                         sequence: Int = 9, step: Int = 0) throws {
        var state = state ?? original
        do { _ = try state.accept(frame, sequence: sequence, step: step) }
        catch { rejected += 1; return }
        throw ProbeError("Invalid token-selection frame was accepted")
    }
    try requireRejected([])
    try requireRejected(good, sequence: 10)
    try requireRejected(good, step: 1)
    try requireRejected(good, state: valid) // Replay after advancing the sequence.
    for (index, value) in [(0, 0), (1, 20), (2, 2), (3, 18), (4, 6), (5, -1), (5, 8), (6, 1)] {
        var changed = good; changed[index] = Int32(value)
        try requireRejected(changed)
    }
    let wrongSequence = TokenSelectionSequence(sequence: 10, vocabularySize: 8, outputCount: 2)
    try requireRejected(combined(original.payload(localArgmax: 3, sequence: 9, step: 0, rank: 0),
        wrongSequence.payload(localArgmax: 7, sequence: 10, step: 0, rank: 1)))
    let invalidLocal = original.payload(localArgmax: 8, sequence: 9, step: 0, rank: 1)
    try requireRejected(combined(original.payload(localArgmax: 3, sequence: 9, step: 0, rank: 0), invalidLocal))
    return rejected
}

/// Bounded two-process check: rank logits intentionally choose different tokens.
/// The following-step inputs must nevertheless be rank zero's selected history.
func checkTokenSelection(collective: Collective) throws {
    let rejectedFrames = try checkTokenSelectionFrames()
    let choices = collective.rank == 0 ? [3, 1, 6] : [5, 7, 2]
    var selected: [Int] = [], local: [Int] = [], nextInputs: [Int] = []
    collective.beginTokenSequence(sequence: 0, vocabularySize: 8, outputCount: choices.count)
    for (step, target) in choices.enumerated() {
        if let previous = selected.last { nextInputs.append(previous) }
        let logits = MLXArray((0..<8).map { $0 == target ? Float(2) : Float(-2) })
        let localToken = argMax(logits).item(Int.self)
        local.append(localToken)
        selected.append(try collective.selectToken(localArgmax: localToken, sequence: 0, step: step))
    }
    guard selected == [3, 1, 6], nextInputs == [3, 1], local == choices else {
        throw ProbeError("Cooperative selection fed an independent token history")
    }
    // A new repetition starts at step zero rather than inheriting the prior cursor.
    collective.beginTokenSequence(sequence: 1, vocabularySize: 8, outputCount: 1)
    guard try collective.selectToken(localArgmax: collective.rank == 0 ? 4 : 5, sequence: 1, step: 0) == 4 else {
        throw ProbeError("Token selection did not reset for a new repetition")
    }
    collective.beginTokenSequence(sequence: 2, vocabularySize: 8, outputCount: 1)
    var rejectedInvalidToken = false
    do { _ = try collective.selectToken(localArgmax: collective.rank == 0 ? -1 : 2, sequence: 2, step: 0) }
    catch { rejectedInvalidToken = true }
    guard rejectedInvalidToken else { throw ProbeError("Invalid rank-zero token was accepted") }
    struct Result: Encodable {
        let kind = "coordinated_token_selection_check"
        let tokenSelectionPolicy = "rank0-greedy"
        let correctnessOnly = true
        let rank: Int
        let generatedTokens: [Int]
        let localArgmaxTokens: [Int]
        let decodeInputTokens: [Int]
        let localArgmaxDisagreementCount: Int
        let rejectedMalformedFrames: Int
        let invalidRankZeroTokenRejected = true
        let sequenceResetVerified = true
    }
    try emitJSON(Result(rank: collective.rank, generatedTokens: selected, localArgmaxTokens: local,
        decodeInputTokens: nextInputs, localArgmaxDisagreementCount: zip(local, selected).filter { $0.0 != $0.1 }.count,
        rejectedMalformedFrames: rejectedFrames))
    collective.barrier()
}
