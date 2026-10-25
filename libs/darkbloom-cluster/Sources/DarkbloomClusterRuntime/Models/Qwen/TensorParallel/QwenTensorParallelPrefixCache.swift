import Foundation
import MLX

/// The prompt-prefix vote of a tensor-parallel owner whose entries a rank
/// keeps at chunk boundaries (`GLM5NextTensorParallelPrefixCache`). A rank's
/// entry holds its own heads' state, never crosses the cable and is useless
/// to the other rank. The Qwen TP owner's request-owned lanes keep theirs in
/// `QwenTensorParallelBatchPrefixCache`.
///
/// Scope: an entry is found only under the scope it was stored with (the
/// load agreement, which binds the model, plan, shares and both builds, and
/// this rank's verified storage commitment) and the exact prompt tokens up to
/// its length. Restore is both-or-neither (`agree`): the ranks vote the
/// boundaries each holds for the prompt in one sealed reduction and restore
/// the longest one BOTH hold; with none, both prefill cold.
enum QwenTensorParallelPrefixCache {
    /// At most this many boundaries are voted (the last ones before the final token).
    static let maximumVotedBoundaries = 32

    /// A conservative default: an eighth of what the allocator may hold beyond
    /// the loaded model, at most 8 GiB.
    static func defaultBudget(activeLoaded: Int) -> Int {
        let limit = Memory.memoryLimit
        return max(0, min(8 << 30, (limit - activeLoaded) / 8))
    }

    static func key(scope: String, prompt: [Int], length: Int) -> String {
        var text = scope + "|\(length)|"
        text += prompt.prefix(length).map(String.init).joined(separator: ",")
        return sha256(Data(text.utf8))
    }

    /// `key(scope:prompt:length:)` for each of `lengths`, joining the prompt
    /// once: each key hashes the same bytes (scope, length, the prefix's
    /// tokens joined), taken from the one joined text.
    static func keys(scope: String, prompt: [Int], lengths: [Int]) -> [String] {
        guard let longest = lengths.max(), longest > 0 else {
            return lengths.map { key(scope: scope, prompt: prompt, length: $0) }
        }
        var joined = [UInt8]()
        joined.reserveCapacity(longest * 7)
        var ends = [Int](repeating: 0, count: longest + 1)
        for index in 0 ..< min(longest, prompt.count) {
            if index > 0 { joined.append(44) }
            joined.append(contentsOf: String(prompt[index]).utf8)
            ends[index + 1] = joined.count
        }
        return lengths.map { length in
            guard length >= 0, length <= prompt.count else { return key(scope: scope, prompt: prompt, length: length) }
            var bytes = Array((scope + "|\(length)|").utf8)
            bytes.append(contentsOf: joined[0 ..< ends[length]])
            return sha256(Data(bytes))
        }
    }

    /// Ascending chunk boundaries before the final token (the last `maximumVotedBoundaries`).
    static func candidates(promptCount: Int, chunk: Int) -> [Int] {
        guard chunk > 0, promptCount > 1 else { return [] }
        let all = Array(stride(from: chunk, through: promptCount - 1, by: chunk))
        return Array(all.suffix(maximumVotedBoundaries))
    }

    /// Both ranks: the longest boundary both hold, or nil. One sealed
    /// reduction of a fixed-size vote (each rank adds 1 where it holds one).
    static func agree(held: [Bool], group: QwenTensorParallelReduction, candidates: [Int]) throws -> Int? {
        var votes = [Float](repeating: 0, count: maximumVotedBoundaries)
        for (index, value) in held.enumerated() where value && index < votes.count { votes[index] = 1 }
        let summed = group.allSum(MLXArray(votes))
        try MLX.withError { error in eval(summed); try error.check() }
        let all = summed.asArray(Float.self)
        let both = all.indices.filter { $0 < candidates.count && all[$0] >= Float(group.size) }
        return both.last.map { candidates[$0] }
    }
}
