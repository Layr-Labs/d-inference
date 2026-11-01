import Foundation
import MLX

/// Immutable compact roots; no snapshot refers to mutable native page storage.
protocol QwenTensorParallelPrefixSnapshot {
    var committedTokens: Int { get }
    /// Bytes this state holds alone. States inserted together as one capture
    /// also view that capture's shared bytes, counted once for all of them.
    var allocatedBytes: Int { get }
}

struct QwenTensorParallelBatchPrefixState: QwenTensorParallelPrefixSnapshot {
    let committedTokens: Int
    let attention: [Int: (keys: MLXArray, values: MLXArray)]
    let recurrent: [Int: (conv: MLXArray, ssm: MLXArray)]
    let allocatedBytes: Int
}

/// Serial native-executor cache. Control threads never read or mutate it.
/// Keys bind the loaded shard agreement, backend, prompt grid and authenticated
/// media identity. A local hit is only an offer: restoration requires a sealed
/// two-rank vote. Insertion happens after bilateral clean native retirement.
typealias QwenTensorParallelBatchPrefixCache = QwenTensorParallelSnapshotCache<QwenTensorParallelBatchPrefixState>

/// Retention is by byte budget, as the pipeline's `QwenStagePrefixCache`:
/// the owner sets it from the room it measures (`setBudget`), and a zero
/// budget keeps nothing resident while votes still count SSD records. One
/// capture's boundaries form a group: their shared attention copy is
/// counted once and freed with the group's last entry. Under the budget the
/// shallower boundaries of other captures go first (least recently used
/// first), then the newest capture's, then whole captures, so an exact
/// repeat's deepest boundary outlives every other. `yieldingMemory` frees
/// entries before a live memory gate refuses.
final class QwenTensorParallelSnapshotCache<Snapshot: QwenTensorParallelPrefixSnapshot> {
    /// Entries and captures kept at most (the pipeline's limits); bytes bound first.
    static var maximumEntries: Int { 1024 }
    static var maximumGroups: Int { 64 }
    /// Boundaries one vote carries at most (the deepest ones before the final token).
    static var maximumVoted: Int { 512 }
    let enabled: Bool
    private(set) var budgetBytes: Int
    private struct Entry { let state: Snapshot; var lastUse: UInt64; let group: UInt64 }
    private struct Group { let sharedBytes: Int; var entries: Int; let deepest: Int }
    private var entries: [String: Entry] = [:]
    private var groups: [UInt64: Group] = [:]
    private var nextGroup: UInt64 = 0
    private var clock: UInt64 = 0
    private(set) var bytesInUse = 0
    private(set) var evictions = 0

    init(enabled: Bool, budgetBytes: Int) {
        self.enabled = enabled; self.budgetBytes = max(0, budgetBytes)
    }
    /// Every boundary on the request's chunk grid before its final token, at
    /// most `maximumTokens` deep (the deepest `maximumVoted` of them).
    static func candidates(promptCount: Int, chunkSize: Int, maximumTokens: Int) -> [Int] {
        guard promptCount > 1, chunkSize > 0, maximumTokens > 0 else { return [] }
        let last = min(promptCount - 1, maximumTokens) / chunkSize * chunkSize
        guard last > 0 else { return [] }
        return Array(stride(from: chunkSize, through: last, by: chunkSize).suffix(maximumVoted))
    }
    static func keys(scope: String, tokens: [Int], frontiers: [Int]) -> [Int: String] {
        QwenStagePrefixKeys.keys(scope: scope, tokens: tokens, frontiers: Set(frontiers))
    }
    func held(keys: [Int: String], candidates: [Int]) -> [Float] {
        candidates.map { enabled && keys[$0].flatMap({ entries[$0] }) != nil ? 1 : 0 }
    }
    /// Whether this rank's resident tier holds `key` at `frontier`.
    func holds(key: String, frontier: Int) -> Bool {
        enabled && entries[key].map { $0.state.committedTokens == frontier } == true
    }
    static func agreed(candidates: [Int], votes: [Float]) throws -> Int {
        guard candidates.count == votes.count, votes.allSatisfy({ $0 == 0 || $0 == 1 || $0 == 2 }) else {
            throw ProbeError("Qwen TP prefix vote differs from the bounded candidate grid")
        }
        return zip(candidates, votes).filter { $0.1 == 2 }.map(\.0).max() ?? 0
    }
    func restore(key: String, frontier: Int) throws -> Snapshot {
        guard enabled, var entry = entries[key], entry.state.committedTokens == frontier else {
            throw ProbeError("Qwen TP mutually held prefix disappeared")
        }
        clock &+= 1; entry.lastUse = clock; entries[key] = entry
        return entry.state
    }

    /// One state that owns all its bytes (an SSD read, an assistant frontier).
    @discardableResult func insert(key: String, state: Snapshot) -> Bool {
        !insert([(key, state)], sharedBytes: 0).isEmpty
    }

    /// One capture's states, viewing `sharedBytes` together. Returns the
    /// boundaries kept: those that fit the budget with the deepest (none
    /// when the deepest does not fit).
    @discardableResult func insert(_ states: [(key: String, state: Snapshot)], sharedBytes: Int) -> [Int] {
        // An attention-only state holds nothing of its own beside the shared copy.
        let sorted = states.filter { $0.state.allocatedBytes >= 0 }.sorted { $0.state.committedTokens < $1.state.committedTokens }
        guard enabled, let deepest = sorted.last, sharedBytes >= 0, sharedBytes + deepest.state.allocatedBytes > 0 else { return [] }
        var total = sharedBytes + deepest.state.allocatedBytes
        guard total <= budgetBytes else { return [] }
        var chosen = [deepest]
        for entry in sorted.dropLast().reversed() where total + entry.state.allocatedBytes <= budgetBytes {
            total += entry.state.allocatedBytes; chosen.append(entry)
        }
        for entry in chosen { if let old = entries[entry.key] { remove(entry.key, old) } }
        let group = nextGroup; nextGroup &+= 1
        evict(reserving: total, adding: chosen.count)
        for entry in chosen.reversed() {
            clock &+= 1
            entries[entry.key] = .init(state: entry.state, lastUse: clock, group: group)
            bytesInUse += entry.state.allocatedBytes
        }
        groups[group] = .init(sharedBytes: sharedBytes, entries: chosen.count, deepest: deepest.state.committedTokens)
        bytesInUse += sharedBytes
        return chosen.map(\.state.committedTokens).sorted()
    }

    /// The owner's measured budget; entries beyond it go now.
    func setBudget(_ bytes: Int) { budgetBytes = max(0, bytes); evict(reserving: 0, adding: 0) }

    /// Drops the next entry `victim` names; false when there is none.
    @discardableResult func evictLeastRecentlyUsed() -> Bool {
        guard let (key, entry) = victim() else { return false }
        remove(key, entry); evictions += 1
        return true
    }

    /// Runs `check` (a live memory gate); while it refuses, first lets the
    /// SSD writer finish what it holds, then drops entries one at a time and
    /// returns their buffers. Only a refusal with nothing left to free throws.
    func yieldingMemory(disk: QwenStagePrefixDiskTier?, _ check: () throws -> Void) throws {
        var drained = disk == nil, evicted = 0
        while true {
            do {
                try check()
                if evicted > 0 { log("darkbloom-prefix-v1 family=qwen mode=tensor_parallel pressure-evicted=\(evicted) entries=\(entries.count) admitted=true") }
                return
            } catch {
                if !drained, let disk {
                    drained = true
                    _ = disk.drain(timeoutSeconds: 10)
                } else if enabled, evictLeastRecentlyUsed() {
                    evicted += 1
                } else {
                    if evicted > 0 { log("darkbloom-prefix-v1 family=qwen mode=tensor_parallel pressure-evicted=\(evicted) entries=\(entries.count) admitted=false") }
                    throw error
                }
                Stream.gpu.synchronize()
                Memory.clearCache()
            }
        }
    }

    func sweep() { entries.removeAll(); groups.removeAll(); bytesInUse = 0 }

    /// Boundaries held now (tests and diagnostics).
    var heldFrontiers: [Int] { entries.values.map(\.state.committedTokens).sorted() }

    private func remove(_ key: String, _ entry: Entry) {
        entries.removeValue(forKey: key)
        bytesInUse -= entry.state.allocatedBytes
        guard var group = groups[entry.group] else { return }
        group.entries -= 1
        if group.entries <= 0 { groups.removeValue(forKey: entry.group); bytesInUse -= group.sharedBytes }
        else { groups[entry.group] = group }
    }

    private func evict(reserving: Int, adding: Int) {
        while groups.count + (adding > 0 ? 1 : 0) > Self.maximumGroups || entries.count + adding > Self.maximumEntries
                || (bytesInUse > 0 && bytesInUse > budgetBytes - min(budgetBytes, reserving)),
              let (key, entry) = victim() {
            remove(key, entry); evictions += 1
        }
    }

    /// The least recently used shallower boundary of a capture other than the
    /// newest, then the newest capture's shallowest, then the least recently
    /// used entry (a whole capture's deepest boundary).
    private func victim() -> (String, Entry)? {
        guard let newest = entries.values.max(by: { $0.lastUse < $1.lastUse })?.group else { return nil }
        func shallow(_ entry: Entry) -> Bool { entry.state.committedTokens < (groups[entry.group]?.deepest ?? 0) }
        let order: ((key: String, value: Entry), (key: String, value: Entry)) -> Bool = {
            ($0.value.lastUse, $0.value.state.committedTokens) < ($1.value.lastUse, $1.value.state.committedTokens)
        }
        if let other = entries.filter({ $0.value.group != newest && shallow($0.value) }).min(by: order) { return (other.key, other.value) }
        if let own = entries.filter({ $0.value.group == newest && shallow($0.value) })
            .min(by: { $0.value.state.committedTokens < $1.value.state.committedTokens }) { return (own.key, own.value) }
        return entries.min(by: order).map { ($0.key, $0.value) }
    }
}
