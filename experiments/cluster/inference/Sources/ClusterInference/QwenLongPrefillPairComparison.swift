import Foundation
import MLX

/// Source-only follow-on draft. One process, two whole-layer stages; no timer,
/// sockets or physical-transfer claim. The full-model owner must be gone.
func compareQwenLongPrefillPair(reference: QwenLongPrefillReferenceEvidence,
    stages: [LoadedQwenLayerStage], local: QwenRegistered9BLongPrefillReferenceAdmission,
    check: () throws -> Void
) throws -> QwenLongPrefillPairResult {
    let agreement = try admitQwenLongPrefillPair(reference: reference, stages: stages, local: local)
    var owners: [QwenLayerStageProfiledPrefillComputeContext] = []
    do {
        return try MLX.withError { error in
            func checked() throws { try error.check(); try check(); try error.check() }
            for stage in stages {
                owners.append(try .init(loaded: stage, local: local, agreement: agreement, check: checked))
                try checked()
            }
            let first = owners[0], second = owners[1]
            var frames: [QwenLongPrefillPairFrame] = []
            for step in local.request.steps {
                let frame = try autoreleasepool {
                    let prepared = try first.prepare(step, check: checked)
                    let boundary = prepared.boundary
                    let source = try QwenLayerStageWireSourceIdentity(
                        sourceConfigurationSHA256: boundary.sourceConfigurationSHA256,
                        artifactAggregateSHA256: boundary.artifactAggregateSHA256,
                        storageCommitmentSHA256: boundary.storageCommitmentSHA256,
                        planFingerprint: boundary.planFingerprint,
                        producerStageFingerprint: boundary.producerStageFingerprint)
                    let header = try QwenLayerStageProfiledBoundaryWireHeader(profile: local.request.request.profile,
                        requestFingerprint: boundary.requestFingerprint,
                        recordedRequestFingerprint: local.request.fingerprint, sourceIdentity: source,
                        frame: boundary.frame, tokenIDsSHA256: boundary.tokenIDsSHA256,
                        payloadSHA256: boundary.payloadSHA256, shape: boundary.array.shape,
                        dtype: String(describing: boundary.array.dtype), byteCount: boundary.array.nbytes)
                    let envelope = try QwenLayerStageProfiledPrefillBoundaryEnvelope(boundary: header, agreement: agreement)
                    let decoded = try QwenLayerStageProfiledPrefillBoundaryEnvelope.decode(envelope.encoded(),
                        agreement: agreement, expectedFrame: step.frame)
                    guard decoded.fingerprint == envelope.fingerprint else {
                        throw ProbeError("Long pair changed its actual boundary envelope bytes")
                    }
                    let copied = try boundary.ownedCopy(check: checked)
                    let consumed = try second.consume(step, boundary: copied, check: checked)
                    guard prepared.commit.frame == step.frame, consumed.frame == step.frame,
                          prepared.commit.committedTokens == step.committedTokens,
                          consumed.committedTokens == step.committedTokens,
                          prepared.commit.recordedRequestFingerprint == local.request.fingerprint,
                          consumed.recordedRequestFingerprint == local.request.fingerprint else {
                        throw ProbeError("Long pair did not commit both complete native frontiers")
                    }
                    try checked()
                    return QwenLongPrefillPairFrame(producer: prepared.commit, consumer: consumed,
                        boundary: header, envelopeFingerprint: envelope.fingerprint,
                        envelopeWireBytesSHA256: envelope.wireBytesSHA256)
                }
                frames.append(frame)
            }
            guard frames.count == 16, owners.allSatisfy({ $0.isPrefillComplete }),
                  !first.hasFinalLogits, second.hasFinalLogits else {
                throw ProbeError("Long pair stopped before complete prefill")
            }
            let token = try second.selectFirstToken(check: checked)
            // This correctness-only driver has no timed interval or remote
            // post-stop event. Final observations follow both completed stages
            // and selection; they do not qualify a timed transport ordering.
            let final = try owners.map { try $0.captureFinalDigestsAfterPostStop(check: checked) }
            let fingerprint = try requireQwenLongPrefillPairResult(reference: reference, final: final, token: token)
            for owner in owners { try owner.close(); try checked() }
            guard owners.allSatisfy({ $0.isClosed && !$0.isFailed && !$0.hasFinalLogits }) else {
                throw ProbeError("Long pair did not retire both request owners")
            }
            return .init(baselineEvidenceFingerprint: reference.fingerprint,
                agreement: agreement.descriptor, agreementFingerprint: agreement.fingerprint,
                frames: frames, selectedToken: token, finalDigests: final,
                combinedFinalStateFingerprint: fingerprint, nativeBoundaryCopies: frames.count)
        }
    } catch {
        let primary = error
        var cleanup: [String] = []
        for (index, owner) in owners.enumerated() where !owner.isClosed {
            do { try MLX.withError { error in try owner.cancel(); try error.check() } }
            catch { cleanup.append("stage \(index): \(error)") }
            if !owner.isClosed || !owner.isFailed || owner.hasFinalLogits {
                cleanup.append("stage \(index) remained live")
            }
        }
        if !cleanup.isEmpty {
            throw ProbeError("Long pair failed (\(primary)); cleanup: \(cleanup.joined(separator: "; "))")
        }
        throw primary
    }
}
