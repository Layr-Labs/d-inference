import Foundation

struct QwenLongPrefillPairFrame: Encodable {
    let producer: QwenLayerStagePrefillCommit
    let consumer: QwenLayerStagePrefillCommit
    let boundary: QwenLayerStageProfiledBoundaryWireHeader
    let envelopeFingerprint: String
    let envelopeWireBytesSHA256: String
}

struct QwenLongPrefillPairResult: Encodable {
    let kind = "qwen_long_prefill_pair_comparison", schemaVersion = 1
    let correctnessOnly = true, throughputMeasurementValid = false
    let interprocessTransportUsed = false, physicalTransferQualified = false
    let baselineEvidenceFingerprint: String
    let agreement: QwenLayerStageProfiledPrefillStartAgreement.Descriptor
    let agreementFingerprint: String
    let frames: [QwenLongPrefillPairFrame]
    let selectedToken: QwenLayerStagePrefillTokenReceipt
    let finalDigests: [QwenLayerStageProfiledPrefillFinalDigest]
    let combinedFinalStateFingerprint: String
    let completeStateMetadataAndDigestsExact = true
    let finalLogitMetadataAndDigestExact = true
    let selectedTokenExact = true
    let allRequestStateRetired = true
    let candidateFullLogitValuesExported = false
    let candidateNativeBytesComparedDirectly = false
    let nativeBoundaryCopies: Int
}

func requireQwenLongPrefillPairResult(reference: QwenLongPrefillReferenceEvidence,
    final: [QwenLayerStageProfiledPrefillFinalDigest], token: QwenLayerStagePrefillTokenReceipt
) throws -> String {
    guard final.count == 2, final.map(\.identity.stageIndex) == [0, 1],
          final.allSatisfy({ $0.completedFrames == 16 && $0.committedTokens == 8192 }),
          final[0].finalLogits == nil, let row = final[1].finalLogits,
          row.shape == reference.execution.finalLogits.record.shape,
          row.dtype == reference.execution.finalLogits.record.dtype,
          row.byteCount == reference.execution.finalLogits.record.byteCount,
          row.logicalBytesSHA256 == reference.execution.finalLogits.record.logicalBytesSHA256,
          token.tokenID == reference.execution.selection.tokenID,
          token.frame == reference.execution.selection.frame,
          token.committedTokens == 8192, token.allLogitsFinite else {
        throw ProbeError("Long pair final logits or selected token differs from the same-chunk full reference")
    }
    let entries = final.flatMap { $0.finalState.entries }.sorted {
        ($0.globalLayerIndex, $0.component) < ($1.globalLayerIndex, $1.component)
    }
    guard entries == reference.execution.finalState.entries,
          entries.count == 72, Set(entries.map(\.key)).count == 72,
          try QwenLongPrefillCheckedBytes.sum(entries.map(\.byteCount)) == 319_946_784 else {
        throw ProbeError("Long pair final state metadata/digests differ from the complete reference")
    }
    let fingerprint = sha256(Data((["cbv2-owned-state-v1", "tokens=8192"]
        + entries.map(\.identity)).joined(separator: "\n").utf8))
    guard fingerprint == reference.execution.finalState.fingerprint else {
        throw ProbeError("Long pair combined state identity differs")
    }
    return fingerprint
}
