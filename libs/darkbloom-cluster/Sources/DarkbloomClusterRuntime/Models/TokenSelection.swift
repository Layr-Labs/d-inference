import Foundation

/// One sequence per measured run or warmup. Invalid local metadata is carried
/// in the collective so both ranks reject it, instead of one peer continuing.
struct TokenSelectionSequence {
    let sequence: Int
    let vocabularySize: Int
    let outputCount: Int
    private(set) var nextStep = 0
    private static let limit = Int(Int32.max) / 2
    private static let tag: Int32 = 73

    func payload(localArgmax: Int, sequence requestedSequence: Int, step: Int, rank: Int) -> [Int32] {
        func encoded(_ value: Int) -> Int32 {
            (-Self.limit...Self.limit).contains(value) ? Int32(value) : 0
        }
        let valid = (0..<2).contains(rank) && requestedSequence == sequence && step == nextStep
            && (-Self.limit...Self.limit).contains(sequence)
            && (1...Self.limit).contains(vocabularySize) && (1...Self.limit).contains(outputCount)
            && (0..<outputCount).contains(step) && (0..<vocabularySize).contains(localArgmax)
        return [Self.tag, encoded(requestedSequence), encoded(step), encoded(vocabularySize),
                encoded(outputCount), rank == 0 && valid ? Int32(localArgmax) : 0, valid ? 1 : 0]
    }

    mutating func accept(_ sum: [Int32], sequence requestedSequence: Int, step: Int) throws -> Int {
        guard requestedSequence == sequence, step == nextStep,
            (-Self.limit...Self.limit).contains(sequence),
            (1...Self.limit).contains(vocabularySize), (1...Self.limit).contains(outputCount),
            (0..<outputCount).contains(step), sum.count == 7,
            sum[0] == Self.tag * 2, sum[1] == Int32(sequence * 2), sum[2] == Int32(step * 2),
            sum[3] == Int32(vocabularySize * 2), sum[4] == Int32(outputCount * 2), sum[6] == 2,
            (0..<vocabularySize).contains(Int(sum[5]))
        else { throw ProbeError("Ranks disagree on token selection sequence, step, vocabulary, count or token bounds") }
        nextStep += 1
        return Int(sum[5])
    }
}
