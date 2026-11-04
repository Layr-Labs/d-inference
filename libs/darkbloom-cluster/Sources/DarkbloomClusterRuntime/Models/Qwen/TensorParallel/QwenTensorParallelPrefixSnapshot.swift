import MLX

/// Shared byte-preserving target capture; a caller must already hold the full
/// live state and explicit compact-copy allowance. No assistant state is inferred.
extension QwenTensorParallelBatchPrefixState {
    static func capture(state: CBv2OwnedRequestState, frontier captureFrontier: Int,
                        limitBytes captureLimitBytes: Int, allocationBound: (Int) throws -> Int,
                        check: () throws -> Void) throws -> Self? {
        guard captureFrontier > 0, state.committedTokens == captureFrontier else {
            throw ProbeError("Qwen TP prefix capture frontier differs")
        }
        try state.requireOpen()
        let attention = try QwenTensorParallelPrefixCapture.attentionRows(state, frontier: captureFrontier)
        let recurrent = try QwenTensorParallelPrefixCapture.recurrentState(state)
        let roots = attention.values.flatMap { [$0.keys, $0.values] } + recurrent.values.flatMap { [$0.conv, $0.ssm] }
        let allocated = try QwenTensorParallelPrefixCapture.bounded(roots, allocationBound)
        guard allocated <= captureLimitBytes else { return nil }
        let copies = (attention: attention.mapValues { (keys: copy($0.keys), values: copy($0.values)) },
                      recurrent: recurrent.mapValues { (conv: copy($0.conv), ssm: copy($0.ssm)) })
        eval(copies.attention.values.flatMap { [$0.keys, $0.values] } + copies.recurrent.values.flatMap { [$0.conv, $0.ssm] })
        try check()
        return .init(committedTokens: captureFrontier, attention: copies.attention, recurrent: copies.recurrent,
                     allocatedBytes: allocated)
    }
}

/// An eager copy with its own storage: later ring or page writes cannot reach it.
private func copy(_ value: MLXArray) -> MLXArray { value * MLXArray(1).asType(value.dtype) }

/// One plain lane's prompt-prefix capture on a tensor-parallel Qwen rank:
/// the boundaries it keeps (`QwenTensorParallelBatchPrefixBudget.frontiers`),
/// within the request's own charged capture. Each kept boundary's
/// convolution and SSM state is copied when the prompt reaches it; the
/// attention rows are copied once, at the deepest boundary, and every
/// shallower state views their first rows. A boundary whose state does not
/// fit the limit beside the deepest's is not kept (the shallowest go first);
/// nothing is kept when the deepest alone does not fit.
final class QwenTensorParallelPrefixCapture {
    let frontiers: [Int]
    let limitBytes: Int
    private let allocationBound: (Int) throws -> Int
    private var kept: Set<Int>?
    private var recurrent: [Int: [Int: (conv: MLXArray, ssm: MLXArray)]] = [:]
    private var recurrentBytes: [Int: Int] = [:]
    private var deepest: (committed: Int, rows: [Int: (keys: MLXArray, values: MLXArray)], bytes: Int)?

    init(frontiers: [Int], limitBytes: Int, allocationBound: @escaping (Int) throws -> Int) {
        self.frontiers = Array(Set(frontiers.filter { $0 > 0 })).sorted()
        self.limitBytes = max(0, limitBytes); self.allocationBound = allocationBound
    }

    /// Whether every boundary is one a request of `request` reaches on its own grid after its restored prefix.
    func fits(_ request: QwenLayerStageGenerationRequest) -> Bool {
        frontiers.allSatisfy { $0 > request.reusedPrefixTokens && $0 < request.promptCount && $0 % request.chunkSize == 0 }
    }

    /// After the prompt frame that committed `frontier` (`state` is the request's).
    func capture(_ state: CBv2OwnedRequestState, at frontier: Int, check: () throws -> Void) throws {
        guard frontiers.contains(frontier) else { return }
        guard state.committedTokens == frontier else { throw ProbeError("Qwen TP prefix capture frontier differs") }
        try state.requireOpen()
        let last = frontiers.last!
        if kept == nil {
            // Measured at the first boundary reached: the deepest boundary's
            // rows grow by whole positions from these; a recurrent state is
            // the same size at every boundary.
            let rows = try Self.attentionRows(state, frontier: frontier)
            let state0 = try Self.recurrentState(state)
            let perBoundary = try Self.bounded(state0.values.flatMap { [$0.conv, $0.ssm] }, allocationBound)
            let deepestRows = try QwenLongPrefillCheckedBytes.sum(rows.values.flatMap { [$0.keys, $0.values] }.map {
                try allocationBound($0.nbytes / frontier * last)
            })
            let base = try QwenLongPrefillCheckedBytes.sum([deepestRows, perBoundary])
            if base > limitBytes { kept = [] } else {
                let more = perBoundary > 0 ? (limitBytes - base) / perBoundary : frontiers.count
                kept = Set(frontiers.dropLast().suffix(max(0, more))).union([last])
            }
        }
        guard kept?.contains(frontier) == true else { return }
        let own = try Self.recurrentState(state).mapValues { (conv: copy($0.conv), ssm: copy($0.ssm)) }
        eval(own.values.flatMap { [$0.conv, $0.ssm] })
        try check()
        recurrent[frontier] = own
        recurrentBytes[frontier] = try Self.bounded(own.values.flatMap { [$0.conv, $0.ssm] }, allocationBound)
        guard frontier == last else { return }
        let rows = try Self.attentionRows(state, frontier: frontier).mapValues { (keys: copy($0.keys), values: copy($0.values)) }
        eval(rows.values.flatMap { [$0.keys, $0.values] })
        try check()
        deepest = (frontier, rows, try Self.bounded(rows.values.flatMap { [$0.keys, $0.values] }, allocationBound))
    }

    /// The kept boundaries' states, ascending, each viewing the deepest
    /// boundary's one copy of the attention rows (`sharedBytes`) and holding
    /// its own recurrent state (`allocatedBytes`); empty unless the deepest
    /// was reached.
    func states() -> [QwenTensorParallelBatchPrefixState] {
        guard let deepest else { return [] }
        return recurrent.keys.sorted().compactMap { frontier in
            guard frontier <= deepest.committed, let own = recurrent[frontier], let bytes = recurrentBytes[frontier] else { return nil }
            let rows = deepest.rows.mapValues { pair -> (keys: MLXArray, values: MLXArray) in
                frontier == deepest.committed ? pair
                    : (keys: pair.keys[0..., 0..., 0 ..< frontier, 0...], values: pair.values[0..., 0..., 0 ..< frontier, 0...])
            }
            return .init(committedTokens: frontier, attention: rows, recurrent: own, allocatedBytes: bytes)
        }
    }

    /// The attention copy the kept states view together.
    var sharedBytes: Int { deepest?.bytes ?? 0 }

    func discard() { recurrent.removeAll(); recurrentBytes.removeAll(); deepest = nil }

    static func attentionRows(_ state: CBv2OwnedRequestState, frontier: Int) throws -> [Int: (keys: MLXArray, values: MLXArray)] {
        var attention: [Int: (keys: MLXArray, values: MLXArray)] = [:]
        for (row, kind) in zip(state.rows, state.geometry.kinds) {
            guard let row, let index = kind.modelLayerIndex else { throw ProbeError("Qwen TP capture lacks an attention row") }
            let value = row.snapshot()
            guard value.offset == frontier, value.keys.dim(2) == frontier, value.values.dim(2) == frontier else {
                throw ProbeError("Qwen TP capture attention frontier differs")
            }
            attention[index] = (value.keys, value.values)
        }
        return attention
    }

    static func recurrentState(_ state: CBv2OwnedRequestState) throws -> [Int: (conv: MLXArray, ssm: MLXArray)] {
        let confirmed = state.recurrent.confirmedStateSnapshot() ?? [:]
        var recurrent: [Int: (conv: MLXArray, ssm: MLXArray)] = [:]
        for layer in state.geometry.recurrent.layers {
            guard let value = confirmed[layer.modelLayerIndex], let conv = value.conv, let ssm = value.ssm else {
                throw ProbeError("Qwen TP capture lacks confirmed recurrence")
            }
            recurrent[layer.modelLayerIndex] = (conv, ssm)
        }
        return recurrent
    }

    static func bounded(_ roots: [MLXArray], _ allocationBound: (Int) throws -> Int) throws -> Int {
        try QwenLongPrefillCheckedBytes.sum(roots.map {
            let bytes = try allocationBound($0.nbytes)
            guard bytes >= $0.nbytes, $0.nbytes > 0 else { throw ProbeError("Qwen TP prefix allocation bound differs") }
            return bytes
        })
    }
}
