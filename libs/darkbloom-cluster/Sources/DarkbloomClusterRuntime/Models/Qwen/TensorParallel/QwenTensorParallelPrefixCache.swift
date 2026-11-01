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
/// the longest one BOTH hold; with none, both prefill cold. A boundary a rank
/// holds only on its SSD tier (`GLM5NextTensorParallelPrefixDisk`) counts
/// too, and is then restored only after a second sealed exchange (`confirm`)
/// shows both ranks have it.
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

    /// One rank's vote for a candidate boundary: 1 held in memory, 3 held
    /// only as a complete SSD record, 0 not held. Without SSD records the
    /// words are the memory-only vote's.
    static func offer(inMemory: Bool, onDisk: Bool) -> Float { inMemory ? 1 : onDisk ? 3 : 0 }

    /// The longest candidate both of two ranks offer, and whether either
    /// offers it only from its SSD tier; nil when none. `sums`: the ranks'
    /// offers summed per candidate, so 2 (both in memory), 4 or 6 (both, from
    /// SSD at least once); 1 and 3 are one rank's alone.
    static func agreed(sums: [Float], candidates: [Int]) -> (boundary: Int, ssd: Bool)? {
        let both = sums.indices.filter { $0 < candidates.count && [Float(2), 4, 6].contains(sums[$0]) }
        return both.last.map { (candidates[$0], sums[$0] > 2) }
    }

    /// Both ranks: the longest boundary both hold (`agreed`), or nil. One
    /// sealed reduction of a fixed-size vote of `offers` (`offer`, per candidate).
    static func agree(offers: [Float], group: QwenTensorParallelReduction, candidates: [Int]) throws
        -> (boundary: Int, ssd: Bool)? {
        guard group.size == 2 else { throw ProbeError("The tensor-parallel prefix vote takes two ranks") }
        var votes = [Float](repeating: 0, count: maximumVotedBoundaries)
        for (index, value) in offers.enumerated() where index < votes.count { votes[index] = value }
        let summed = group.allSum(MLXArray(votes))
        try MLX.withError { error in eval(summed); try error.check() }
        return agreed(sums: summed.asArray(Float.self), candidates: candidates)
    }

    /// The second exchange of a boundary agreed from an SSD record: true when
    /// both ranks have its state (`local`, this rank's), else both prefill
    /// from zero.
    static func confirm(_ local: Bool, group: QwenTensorParallelReduction) throws -> Bool {
        let summed = group.allSum(MLXArray([Float(local ? 1 : 0)]))
        try MLX.withError { error in eval(summed); try error.check() }
        return summed.asArray(Float.self) == [Float(group.size)]
    }
}
