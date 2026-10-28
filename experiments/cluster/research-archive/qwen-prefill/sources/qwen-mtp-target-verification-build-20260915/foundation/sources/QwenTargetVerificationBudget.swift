/// Extra named ownership beyond the unchanged request state/fusion reservation.
/// This is not a whole-kernel/workspace or measured process-peak prediction.
struct QwenTargetVerificationBudget {
    let additionalNativeBytes: Int
    let additionalHostBytes: Int

    static func derive(hiddenSize: Int, vocabularySize: Int, dtypeBytes: Int,
                       rank: Int, steps: Int, bound: (Int) throws -> Int) throws -> Self {
        guard (0...1).contains(rank), (1...2).contains(steps), (1...8192).contains(hiddenSize),
              (1...262_144).contains(vocabularySize), [2, 4].contains(dtypeBytes) else {
            throw ProbeError("Target verification capture geometry is outside its named bounds")
        }
        let product = QwenLongPrefillCheckedBytes.product, sum = QwenLongPrefillCheckedBytes.sum
        func array(_ bytes: Int, count: Int) throws -> Int {
            let actual = try bound(bytes)
            guard actual >= bytes, bytes > 0 else { throw ProbeError("Target verification allocation bound is invalid") }
            return try product([actual, count])
        }
        let hidden = try product([hiddenSize, dtypeBytes])
        // Per step rank0 retains a residual and permits one handoff copy;
        // rank1 retains an ingress and its pre-norm root.
        // Full target rows use F32 upper bounds regardless of actual head dtype.
        let native = try sum([array(hidden, count: steps * 2),
            rank == 1 ? array(product([vocabularySize, 4]), count: steps) : 0,
            array(4, count: steps)])
        // One residual digest copy exists at a time. Remote framing/queues
        // remain the owner's separate transport reservation, never hidden here.
        return .init(additionalNativeBytes: native, additionalHostBytes: hidden)
    }
}

