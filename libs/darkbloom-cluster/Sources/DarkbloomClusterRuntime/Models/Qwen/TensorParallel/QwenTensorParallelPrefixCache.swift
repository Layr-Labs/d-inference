import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// One rank's prompt-prefix cache under tensor parallel: the request state of
/// this rank's own heads (attention keys and values of its key/value heads,
/// Gated DeltaNet convolution and recurrent state of its heads) at a prompt's
/// last whole chunk boundary, kept in memory. The state divides by heads, so
/// a rank's entry never crosses the cable and is useless to the other rank.
///
/// Scope: an entry is found only under the scope it was stored with (the
/// load agreement, which binds the model, plan, shares and both builds, and
/// this rank's verified storage commitment) and the exact prompt tokens up to
/// its length. Restore is both-or-neither (`agree`): the ranks vote the
/// boundaries each holds for the prompt in one sealed reduction and restore
/// the longest one BOTH hold; with none, both prefill cold. Every failure
/// sweeps the cache (the peer may hold something else now).
///
/// Memory: entries give way first (`yieldingMemory`) before a reservation or
/// a running request is refused, oldest first. The SSD tier is not wired for
/// tensor parallel yet (each rank would keep its own shard's records under
/// the same scope; see STATUS).
final class QwenTensorParallelPrefixCache {
    private struct Entry {
        let key: String
        let length: Int
        let state: [any KVCache]
        let bytes: Int
        var used: UInt64
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var clock: UInt64 = 0
    let budgetBytes: Int
    var enabled: Bool { budgetBytes > 0 }
    private(set) var bytesInUse = 0
    /// At most this many boundaries are voted (the last ones before the final token).
    static let maximumVotedBoundaries = 32

    init(budgetBytes: Int) { self.budgetBytes = max(0, budgetBytes) }

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

    /// The chunk boundaries before the final token that this rank holds for `prompt`.
    func heldBoundaries(scope: String, prompt: [Int], chunk: Int) -> [Bool] {
        let candidates = Self.candidates(promptCount: prompt.count, chunk: chunk)
        return lock.withLock { candidates.map { entries[Self.key(scope: scope, prompt: prompt, length: $0)] != nil } }
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

    func restore(scope: String, prompt: [Int], length: Int) -> [any KVCache]? {
        lock.withLock {
            let key = Self.key(scope: scope, prompt: prompt, length: length)
            guard var entry = entries[key] else { return nil }
            clock += 1; entry.used = clock; entries[key] = entry
            return entry.state.map { $0.copy() }
        }
    }

    /// Keeps a copy of `cache` (evaluated) at `length`, evicting the oldest
    /// entries beyond the budget; nothing when it alone exceeds the budget.
    func store(scope: String, prompt: [Int], length: Int, cache: [any KVCache]) {
        guard enabled else { return }
        let state = cache.map { $0.copy() }
        let arrays = state.flatMap { $0.innerState() }
        eval(arrays)
        // Paged attention histories share the request's pages (their roots
        // are fences): the entry counts every page it holds.
        let bytes = arrays.reduce(0) { $0 + $1.nbytes }
            + state.reduce(0) { $0 + (($1 as? PagedAttentionKVCache)?.pagedBytes ?? 0) }
        guard bytes <= budgetBytes else { return }
        lock.withLock {
            let key = Self.key(scope: scope, prompt: prompt, length: length)
            if let old = entries[key] { bytesInUse -= old.bytes }
            clock += 1
            entries[key] = .init(key: key, length: length, state: state, bytes: bytes, used: clock)
            bytesInUse += bytes
            evict(toFit: 0)
        }
    }

    private func evict(toFit extra: Int) {
        while bytesInUse + extra > budgetBytes, let oldest = entries.values.min(by: { $0.used < $1.used }) {
            entries[oldest.key] = nil; bytesInUse -= oldest.bytes
        }
    }

    /// Runs `body`; on a refusal, drops every entry and runs it once more.
    func yieldingMemory<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch {
            guard lock.withLock({ !entries.isEmpty }) else { throw error }
            sweep(); Memory.clearCache()
            return try body()
        }
    }

    func sweep() { lock.withLock { entries.removeAll(); bytesInUse = 0 } }
}
