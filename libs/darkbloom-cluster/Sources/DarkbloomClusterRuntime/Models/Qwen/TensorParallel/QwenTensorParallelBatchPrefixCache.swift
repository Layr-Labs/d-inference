import Foundation
import MLX

/// Immutable compact roots; no snapshot refers to mutable native page storage.
protocol QwenTensorParallelPrefixSnapshot {
    var committedTokens: Int { get }
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

final class QwenTensorParallelSnapshotCache<Snapshot: QwenTensorParallelPrefixSnapshot> {
    static var maximumEntries: Int { 32 }
    let enabled: Bool
    let budgetBytes: Int
    private struct Entry { let state: Snapshot; var lastUse: UInt64 }
    private var entries: [String: Entry] = [:]
    private var clock: UInt64 = 0
    private(set) var bytesInUse = 0

    init(enabled: Bool, budgetBytes: Int) {
        self.enabled = enabled && budgetBytes > 0; self.budgetBytes = max(0, budgetBytes)
    }
    static func candidates(promptCount: Int, chunkSize: Int, maximumTokens: Int) -> [Int] {
        guard promptCount > 1, chunkSize > 0, maximumTokens > 0 else { return [] }
        let last = min(promptCount - 1, maximumTokens) / chunkSize * chunkSize
        guard last > 0 else { return [] }
        return Array(stride(from: chunkSize, through: last, by: chunkSize).suffix(maximumEntries))
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
    @discardableResult func insert(key: String, state: Snapshot) -> Bool {
        guard enabled, state.allocatedBytes > 0, state.allocatedBytes <= budgetBytes else { return false }
        if let old = entries.removeValue(forKey: key) { bytesInUse -= old.state.allocatedBytes }
        while entries.count >= Self.maximumEntries || bytesInUse > budgetBytes - state.allocatedBytes {
            guard let key = entries.min(by: { $0.value.lastUse < $1.value.lastUse })?.key,
                  let old = entries.removeValue(forKey: key) else { break }
            bytesInUse -= old.state.allocatedBytes
        }
        clock &+= 1; entries[key] = .init(state: state, lastUse: clock); bytesInUse += state.allocatedBytes
        return true
    }
    func sweep() { entries.removeAll(); bytesInUse = 0 }
}
