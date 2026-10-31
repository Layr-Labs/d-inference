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
        var attention: [Int: (keys: MLXArray, values: MLXArray)] = [:]
        for (row, kind) in zip(state.rows, state.geometry.kinds) {
            guard let row, let index = kind.modelLayerIndex else { throw ProbeError("Qwen TP capture lacks an attention row") }
            let value = row.snapshot()
            guard value.offset == captureFrontier, value.keys.dim(2) == captureFrontier,
                  value.values.dim(2) == captureFrontier else { throw ProbeError("Qwen TP capture attention frontier differs") }
            attention[index] = (value.keys, value.values)
        }
        let confirmed = state.recurrent.confirmedStateSnapshot() ?? [:]
        var recurrent: [Int: (conv: MLXArray, ssm: MLXArray)] = [:]
        for layer in state.geometry.recurrent.layers {
            guard let value = confirmed[layer.modelLayerIndex], let conv = value.conv, let ssm = value.ssm else {
                throw ProbeError("Qwen TP capture lacks confirmed recurrence")
            }
            recurrent[layer.modelLayerIndex] = (conv, ssm)
        }
        let roots = attention.values.flatMap { [$0.keys, $0.values] } + recurrent.values.flatMap { [$0.conv, $0.ssm] }
        let allocated = try QwenLongPrefillCheckedBytes.sum(roots.map {
            let bytes = try allocationBound($0.nbytes)
            guard bytes >= $0.nbytes, $0.nbytes > 0 else { throw ProbeError("Qwen TP prefix allocation bound differs") }
            return bytes
        })
        guard allocated <= captureLimitBytes else { return nil }
        func copy(_ value: MLXArray) -> MLXArray { value * MLXArray(1).asType(value.dtype) }
        attention = attention.mapValues { (copy($0.keys), copy($0.values)) }
        recurrent = recurrent.mapValues { (copy($0.conv), copy($0.ssm)) }
        eval(attention.values.flatMap { [$0.keys, $0.values] } + recurrent.values.flatMap { [$0.conv, $0.ssm] })
        try check()
        return .init(committedTokens: captureFrontier, attention: attention, recurrent: recurrent,
                         allocatedBytes: allocated)
    }

}
