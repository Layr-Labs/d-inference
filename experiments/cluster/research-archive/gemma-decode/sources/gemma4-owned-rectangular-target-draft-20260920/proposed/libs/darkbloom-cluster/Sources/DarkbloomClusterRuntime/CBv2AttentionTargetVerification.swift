import MLX
@_spi(OwnedTargetVerification) import MLXLMCommon

/// One rectangular attention-only transaction over the original owned rows.
/// Full Qwen/recurrent serial verification remains a separate unchanged class.
final class CBv2AttentionTargetVerification {
    let plan: CBv2AttentionVerificationPlan
    private var captures: [CBv2OwnedRectangularAttention.Capture] = []
    private var staged = false
    private var failed = false
    private var resolved = false
    private var executing = false

    init(plan: CBv2AttentionVerificationPlan, rows: [CBv2SequenceKV?],
         backend: CBv2ContiguousKVBackend, check: () throws -> Void) throws {
        guard rows.count == plan.layout.layers.count,
              rows.enumerated().allSatisfy({ index, optional in
                  guard let row = optional else { return false }
                  let layer = plan.layout.layers[index]
                  let concrete = layer.window.map { window in
                      (row as? CBv2WindowedSequenceKV)?.window == window
                  } ?? ((row as? CBv2FullSequenceKV)?.maxLength == plan.layout.maximumTokens)
                  return concrete && row.supportsSpeculativeWrites && row.absoluteOffset == plan.base
              }) else { throw ProbeError("Attention verification requires original bounded full/window rows") }
        self.plan = plan
        for index in plan.captureLayerIndices {
            let row = rows[index]!, snapshot = row.snapshot(), layer = plan.layout.layers[index]
            let count = try plan.layout.range(layer: index, frontier: plan.base).count
            guard snapshot.offset == plan.base, snapshot.keys.shape == [1, layer.kvHeads, count, layer.headDimension],
                  snapshot.values.shape == snapshot.keys.shape,
                  String(describing: snapshot.keys.dtype) == layer.element.rawValue,
                  snapshot.values.dtype == snapshot.keys.dtype else { throw ProbeError("Pre-write capture differs from owned geometry") }
            captures.append(.init(row: row, keys: snapshot.keys, values: snapshot.values))
        }
        try CBv2OwnedRectangularAttention.protectCaptures(captures, backend: backend, check: check)
        for row in rows { row!.beginSpeculativeWrite() }
    }

    func stage(bank: CBv2LayerCacheBank, rows: [CBv2SequenceKV?], check: () throws -> Void,
               additionalTargets: () -> [MLXArray],
               forward: ([any CBv2AttendingLayerCache]) throws -> MLXArray,
               validate: (MLXArray, Int) throws -> Void) throws -> MLXArray {
        do {
            guard !failed, !resolved, !staged, !executing else { throw ProbeError("Rectangular target stage is replayed or retired") }
            executing = true
            defer { executing = false }
            try check()
            let caches = bank.layerCaches(rowStates: [rows])
            let output = try CBv2OwnedRectangularAttention.withSerialQueries(caches: caches) {
                try forward(caches)
            }
            try check()
            let cacheRoots = caches.flatMap { ($0 as! any KVCache).innerState() }
            let stagedRoots = CBv2OwnedRectangularAttention.stagingRoots(rows: rows.map { $0! })
            eval([output] + cacheRoots + stagedRoots + captures.flatMap { [$0.keys, $0.values] } + additionalTargets())
            try check(); try validate(output, plan.base + plan.steps); try check()
            staged = true
            return output
        } catch { failed = true; throw error }
    }

    func reconcile(keeping count: Int, bank: CBv2LayerCacheBank, rows: [CBv2SequenceKV?],
                   backend: CBv2ContiguousKVBackend, check: () throws -> Void,
                   validate: (Int) throws -> Void) throws -> Int {
        do {
            guard !failed, !resolved, staged, !executing, (0...plan.steps).contains(count) else {
                throw ProbeError("Rectangular target accepted prefix is invalid")
            }
            executing = true
            defer { executing = false }
            try check(); Stream.gpu.synchronize(); Stream.cpu.synchronize(); try check()
            for row in rows { row!.rollback(plan.steps - count); row!.commitSpeculativeWrite() }
            bank.invalidateBoundComposition()
            let caches = bank.layerCaches(rowStates: [rows])
            // Window commit constructs actual ring writes. Complete those roots
            // before describing a reusable prefix or restoring the base budget.
            eval(caches.flatMap { ($0 as! any KVCache).innerState() }); try check()
            captures.removeAll()
            backend.updateBytesCapacity(plan.layout.conservativeKVCapacityBytes)
            try validate(plan.base + count); try check()
            resolved = true
            return plan.base + count
        } catch { failed = true; throw error }
    }

    /// Cleanup only: the containing owner synchronizes and releases every row.
    /// A partial forward must never be repaired into a reusable request here.
    func discard() { failed = true; resolved = true; captures.removeAll() }
}
