import Foundation
import MLX
import MLXLLM

/// One rank's prompt-prefix cache under GLM tensor parallel: the rank's stage
/// cache (its own heads' KDA state and the replicated DSA latents) at a
/// prompt's last whole chunk boundary, kept in memory, with the NextN history
/// at the same boundary when the runtime decodes speculatively (so a restored
/// prefix proposes as well as a prefilled one). The KDA state divides by
/// heads, so an entry never crosses the cable and is useless to the other
/// rank.
///
/// As `QwenTensorParallelPrefixCache`: an entry is found only under the scope
/// it was stored with (the load agreement) and the exact prompt tokens up to
/// its length; restore is both-or-neither (`QwenTensorParallelPrefixCache.agree`,
/// one sealed vote), and entries give way (`yieldingMemory`) before a
/// reservation or a running request is refused, and while idle under host
/// memory pressure (`sweep`). No SSD tier yet.
///
/// Bytes: an entry counts the buffers it keeps alive, not its logical
/// arrays. The DSA histories grow with geometric spare columns and a copy
/// shares that storage, so each entry keeps an exact copy of them instead
/// (`contiguous` copies a view whose buffer is larger than it by more than
/// 16 KiB); the NextN history is the checkpoint's own and is counted with its
/// spare columns. `budgetBytes` bounds what the entries hold.
///
/// Paged histories (`GLM5NextTensorParallelPagedKV.swift`): an entry shares
/// the request's pages instead of copying them (a request restored from it
/// writes past them, copying only a shared partial page), and counts every
/// page it holds, shared or not, beside its KDA state's buffers.
final class GLM5NextTensorParallelPrefixCache {
    private struct Entry {
        let key: String
        let length: Int
        let cache: GLM5NextTextStageCache
        let mtp: GLM5NextMTPCheckpoint?
        let bytes: Int
        var used: UInt64
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var clock: UInt64 = 0
    let budgetBytes: Int
    var enabled: Bool { budgetBytes > 0 }
    private(set) var bytesInUse = 0

    init(budgetBytes: Int) { self.budgetBytes = max(0, budgetBytes) }

    var count: Int { lock.withLock { entries.count } }

    /// The chunk boundaries before the final token that this rank holds for `prompt`.
    func heldBoundaries(scope: String, prompt: [Int], chunk: Int) -> [Bool] {
        let candidates = QwenTensorParallelPrefixCache.candidates(promptCount: prompt.count, chunk: chunk)
        return lock.withLock {
            candidates.map { entries[QwenTensorParallelPrefixCache.key(scope: scope, prompt: prompt, length: $0)] != nil }
        }
    }

    /// A copy of the entry at `length` (the request writes its own copy) and
    /// its NextN history, which is immutable and restored by copy.
    func restore(scope: String, prompt: [Int], length: Int)
        -> (cache: GLM5NextTextStageCache, mtp: GLM5NextMTPCheckpoint?)? {
        lock.withLock {
            let key = QwenTensorParallelPrefixCache.key(scope: scope, prompt: prompt, length: length)
            guard var entry = entries[key] else { return nil }
            clock += 1; entry.used = clock; entries[key] = entry
            return (entry.cache.copy(), entry.mtp)
        }
    }

    /// Keeps a copy of `cache` (evaluated, its DSA histories exact) and the
    /// NextN history `mtp` at `length`, evicting the oldest entries beyond the
    /// budget; nothing when it alone exceeds the budget.
    func store(scope: String, prompt: [Int], length: Int, cache: GLM5NextTextStageCache,
               mtp: GLM5NextMTPCheckpoint? = nil) {
        guard enabled else { return }
        // An entry above the budget is never kept: skip it before its compact
        // copy exists (a long prompt's would be tens of GB beside the request,
        // outside its charge). The logical bytes are a lower bound of the
        // buffers below, so every entry kept before is still kept. Paged
        // histories count their pages (reading `state` would gather them).
        let logical = cache.heldPages > 0 ? cache.pagedBytes : cache.layers.reduce(0) { total, layer in
            total + ((layer as? GLM5NextDSACache)?.state.reduce(0) { $0 + $1.nbytes } ?? 0)
        }
        guard logical <= budgetBytes else { return }
        let kept = cache.copy()
        let paged = kept.heldPages > 0
        if !paged { for case let history as GLM5NextDSACache in kept.layers { Self.compact(history) } }
        let arrays = kept.layers.flatMap { $0.innerState() } + (mtp?.arrays ?? [])
        eval(arrays)
        // Paged: the histories' roots are their page launches' fences; their pages count instead.
        let bytes = Self.bufferBytes(arrays) + (paged ? kept.pagedBytes + (mtp?.pagedBytes ?? 0) : 0)
        guard bytes <= budgetBytes else { return }
        lock.withLock {
            let key = QwenTensorParallelPrefixCache.key(scope: scope, prompt: prompt, length: length)
            if let old = entries[key] { bytesInUse -= old.bytes }
            clock += 1
            entries[key] = .init(key: key, length: length, cache: kept, mtp: mtp, bytes: bytes, used: clock)
            bytesInUse += bytes
            while bytesInUse > budgetBytes, let oldest = entries.values.min(by: { $0.used < $1.used }) {
                entries[oldest.key] = nil; bytesInUse -= oldest.bytes
            }
        }
    }

    /// Points `history` (a copy's own object) at exact copies of its logical
    /// columns where its storage carries spare ones; lazy until evaluated.
    static func compact(_ history: GLM5NextDSACache) {
        history.state = history.state.map { $0.contiguous() }
    }

    /// Bytes of the buffers behind evaluated `arrays` (a view counts its whole
    /// buffer; one shared by two arrays counts twice, never less).
    static func bufferBytes(_ arrays: [MLXArray]) -> Int {
        arrays.reduce(0) { total, array in
            total + max(array.nbytes, (try? array.evaluatedBufferInfo())?.allocatedBytes ?? 0)
        }
    }

    /// Runs `body`; on a refusal, gives MLX's freed-buffer cache back and runs
    /// it again, then drops every entry and runs it once more.
    func yieldingMemory<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch {
            var refusal = error
            if ClusterIdleMemory.releaseFreedBuffers() > 0 {
                do { return try body() } catch let again { refusal = again }
            }
            guard lock.withLock({ !entries.isEmpty }) else { throw refusal }
            sweep(); Memory.clearCache()
            return try body()
        }
    }

    /// Drops every entry; returns the bytes they held.
    @discardableResult
    func sweep() -> Int {
        lock.withLock {
            let held = bytesInUse
            entries.removeAll(); bytesInUse = 0
            return held
        }
    }
}
