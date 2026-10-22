import MLX
import MLXLMCommon

/// Serial, depth-one target verification. The committed generation plus at
/// most two plain pending generations fit the existing three-generation ledger.
/// No model, schedule, sampled token or distributed acknowledgement lives here.
final class CBv2TargetVerification {
    let base: Int
    let maximumSteps: Int
    private var pending: [CBv2RecurrentStateEvaluation] = []
    private var active: CBv2RecurrentStateEvaluation?
    private var activeWasEvaluated = false
    private var failed = false
    private var resolved = false
    private(set) var stagedCount = 0
    private(set) var committedCount = 0

    init(base: Int, maximumSteps: Int, rows: [CBv2SequenceKV?]) throws {
        guard base > 0, (1...2).contains(maximumSteps), base <= Int.max - maximumSteps,
              !rows.isEmpty, rows.allSatisfy({
            // This first seam is for the admitted Qwen full-attention rows.
            // Do not assume a future windowed/borrowed implementation has the
            // same full-prefix and storage budget as the current geometry.
            ($0 as? CBv2FullSequenceKV).map { $0.maxLength >= base + maximumSteps } == true
                && $0?.supportsSpeculativeWrites == true
                && $0?.absoluteOffset == base && $0?.retainedCount == base
        }) else { throw ProbeError("Target verification requires bounded full-KV rows at one committed frontier") }
        self.base = base; self.maximumSteps = maximumSteps
        for row in rows { row!.beginSpeculativeWrite() }
    }

    func stage(recurrent: CBv2RecurrentRequestState, bank: CBv2LayerCacheBank,
               rows: [CBv2SequenceKV?], check: () throws -> Void,
               additionalTargets: () -> [MLXArray],
               forward: ([any CBv2AttendingLayerCache], CBv2RecurrentStateEvaluation) throws -> MLXArray,
               validate: (MLXArray, Int) throws -> Void) throws -> MLXArray {
        do {
            guard !failed, !resolved, active == nil, committedCount == 0, stagedCount < maximumSteps else {
                throw ProbeError("Target verification stage is replayed, failed or full")
            }
            try check()
            let caches = bank.layerCaches(rowStates: [rows])
            // bind() reads pending.last, not merely confirmedStateSnapshot().
            // Thus the draft evaluation consumes the still-pending seed state.
            active = try recurrent.bind(); activeWasEvaluated = false
            let output = try forward(caches, active!)
            try check()
            let roots = try active!.evaluate(); activeWasEvaluated = true
            let cacheRoots = caches.flatMap { ($0 as! any KVCache).innerState() }
            eval([output] + roots + cacheRoots + additionalTargets())
            try check()
            try validate(output, base + stagedCount + 1)
            try check()
            pending.append(active!); stagedCount += 1; active = nil; activeWasEvaluated = false
            return output
        } catch { failed = true; throw error }
    }

    /// Commit only the oldest input while retaining the already-evaluated
    /// suffix. Full KV rows still expose the speculative frontier; their prefix
    /// is immutable. The receipt must describe both frontiers until reconcile.
    func commitNext(check: () throws -> Void, validate: (Int, Int) throws -> Void) throws -> Int {
        do {
            guard !failed, !resolved, active == nil, !pending.isEmpty,
                  pending.count == stagedCount - committedCount else {
                throw ProbeError("Target verification has no next pending input to commit")
            }
            try check()
            Stream.gpu.synchronize(); Stream.cpu.synchronize(); try check()
            try pending.first!.commit(); pending.removeFirst(); committedCount += 1
            try validate(base + committedCount, base + stagedCount); try check()
            return base + committedCount
        } catch { failed = true; throw error }
    }

    /// Zero retained inputs is a successful restoration of the old committed
    /// state. Any reconciliation error instead poisons the entire request.
    func reconcile(keeping count: Int, bank: CBv2LayerCacheBank,
                   rows: [CBv2SequenceKV?], check: () throws -> Void,
                   validate: (Int) throws -> Void) throws -> Int {
        do {
            guard !failed, !resolved, active == nil, (committedCount...stagedCount).contains(count),
                  pending.count == stagedCount - committedCount else {
                throw ProbeError("Target verification retained prefix is invalid")
            }
            try check()
            Stream.gpu.synchronize(); Stream.cpu.synchronize(); try check()
            let rejected = stagedCount - count
            // Production recurrent ownership requires LIFO rollback, then FIFO
            // commit. Remove only after success so retirement can retry cleanup.
            while pending.count > count - committedCount { try pending.last!.rollback(); pending.removeLast() }
            while !pending.isEmpty { try pending.first!.commit(); pending.removeFirst(); committedCount += 1 }
            for row in rows { row!.rollback(rejected); row!.commitSpeculativeWrite() }
            // Host rollback alone leaves the bank's device positionOffsets at
            // the speculative frontier. Rebind immediately (also keeps later
            // releaseBoundRows effective) before validating/publishing anything.
            bank.invalidateBoundComposition()
            _ = bank.layerCaches(rowStates: [rows])
            try check(); try validate(base + count); try check()
            resolved = true
            return base + count
        } catch { failed = true; throw error }
    }

    /// Whole-request retirement only. Partially executed attention writes are
    /// released by the core, never described as a reusable reconciled prefix.
    func discard() throws {
        var failure: Error?
        if let active, activeWasEvaluated {
            do { try active.rollback() } catch { failure = error }
        }
        // An unevaluated binding is abandoned by evaluation.deinit. Drop it
        // before recurrent.release(), including when forward threw mid-layer.
        active = nil; activeWasEvaluated = false
        while let last = pending.last {
            do { try last.rollback(); pending.removeLast() }
            catch { failure = failure ?? error; break }
        }
        resolved = true
        if let failure { failed = true; throw failure }
    }
}
