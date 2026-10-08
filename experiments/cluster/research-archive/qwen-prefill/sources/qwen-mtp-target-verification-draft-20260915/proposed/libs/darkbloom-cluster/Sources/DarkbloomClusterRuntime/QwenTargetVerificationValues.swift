import MLX

/// Provisional ingress is a distinct type, so ordinary committed decode cannot
/// accept it accidentally. A transport must reconstruct these exact fields and
/// an owned evaluated residual after validating its authenticated round binding.
struct QwenTargetVerificationBoundary {
    let verificationFingerprint: String
    let producerStageFingerprint: String
    let step: Int
    let tokenID: Int
    let payloadSHA256: String
    let array: MLXArray

    func ownedCopy(check: () throws -> Void) throws -> Self {
        try MLX.withError { nativeError in
            do {
                try nativeError.check(); try check(); try nativeError.check()
                let copy = try copySelectedTensor(array, selection: .all)
                try nativeError.check(); try check()
                guard copy.shape == array.shape, copy.dtype == array.dtype,
                      sha256(copy.asData().data) == payloadSHA256 else {
                    throw ProbeError("Target verification residual copy differs")
                }
                try nativeError.check(); try check()
                return .init(verificationFingerprint: verificationFingerprint,
                    producerStageFingerprint: producerStageFingerprint, step: step,
                    tokenID: tokenID, payloadSHA256: payloadSHA256, array: copy)
            } catch { try nativeError.check(); throw error }
        }
    }

    func validate(request: QwenTargetVerificationRequest, step: Int, dtype: DType) throws {
        let hidden = request.agreement.request.profile.hiddenSize
        guard verificationFingerprint == request.fingerprint, self.step == step,
              tokenID == (try request.token(step: step)),
              producerStageFingerprint == request.agreement.descriptor.stageFingerprints[0],
              array.shape == [1, 1, hidden], array.dtype == dtype,
              array.nbytes == hidden * dtype.size else {
            throw ProbeError("Target verification residual identity or shape differs")
        }
        let bound = try Memory.allocationFootprintUpperBound(byteCount: array.nbytes)
        guard let storage = try array.evaluatedBufferInfo(), storage.isUnique,
              storage.isRowContiguous, storage.dataOffset == 0, storage.dataElements == array.size,
              storage.allocatedBytes >= array.nbytes, storage.allocatedBytes <= bound,
              sha256(array.asData().data) == payloadSHA256 else {
            throw ProbeError("Target verification ingress is not an owned evaluated residual")
        }
    }
}

enum QwenTargetVerificationOutput {
    case provisionalHidden(QwenTargetVerificationBoundary)
    case provisionalLogits(MLXArray)
}

/// Each native row becomes accessible once after its local prefix commit. The
/// owner must still join both receipts before using them for assistant history.
final class QwenTargetVerificationCommit {
    let localReceipt: QwenTargetVerificationLocalReceipt
    private var hidden: [MLXArray]?
    init(receipt: QwenTargetVerificationLocalReceipt, hidden: [MLXArray]) {
        localReceipt = receipt; self.hidden = hidden
    }
    func takeLocalHiddenRows() throws -> [MLXArray] {
        guard let hidden else { throw ProbeError("Committed target rows were already consumed") }
        self.hidden = nil; return hidden
    }
    func discard() { hidden = nil }
}
