import Foundation
import MLX

/// One stage's committed request state at an exact prompt frontier, kept on
/// the rank that computed it. Arrays are keyed by the model's global layer
/// index, as a hand-off's are. Attention arrays hold exactly
/// `committedTokens` positions; recurrent arrays are the confirmed state after
/// exactly that many tokens.
struct QwenStagePrefixState {
    let committedTokens: Int
    let attention: [Int: (keys: MLXArray, values: MLXArray)]
    let recurrent: [Int: (conv: MLXArray, ssm: MLXArray)]
    /// On the decoding rank of a speculative pair: the head's trusted history
    /// at this frontier, so that a request restoring it drafts from the whole
    /// prompt as a cold request does, not only from its computed suffix.
    var speculativeHistory: QwenMTPPrefixHistory? = nil

    var adopted: QwenLayerStageAdoptedState {
        .init(committedTokens: committedTokens, attention: attention, recurrent: recurrent)
    }
}

/// Rank-local resident prompt-prefix cache of one loaded stage.
///
/// Both ranks key an entry by the same string: the request scope both ranks
/// agreed (plan, artifact, storage, arithmetic, profile, chunk size) and the
/// prompt tokens before the frontier. Each rank stores only its own stage's
/// state under that key. Nothing here decides reuse: the two ranks exchange
/// the frontiers they hold and reuse only one both hold
/// (`QwenStagePrefixAgreement`).
///
/// Eviction is least-recently-used by entry count, never by bytes. Entries
/// are inserted only after a request retired cleanly on both ranks. A sweep
/// drops every entry; the runtime sweeps before it releases its model and
/// after a failed request.
public final class QwenStagePrefixCache: @unchecked Sendable {
    /// One entry is one frontier of one prompt: its recurrent state (tens of
    /// MB a rank for the dense Qwen models) and a view of its prompt's
    /// attention copy, which is shared by every frontier of that prompt.
    public static let defaultEntryLimit = 32
    /// Grid frontiers kept besides `promptCount - 1`: multiples of this many
    /// tokens (rounded up to a multiple of the request's chunk size). Keeping
    /// one costs no copy (a reference to an immutable confirmed state) but
    /// keeps that state alive: about 110 MB a frontier on the 27B's larger
    /// stage, so the grid is coarser than the chunk size.
    public static let defaultStrideTokens = 512
    /// Most frontiers one rank offers its peer for one request.
    static let maximumOffered = 32

    /// The diagnosis switch: off means this rank offers nothing and asks for
    /// no split, so the pair runs exactly as it did before the cache existed.
    public let enabled: Bool
    public let entryLimit: Int
    public let strideTokens: Int

    private struct Entry {
        let key: String
        let scope: String
        let state: QwenStagePrefixState
        var lastUse: UInt64
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var clock: UInt64 = 0
    private(set) var evictions = 0

    public init(enabled: Bool = true, entryLimit: Int = QwenStagePrefixCache.defaultEntryLimit,
                strideTokens: Int = QwenStagePrefixCache.defaultStrideTokens) {
        self.enabled = enabled
        self.entryLimit = max(1, min(entryLimit, 1024))
        self.strideTokens = max(1, strideTokens)
    }

    /// From the worker's environment. `DARKBLOOM_CLUSTER_PREFIX_CACHE=off`
    /// turns it off for diagnosis; anything else (or nothing) leaves it on.
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment)
        -> QwenStagePrefixCache {
        let value = environment["DARKBLOOM_CLUSTER_PREFIX_CACHE"]?.lowercased()
        let off = value == "off" || value == "0" || value == "false" || value == "no"
        return QwenStagePrefixCache(enabled: !off)
    }

    public var count: Int { lock.withLock { entries.count } }

    /// Frontiers on the grid of this request's chunk size.
    func stride(chunkSize: Int) -> Int {
        guard chunkSize > 0 else { return strideTokens }
        return max(1, (strideTokens + chunkSize - 1) / chunkSize) * chunkSize
    }

    static func key(scope: String, tokens: ArraySlice<Int>) -> String {
        sha256(Data(("darkbloom-cluster-prefix-v1|" + scope + "|" + qwenGenerationTokenHash(Array(tokens))).utf8))
    }

    /// Frontiers this rank holds for `tokens` under `scope`, at most
    /// `maximumFrontier`, deepest first. Does not touch recency.
    func frontiers(scope: String, tokens: [Int], maximumFrontier: Int) -> [Int] {
        guard enabled else { return [] }
        let held = lock.withLock { entries.values.filter { $0.scope == scope && $0.state.committedTokens <= maximumFrontier } }
        var keys: [Int: String] = [:]
        var found: [Int] = []
        for entry in held {
            let frontier = entry.state.committedTokens
            guard frontier > 0, frontier <= tokens.count else { continue }
            let key = keys[frontier] ?? Self.key(scope: scope, tokens: tokens[0..<frontier])
            keys[frontier] = key
            if key == entry.key { found.append(frontier) }
        }
        return Array(Set(found).sorted(by: >).prefix(Self.maximumOffered))
    }

    /// The state at `frontier` for this prompt, marking it most recently used.
    func state(scope: String, tokens: [Int], frontier: Int) -> QwenStagePrefixState? {
        guard enabled, frontier > 0, frontier <= tokens.count else { return nil }
        let key = Self.key(scope: scope, tokens: tokens[0..<frontier])
        return lock.withLock {
            guard var entry = entries[key], entry.scope == scope, entry.state.committedTokens == frontier else { return nil }
            clock += 1; entry.lastUse = clock; entries[key] = entry
            return entry.state
        }
    }

    /// Inserts states of one cleanly retired request, then evicts the least
    /// recently used entries beyond the count limit.
    func insert(scope: String, tokens: [Int], states: [QwenStagePrefixState]) {
        guard enabled else { return }
        lock.withLock {
            for state in states.sorted(by: { $0.committedTokens < $1.committedTokens }) {
                guard state.committedTokens > 0, state.committedTokens <= tokens.count else { continue }
                let key = Self.key(scope: scope, tokens: tokens[0..<state.committedTokens])
                clock += 1
                entries[key] = Entry(key: key, scope: scope, state: state, lastUse: clock)
            }
            while entries.count > entryLimit, let oldest = entries.values.min(by: { $0.lastUse < $1.lastUse }) {
                entries.removeValue(forKey: oldest.key); evictions += 1
            }
        }
    }

    /// Drops the least recently used entry; false when there is none.
    @discardableResult
    func evictLeastRecentlyUsed() -> Bool {
        lock.withLock {
            guard let oldest = entries.values.min(by: { $0.lastUse < $1.lastUse }) else { return false }
            entries.removeValue(forKey: oldest.key); evictions += 1
            return true
        }
    }

    /// Runs `check` (a live memory admission); while it refuses and entries
    /// remain, drops the least recently used entry, returns the freed buffers
    /// to the system and checks again. The cache never makes a request fail
    /// for memory: only a refusal with the cache empty is thrown.
    func yieldingMemory(_ check: () throws -> Void) throws {
        var evicted = 0
        while true {
            do {
                try check()
                if evicted > 0 { log("darkbloom-prefix-v1 pressure-evicted=\(evicted) entries=\(count) admitted=true") }
                return
            } catch {
                guard enabled, evictLeastRecentlyUsed() else {
                    if evicted > 0 { log("darkbloom-prefix-v1 pressure-evicted=\(evicted) entries=\(count) admitted=false") }
                    throw error
                }
                pressureEvictions += 1; evicted += 1
                // Buffers still referenced by finished GPU work are released
                // only after it completes; then return them to the system.
                Stream.gpu.synchronize()
                Memory.clearCache()
            }
        }
    }
    private(set) var pressureEvictions = 0

    /// Drops every entry. The arrays are released when the last reference
    /// (an entry, or a session that is adopting one) goes away.
    public func sweep() {
        lock.withLock { entries.removeAll(keepingCapacity: false) }
    }

    /// Committed frontiers currently held, for tests and diagnostics.
    var heldFrontiers: [Int] { lock.withLock { entries.values.map(\.state.committedTokens).sorted() } }
}
