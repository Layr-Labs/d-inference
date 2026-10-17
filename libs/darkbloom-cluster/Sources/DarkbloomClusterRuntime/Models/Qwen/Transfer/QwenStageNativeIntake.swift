import Foundation
import MLX

/// Digests that hashing threads have finished, until the receiver collects them.
private final class QwenStageDigestResults: @unchecked Sendable {
    private let lock = NSLock()
    private var ready: [(tensor: Int, contentSHA256: String)] = []

    func append(_ tensor: Int, _ digest: String) {
        lock.lock(); ready.append((tensor, digest)); lock.unlock()
    }

    func take() -> [(tensor: Int, contentSHA256: String)] {
        lock.lock(); defer { lock.unlock() }
        defer { ready = [] }
        return ready
    }
}

/// The receiving rank's storage for a transferred stage. A tensor that came as
/// one piece is kept as it arrived: that allocation is its final one. A split
/// tensor is joined once along axis 0 and its pieces released. Each finished
/// tensor is hashed in place on a hashing thread while later pieces arrive;
/// the bytes are only borrowed there, and this object keeps the array alive
/// until the hashing is joined. A tensor whose storage is not one compact
/// allocation is refused, so nothing is ever copied to host memory to hash it.
///
/// The load's own gate decides about each tensor before it takes its storage
/// here, and is asked again once the tensor has settled: the same questions,
/// in the same order, that a local load asks before and after each read. Only
/// the tensor's first piece, at most one piece limit, exists before the answer.
///
/// Every MLX call is made on the caller's thread. Hashing threads touch bytes only.
final class QwenStageNativeIntake: QwenStageTransferIntake {
    static let hashThreadCount = 8

    let plan: QwenStageTransferPlan
    private let active: [QwenStageActiveTensor]
    private let gate: any QwenLayerStageGate
    private let check: () throws -> Void
    private let hashing = OperationQueue()
    private let results = QwenStageDigestResults()
    private var assembling: [MLXArray] = []
    private var tensors: [Int: MLXArray] = [:]

    /// `active` is the stage inventory the plan was made from and `gate` the
    /// gate of the load it belongs to. `check` reports a native fault or a
    /// passed deadline.
    init(plan: QwenStageTransferPlan, active: [QwenStageActiveTensor], gate: any QwenLayerStageGate,
         hashThreads: Int = hashThreadCount, check: @escaping () throws -> Void) throws {
        guard active.count == plan.tensors.count, zip(active, plan.tensors).allSatisfy({
            $0.sourceName == $1.sourceName && $0.shape == $1.shape && $0.byteCount == $1.byteCount
        }) else { throw ProbeError("Stage transfer intake needs the active inventory its plan was made from") }
        // The loader would convert such a tensor after the gate's last question about it.
        guard active.allSatisfy({ $0.sourceDType == $0.loadedDType }) else {
            throw ProbeError("Stage transfer intake takes no tensor the loader would convert")
        }
        self.plan = plan; self.active = active; self.gate = gate; self.check = check
        hashing.maxConcurrentOperationCount = max(1, hashThreads)
    }

    /// The hashing threads borrow storage this object owns.
    deinit { joinHashing(abandoningQueued: true) }

    func accept(_ payload: MLXArray, for piece: QwenStageTransferPlan.Piece) throws {
        // A native fault while the piece was made is reported as itself, not as a wrong piece.
        try check()
        guard payload.shape == piece.shape, payload.dtype == piece.dtype.native,
              payload.nbytes == piece.byteCount else {
            throw ProbeError("Stage transfer piece differs from its planned shape, dtype or size")
        }
        let tensor = plan.tensors[piece.tensor]
        if piece.index == tensor.pieces.lowerBound {
            try check(); try gate.beforeRead(active[piece.tensor]); try check()
        }
        assembling.append(payload)
        guard piece.index + 1 == tensor.pieces.upperBound else { return }
        let whole = assembling.count == 1 ? assembling[0] : concatenated(assembling, axis: 0)
        assembling = []
        eval(whole); Stream.gpu.synchronize()
        try check(); try gate.observe(); try check()
        guard whole.shape == tensor.shape, let storage = try whole.evaluatedBufferInfo(), storage.isRowContiguous,
              storage.dataOffset == 0, storage.dataElements == whole.size else {
            throw ProbeError("Stage transfer tensor did not assemble to its planned shape in one compact allocation")
        }
        // Borrowed, not copied: compact storage is handed out as it is.
        let bytes = whole.asData(access: .noCopyIfContiguous).data
        guard bytes.count == tensor.byteCount else {
            throw ProbeError("Stage transfer tensor did not assemble to its planned size")
        }
        tensors[piece.tensor] = whole
        hashing.addOperation { [results] in
            results.append(piece.tensor, sha256(bytes))
        }
    }

    func completedDigests(joining: Bool) throws -> [(tensor: Int, contentSHA256: String)] {
        if joining { joinHashing(abandoningQueued: false) }
        return results.take()
    }

    func discard() {
        joinHashing(abandoningQueued: true)
        assembling = []; tensors = [:]
        _ = results.take()
    }

    /// Returns once no hashing thread is reading. Digests nobody will ask for are not started.
    private func joinHashing(abandoningQueued: Bool) {
        if abandoningQueued { hashing.cancelAllOperations() }
        hashing.waitUntilAllOperationsAreFinished()
    }

    /// Hands one verified tensor to the loader. This object keeps no reference to it.
    func take(_ tensor: Int) -> MLXArray? { tensors.removeValue(forKey: tensor) }
    var heldTensorCount: Int { tensors.count }
}
