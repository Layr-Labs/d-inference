// FullSequenceKV.swift
//
// ContinuousBatchingV2 per-sequence KV storage for FULL attention layers.
//
// One instance owns the K/V for ONE sequence at ONE layer. There is no shared
// batch frontier, no left padding, and no batch-wide trim: joining or leaving
// a batch never touches this object (batch membership is just list membership
// in `CBv2LayerCache.rows`).

import Foundation
import MLX

/// Counters for the v2 core runtime's own host-interaction points.
///
/// The engine step loop must never force a host sync (`.item()`, `asArray`,
/// blocking `eval`) and must never rebuild per-row metadata arrays from host
/// integers outside membership changes. Any CBv2 core code that *does* touch
/// the host goes through these counters so tests can assert the step loop is
/// clean (see `CBv2CoreTests`). This deliberately does not instrument MLX
/// itself — only our own sync points.
public enum CBv2CoreInstrumentation {
    private static let lock = NSLock()

    nonisolated(unsafe) private static var _hostSyncs = 0
    nonisolated(unsafe) private static var _positionOffsetsHostRebuilds = 0

    /// Number of host syncs performed by CBv2 core code.
    public static var hostSyncs: Int {
        lock.lock()
        defer { lock.unlock() }
        return _hostSyncs
    }

    /// Number of times a layer cache rebuilt `positionOffsets` from host
    /// integers. Must only ever increase on batch membership changes.
    public static var positionOffsetsHostRebuilds: Int {
        lock.lock()
        defer { lock.unlock() }
        return _positionOffsetsHostRebuilds
    }

    /// Gate for `recordHostSync`: the engine's finalize readbacks count
    /// only while a test has switched counting on. Off (the default) the
    /// step path pays one static bool read per readback and never touches
    /// the lock — the same pattern as the engine's signposter gate. Tests
    /// flip it on before stepping and reset it afterwards.
    nonisolated(unsafe) static var countingEnabled = false

    static func recordHostSync() {
        guard countingEnabled else { return }
        lock.lock()
        defer { lock.unlock() }
        _hostSyncs += 1
    }

    static func recordPositionOffsetsHostRebuild() {
        lock.lock()
        defer { lock.unlock() }
        _positionOffsetsHostRebuilds += 1
    }
}

/// Internal hook so `CBv2LayerCache` can hand a row's lazily-mutated storage
/// arrays to the engine loop's `asyncEval` (graph/metadata hygiene: no
/// unconsumed lazy chain may grow O(steps) — DAR-325).
protocol CBv2InnerStateProviding {
    func cbv2InnerState() -> [MLXArray]
}

/// `CBv2SequenceKV` for full (non-windowed) attention.
///
/// Storage is one contiguous `[1, kvHeads, capacity, headDim]` buffer per
/// K and V, grown by doubling (initial capacity = promptLength + 256, capped
/// at `maxLength`). Appends are slice assignments — `mlx_slice_update`
/// donates the input buffer when refcount permits, so an append is O(n), not
/// O(cache). `update` returns temporal-order zero-copy strided views
/// `[..., 0..<retained, :]`; MLX SDPA accepts strided K/V.
public final class CBv2FullSequenceKV: CBv2SequenceKV, CBv2InnerStateProviding, CBv2ContiguousKVMetadataProviding {
    /// No native root escapes and wrapped rings are not concatenated.
    public var cbv2ContiguousMetadata: CBv2ContiguousKVMetadata {
        .init(absoluteOffset: absoluteOffset, retainedStart: 0, retainedCount: retainedCount,
            window: nil, keys: keys.map(CBv2ContiguousKVMetadata.Tensor.init),
            values: values.map(CBv2ContiguousKVMetadata.Tensor.init),
            retainedChunkKeys: nil, retainedChunkValues: nil,
            speculativeWritePending: false)
    }


    /// Extra slots allocated beyond the prompt so the first decode steps
    /// don't immediately grow the buffer.
    static let initialSlack = 256

    public private(set) var absoluteOffset: Int = 0
    public var retainedCount: Int { absoluteOffset }

    /// Hard cap on this sequence's length; growth beyond it is an engine
    /// admission bug and traps.
    public let maxLength: Int

    let kvHeads: Int
    let headDim: Int

    private var keys: MLXArray?
    private var values: MLXArray?
    private var capacity: Int

    /// - Parameters:
    ///   - promptLength: expected prompt length, used to size the initial
    ///     allocation (`promptLength + 256`, capped at `maxLength`).
    ///   - maxLength: maximum total tokens this sequence may ever hold.
    ///   - kvHeads/headDim: from the layer's `CBv2LayerKind`; validated
    ///     against the arrays passed to `update`.
    public init(promptLength: Int, maxLength: Int, kvHeads: Int, headDim: Int) {
        precondition(maxLength > 0, "CBv2FullSequenceKV: maxLength must be > 0")
        precondition(
            promptLength <= maxLength,
            "CBv2FullSequenceKV: promptLength \(promptLength) exceeds maxLength \(maxLength)")
        self.maxLength = maxLength
        self.kvHeads = kvHeads
        self.headDim = headDim
        self.capacity = min(maxLength, max(1, promptLength + Self.initialSlack))
    }

    public var byteCount: Int {
        (keys?.nbytes ?? 0) + (values?.nbytes ?? 0)
    }

    /// Transfer an exclusively owned, fully authenticated native destination.
    /// No prefix copy or lazy assignment may retain the staging buffers.
    init(
        restoredKeys: MLXArray, restoredValues: MLXArray, offset: Int,
        maxLength: Int, kvHeads: Int, headDim: Int
    ) throws {
        let shape = [1, kvHeads, maxLength, headDim]
        guard maxLength > 0, offset > 0, offset <= maxLength,
            restoredKeys.shape == shape, restoredValues.shape == shape,
            restoredKeys.dtype == restoredValues.dtype
        else { throw CBv2CompleteCheckpointError.incompatibleCheckpoint }
        self.maxLength = maxLength
        self.kvHeads = kvHeads
        self.headDim = headDim
        self.capacity = maxLength
        self.absoluteOffset = offset
        self.keys = restoredKeys
        self.values = restoredValues
    }

    public func update(keys newKeys: MLXArray, values newValues: MLXArray) -> (MLXArray, MLXArray) {
        let n = newKeys.dim(2)
        precondition(newKeys.dim(0) == 1 && newValues.dim(0) == 1,
            "CBv2FullSequenceKV holds ONE sequence; got batch \(newKeys.dim(0))")
        precondition(newKeys.dim(1) == kvHeads,
            "CBv2FullSequenceKV: kvHeads mismatch (\(newKeys.dim(1)) != \(kvHeads))")
        precondition(newValues.dim(2) == n,
            "CBv2FullSequenceKV: keys/values token count mismatch")
        precondition(
            absoluteOffset + n <= maxLength,
            "CBv2FullSequenceKV: append past maxLength (\(absoluteOffset) + \(n) > \(maxLength)) — admission bug"
        )

        ensureCapacity(absoluteOffset + n, keyTemplate: newKeys, valueTemplate: newValues)

        keys![.ellipsis, absoluteOffset ..< (absoluteOffset + n), 0...] = newKeys
        values![.ellipsis, absoluteOffset ..< (absoluteOffset + n), 0...] = newValues
        absoluteOffset += n

        return (
            keys![.ellipsis, ..<absoluteOffset, 0...],
            values![.ellipsis, ..<absoluteOffset, 0...]
        )
    }

    public func snapshot() -> (keys: MLXArray, values: MLXArray, offset: Int) {
        guard let keys, let values else {
            return (
                MLXArray.zeros([1, kvHeads, 0, headDim], dtype: .float16),
                MLXArray.zeros([1, kvHeads, 0, headDim], dtype: .float16),
                absoluteOffset
            )
        }
        return (
            keys[.ellipsis, ..<absoluteOffset, 0...],
            values[.ellipsis, ..<absoluteOffset, 0...],
            absoluteOffset
        )
    }

    /// Plain rollback is already value-exact (see `rollback`: the offset
    /// decrement makes the un-confirmed tail structurally unreachable and
    /// the confirmed prefix is untouched), so speculative begin/commit are
    /// the contract's default no-ops.
    public var supportsSpeculativeWrites: Bool { true }

    /// Rollback the last `n` tokens (speculative rejection). The un-confirmed
    /// tail is structurally unreachable afterwards: every view this class
    /// hands out is sliced to `..<absoluteOffset`, and the tail slots are
    /// overwritten by the next `update` before they can ever be exposed —
    /// so no zeroing pass is needed.
    public func rollback(_ n: Int) {
        precondition(n >= 0, "CBv2FullSequenceKV.rollback: negative n")
        precondition(
            n <= absoluteOffset,
            "CBv2FullSequenceKV.rollback(\(n)) exceeds retained \(absoluteOffset)")
        absoluteOffset -= n
    }

    func cbv2InnerState() -> [MLXArray] {
        [keys, values].compactMap { $0 }
    }

    // MARK: - Private

    private func ensureCapacity(_ needed: Int, keyTemplate: MLXArray, valueTemplate: MLXArray) {
        if keys == nil {
            capacity = min(maxLength, max(capacity, needed))
            keys = MLXArray.zeros(
                [1, kvHeads, capacity, keyTemplate.dim(3)], dtype: keyTemplate.dtype)
            values = MLXArray.zeros(
                [1, kvHeads, capacity, valueTemplate.dim(3)], dtype: valueTemplate.dtype)
            return
        }
        guard needed > capacity else { return }

        // Grow by doubling, capped at maxLength. The concat copies the old
        // buffer once per doubling — amortized O(1) per appended token.
        let newCapacity = min(maxLength, max(capacity * 2, needed))
        let growth = newCapacity - capacity
        keys = concatenated(
            [keys!, MLXArray.zeros([1, kvHeads, growth, keys!.dim(3)], dtype: keys!.dtype)],
            axis: 2)
        values = concatenated(
            [values!, MLXArray.zeros([1, kvHeads, growth, values!.dim(3)], dtype: values!.dtype)],
            axis: 2)
        capacity = newCapacity
    }
}
