import Foundation
import MLX
import MLXLMCommon

/// One request's prefix capture on one MiMo or GLM stage: the frontiers it
/// was asked to keep, what it kept within its limit, and the copies.
///
/// The family's snapshot splits a stage's state at a frontier in two. Rows
/// that grow by one per committed position (MiMo's full-attention rows, GLM's
/// DSA histories) are captured once, at the deepest kept frontier (the split
/// frontier), and shallower frontiers view a prefix of that copy, exactly as
/// the dense stage session keeps its attention copy. State that is a
/// frontier's own (MiMo's sliding tails, GLM's KDA state) is captured at
/// every kept frontier.
final class ClusterStagePrefixCapture {
    /// A stage's state at one frontier: the growing rows and the frontier's
    /// own pairs, both keyed by global layer, and the bytes one frontier's own
    /// state is charged. Nil when the state is not storable at this frontier.
    typealias Snapshot = (_ caches: [KVCache], _ globalLayers: [Int], _ frontier: Int) throws
        -> (shared: [Int: (keys: MLXArray, values: MLXArray)], own: [Int: (conv: MLXArray, ssm: MLXArray)],
            ownChargeBytes: Int)?

    /// Prompt frontiers at which this request may keep its state (grid
    /// multiples of the stride and the split frontier `promptCount - 1`).
    let frontiers: Set<Int>
    /// Most bytes this request's captures may hold together (its charge).
    var limitBytes: Int?
    var maximumFrontiers = Int.max
    /// Measured at the first capture frontier; decides what is kept.
    private(set) var cost: QwenStagePrefixCaptureCost?
    private var kept: Set<Int>?
    private(set) var withdrawn = false
    private let snapshot: Snapshot
    private var own: [Int: [Int: (conv: MLXArray, ssm: MLXArray)]] = [:]
    private var deepest: (committed: Int, layers: [Int: (keys: MLXArray, values: MLXArray)])?
    /// Frontiers not captured because the snapshot could not store them there.
    private(set) var skipped: [Int] = []

    init(frontiers: Set<Int>, snapshot: @escaping Snapshot) {
        self.frontiers = frontiers
        self.snapshot = snapshot
    }

    /// After the frame that committed `frontier` (`caches` are the request's).
    func capture(at frontier: Int, caches: [KVCache], globalLayers: [Int]) throws {
        guard frontiers.contains(frontier), !withdrawn else { return }
        guard let state = try snapshot(caches, globalLayers, frontier) else {
            skipped.append(frontier); return
        }
        let planned = frontiers.sorted()
        if kept == nil {
            let rows = state.shared.values.reduce(0) { $0 + $1.keys.nbytes + $1.values.nbytes }
            let measured = QwenStagePrefixCaptureCost(attentionBytesPerToken: (rows + frontier - 1) / frontier,
                recurrentBytesPerFrontier: state.ownChargeBytes, historyBytesPerToken: 0)
            cost = measured
            kept = measured.kept(planned, limit: limitBytes ?? Int.max, maximum: maximumFrontiers)
        }
        guard kept?.contains(frontier) == true else { return }
        own[frontier] = state.own
        if frontier == planned.last { deepest = (frontier, state.shared) }
    }

    /// The kept frontiers' states, ascending. Empty unless the deepest was
    /// reached (a request that never reached its split frontier keeps nothing).
    func states() -> [QwenStagePrefixState] {
        guard let deepest, !withdrawn else { return [] }
        return own.keys.sorted().compactMap { frontier in
            guard frontier <= deepest.committed, let pairs = own[frontier] else { return nil }
            let rows = deepest.layers.mapValues { pair -> (keys: MLXArray, values: MLXArray) in
                frontier == deepest.committed ? pair
                    : (keys: pair.keys[0..., 0..., 0..<frontier, 0...], values: pair.values[0..., 0..., 0..<frontier, 0...])
            }
            return QwenStagePrefixState(committedTokens: frontier, attention: rows, recurrent: pairs)
        }
    }

    /// Bytes of the shared copy the kept states view together.
    var sharedBytes: Int { deepest?.layers.values.reduce(0) { $0 + $1.keys.nbytes + $1.values.nbytes } ?? 0 }

    /// Whether this request keeps its prompt: the deepest frontier was captured.
    var keepsPrompt: Bool { !withdrawn && deepest != nil }

    /// The running check withdrew this capture: let go of it, capture no more.
    func withdraw() { withdrawn = true; own.removeAll(); deepest = nil }

    func discard() { own.removeAll(); deepest = nil; kept = nil }
}
