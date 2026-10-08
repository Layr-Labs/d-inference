import Foundation
import MLX

/// Identity accompanies a native residual array, never token embeddings. This
/// local diagnostic format is not a transport protocol or zero-copy claim.
struct QwenLayerStageBoundary {
    let requestFingerprint: String
    let sourceConfigurationSHA256: String
    let artifactAggregateSHA256: String
    let storageCommitmentSHA256: String
    let planFingerprint: String
    let producerStageFingerprint: String
    let frame: QwenLayerStageFrame
    let tokenIDsSHA256: String
    let payloadSHA256: String
    let array: MLXArray

    static func tokenHash(_ tokens: [Int]) -> String {
        sha256(Data(tokens.map(String.init).joined(separator: ",").utf8))
    }

    /// Caller explicitly chooses a physical copy for the sequential diagnostic.
    /// This helper preserves every dtype/bit and proves actual owned storage;
    /// no buffer is retained in either stage session after the consumer returns.
    func ownedCopy(check: () throws -> Void) throws -> QwenLayerStageBoundary {
        try MLX.withError { error in
        let copy = try copySelectedTensor(array, selection: .all)
        try error.check(); try check()
        guard copy.shape == array.shape, copy.dtype == array.dtype,
            copy.asData().data == array.asData().data else {
            throw ProbeError("Layer-stage boundary copy changed native residual bytes")
        }
        try error.check(); try check()
        return .init(requestFingerprint: requestFingerprint,
            sourceConfigurationSHA256: sourceConfigurationSHA256,
            artifactAggregateSHA256: artifactAggregateSHA256,
            storageCommitmentSHA256: storageCommitmentSHA256, planFingerprint: planFingerprint,
            producerStageFingerprint: producerStageFingerprint, frame: frame,
            tokenIDsSHA256: tokenIDsSHA256, payloadSHA256: payloadSHA256, array: copy)
        }
    }

    func validateOwnedArray(tokens: Int, hidden: Int, dtype: DType) throws {
        let bound = try Memory.allocationFootprintUpperBound(byteCount: array.nbytes)
        guard array.shape == [1, tokens, hidden], array.dtype == dtype,
            array.nbytes == tokens * hidden * dtype.size,
            let storage = try array.evaluatedBufferInfo(), storage.isUnique,
            storage.isRowContiguous, storage.dataOffset == 0, storage.dataElements == array.size,
            storage.allocatedBytes >= array.nbytes,
            storage.allocatedBytes <= bound, sha256(array.asData().data) == payloadSHA256 else {
            throw ProbeError("Incoming stage residual must be an evaluated, owned, compact native [1,M,H] array")
        }
    }
}

enum QwenLayerStageOutput {
    case hidden(QwenLayerStageBoundary)
    case evaluationHandle(MLXArray)
    case logits(MLXArray)
}
