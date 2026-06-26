/// ClusterBatchControl -- the per-step batch-composition control round for
/// continuous batching (Phase 3).
///
/// Continuous batching changes the active batch every step: rows finish (evict)
/// and new requests join (admit). The MLX ring is a single ordered stream, so
/// EVERY rank must agree on the new composition before each step and apply the
/// SAME `filter`/`extend` to its local per-layer batched KV caches — or the
/// caches diverge and attention silently corrupts.
///
/// The head decides the composition (which rows survive, which are admitted) and
/// broadcasts it via one `all_gather` of a fixed-width int32 vector; peers
/// contribute zeros and replay the head's decision. This mirrors the B=1
/// `exchangeRequest` control round, extended to per-step batch granularity.
///
/// Wire layout (head's slot = first BATCH_CTRL_WIDTH entries of the gather):
///   [0] command   0=step, 1=shutdown, 2=idle-keepalive
///   [1] B_next    active row count AFTER this step's evict+admit
///   [2] nKeep     surviving rows from the previous batch
///   [3] nAdmit    newly admitted rows (prefilled this step)
///   [4] prefillW  max prompt length among admitted rows (0 if none)
///   [5 ..< 5+nKeep]              keepIndices into the PREVIOUS batch (ascending)
///   [.. nAdmit blocks of]        { promptLen, leftPadding, maxTokens,
///                                  prompt token ids… } packed back-to-back
///
/// The admit cap keeps the vector fixed-width; if a step's admissions would
/// overflow, the scheduler admits fewer rows (back-pressure).

import Foundation
import MLX

/// Fixed admit-token budget per control round (caps the gather vector width).
public let BATCH_CTRL_MAX_ADMIT_TOKENS = 8192
/// Max rows ever active or admitted in one round (bounds keepIndices + headers).
public let BATCH_CTRL_MAX_ROWS = 64
/// 5 header ints + keepIndices (≤ MAX_ROWS) + nAdmit headers (3 each) + tokens.
public let BATCH_CTRL_WIDTH =
    5 + BATCH_CTRL_MAX_ROWS + BATCH_CTRL_MAX_ROWS * 3 + BATCH_CTRL_MAX_ADMIT_TOKENS

public enum ClusterBatchCommand: Int32, Sendable {
    case step = 0
    case shutdown = 1
    case idle = 2
}

/// One newly-admitted request in a composition round.
public struct ClusterAdmitRow: Sendable {
    public let promptTokens: [Int]
    public let leftPadding: Int
    public let maxTokens: Int
    public init(promptTokens: [Int], leftPadding: Int, maxTokens: Int) {
        self.promptTokens = promptTokens
        self.leftPadding = leftPadding
        self.maxTokens = maxTokens
    }
}

/// The agreed batch composition for one step (identical on every rank after the
/// control all_gather).
public struct ClusterBatchComposition: Sendable {
    public var command: ClusterBatchCommand
    public var bNext: Int
    /// Indices into the PREVIOUS batch that survive (ascending). Empty on a
    /// fresh start. Length == nKeep.
    public var keepIndices: [Int]
    /// Rows admitted (and prefilled) this step. Length == nAdmit.
    public var admit: [ClusterAdmitRow]

    public init(command: ClusterBatchCommand, bNext: Int, keepIndices: [Int], admit: [ClusterAdmitRow]) {
        self.command = command
        self.bNext = bNext
        self.keepIndices = keepIndices
        self.admit = admit
    }

    public static let shutdown = ClusterBatchComposition(command: .shutdown, bNext: 0, keepIndices: [], admit: [])
    public static let idle = ClusterBatchComposition(command: .idle, bNext: 0, keepIndices: [], admit: [])

    /// Encode into the fixed-width int32 control vector.
    public func encodeVector() -> [Int32] {
        var v = [Int32](repeating: 0, count: BATCH_CTRL_WIDTH)
        v[0] = command.rawValue
        v[1] = Int32(bNext)
        v[2] = Int32(keepIndices.count)
        v[3] = Int32(admit.count)
        let prefillW = admit.map(\.promptTokens.count).max() ?? 0
        v[4] = Int32(prefillW)
        var idx = 5
        for k in keepIndices { v[idx] = Int32(k); idx += 1 }
        // Reserve the keep region at full width so admit blocks start at a fixed
        // offset regardless of nKeep — keeps decode unambiguous.
        idx = 5 + BATCH_CTRL_MAX_ROWS
        for row in admit {
            v[idx] = Int32(row.promptTokens.count); idx += 1
            v[idx] = Int32(row.leftPadding); idx += 1
            v[idx] = Int32(row.maxTokens); idx += 1
        }
        // Admit token ids follow the headers region.
        idx = 5 + BATCH_CTRL_MAX_ROWS + BATCH_CTRL_MAX_ROWS * 3
        for row in admit {
            for t in row.promptTokens { v[idx] = Int32(t); idx += 1 }
        }
        return v
    }

    /// Decode from the head's slot of the gathered control vector.
    public static func decode(_ slot: [Int32]) -> ClusterBatchComposition {
        let command = ClusterBatchCommand(rawValue: slot[0]) ?? .step
        let bNext = Int(slot[1])
        let nKeep = Int(slot[2])
        let nAdmit = Int(slot[3])
        var keep = [Int]()
        for i in 0..<max(0, nKeep) { keep.append(Int(slot[5 + i])) }
        var admit = [ClusterAdmitRow]()
        let headerBase = 5 + BATCH_CTRL_MAX_ROWS
        let tokenBase = 5 + BATCH_CTRL_MAX_ROWS + BATCH_CTRL_MAX_ROWS * 3
        var tokOffset = tokenBase
        for a in 0..<max(0, nAdmit) {
            let pLen = Int(slot[headerBase + a * 3 + 0])
            let lpad = Int(slot[headerBase + a * 3 + 1])
            let mTok = Int(slot[headerBase + a * 3 + 2])
            var prompt = [Int]()
            for _ in 0..<max(0, pLen) { prompt.append(Int(slot[tokOffset])); tokOffset += 1 }
            admit.append(ClusterAdmitRow(promptTokens: prompt, leftPadding: lpad, maxTokens: mTok))
        }
        return ClusterBatchComposition(command: command, bNext: bNext, keepIndices: keep, admit: admit)
    }
}
