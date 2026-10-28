import Foundation

/// Consumes the existing recorder's CPU values after the shared native core and
/// local lifecycle have retired. No native array, secret, additional collective,
/// GPU evaluation or file operation exists in this encoder.
enum QwenProtectedEvidenceExport {
    static func publish(_ evidence: QwenGenerationDiagnosticEvidence,
                        request: QwenLayerStageGenerationRequest, totalReservedBytes: Int,
                        to publisher: (Data, () throws -> Void) throws -> Void,
                        check: () throws -> Void) throws {
        try require(evidence, request: request, totalReservedBytes: totalReservedBytes)
        try check()
        try autoreleasepool {
            let writer = try QwenProtectedEvidenceJSON()
            try encode(evidence, request: request, totalReservedBytes: totalReservedBytes,
                       into: writer, check: check)
            try check()
            try writer.publish { bytes in
                try publisher(bytes, check)
                try check()
            }
        }
        try check()
    }

    static func require(_ e: QwenGenerationDiagnosticEvidence,
                        request: QwenLayerStageGenerationRequest, totalReservedBytes: Int) throws {
        let result = e.execution, agreement = e.agreement
        let required = try QwenLongPrefillCheckedBytes.sum([e.captureBudget.originalRequestReservedBytes,
            e.captureBudget.extraHostBytes, e.captureBudget.extraNativeBytes,
            QwenResidentProtectedExperiment.reservedBytes])
        try QwenResidentProtectedExperiment.requireWorkload(promptCount: request.promptCount,
            chunkSize: request.chunkSize, outputCount: request.outputCount, stopTokenIDs: request.stopTokenIDs.sorted())
        guard (0...1).contains(e.rank), e.sourceLayerStart == e.rank * 16,
              e.sourceLayerEnd == (e.rank + 1) * 16,
              request.profile.activationDType == "bfloat16",
              request.profile.vocabularySize == QwenProtectedEvidenceBudget.vocabularySize,
              result.bothRequestStatesRetired, result.finishReason == .length,
              result.completedFrames == 3, result.committedTokens == 33,
              result.selectedTokenIDs.count == 2, result.selectedTokenIDs.allSatisfy({
                  (0..<QwenProtectedEvidenceBudget.vocabularySize).contains($0)
              }), result.prefillSchedule == nil, !result.mtpEnabled,
              result.identity.stageIndex == e.rank,
              result.identity.requestFingerprint == request.fingerprint,
              e.requestFingerprint == request.fingerprint,
              e.profileFingerprint == request.profile.fingerprint,
              agreement.profileFingerprint == request.profile.fingerprint,
              agreement.requestID == request.requestID.uuidString.lowercased(),
              agreement.requestFingerprint == request.fingerprint,
              agreement.membershipEpoch == result.membershipEpoch,
              agreement.prefillSchedulingPolicy == nil,
              agreement.rankBuildSHA256.count == 2, agreement.stageFingerprints.count == 2,
              agreement.stageFingerprints[e.rank] == result.identity.stageFingerprint,
              e.stateEntries.count == QwenProtectedEvidenceBudget.stateEntriesPerRank,
              Set(e.stateEntries.map(\.key)).count == e.stateEntries.count,
              e.stateEntries.allSatisfy({ (e.sourceLayerStart..<e.sourceLayerEnd).contains($0.globalLayerIndex)
                  && $0.validLogicalStorage && qwenStageWireIsSHA256($0.sha256) }),
              e.resourceObservationCount > 0,
              totalReservedBytes == required,
              e.captureBudget.rank == e.rank,
              (e.finalLogits != nil) == (e.rank == 1) else {
            throw ProbeError("Protected numerical export differs from its completed exact recording request")
        }
        if let logits = e.finalLogits?.record {
            guard logits.shape == [1, QwenProtectedEvidenceBudget.vocabularySize],
                  logits.dtype == "bfloat16", logits.byteCount == QwenProtectedEvidenceBudget.vocabularySize * 2,
                  logits.values.count == QwenProtectedEvidenceBudget.vocabularySize,
                  logits.values.allSatisfy({ $0.isFinite }), qwenStageWireIsSHA256(logits.logicalBytesSHA256) else {
                throw ProbeError("Protected numerical export lacks the complete final BF16 vocabulary row")
            }
        }
    }

    private static func encode(_ e: QwenGenerationDiagnosticEvidence,
                               request: QwenLayerStageGenerationRequest, totalReservedBytes: Int,
                               into w: QwenProtectedEvidenceJSON, check: () throws -> Void) throws {
        let a = e.agreement, result = e.execution
        try w.raw("{"); try w.field("schema", "qwen9b_protected_final_evidence_v1")
        try w.field("nativeRequestID", a.requestID); try w.field("membershipEpoch", a.membershipEpoch)
        try w.number("rank", e.rank); try w.number("sourceLayerStart", e.sourceLayerStart)
        try w.number("sourceLayerEnd", e.sourceLayerEnd)
        try w.field("requestFingerprint", e.requestFingerprint); try w.field("profileFingerprint", e.profileFingerprint)
        try w.field("agreementFingerprint", result.agreementFingerprint)
        try w.field("sourceConfigurationSHA256", a.sourceConfigurationSHA256)
        try w.field("artifactAggregateSHA256", a.artifactAggregateSHA256)
        try w.field("storageCommitmentSHA256", a.storageCommitmentSHA256)
        try w.field("planFingerprint", a.planFingerprint)
        try w.field("numericalPolicySHA256", a.numericalPolicySHA256)
        try w.field("protectedResourcePolicySHA256", sha256(try QwenResidentProtectedExperiment.resourcePolicyBytes()))
        try w.key("stageFingerprints"); try strings(a.stageFingerprints, into: w); try w.raw(",")
        try w.key("rankBuildSHA256"); try strings(a.rankBuildSHA256, into: w); try w.raw(",")
        try w.field("promptTokenIDsSHA256", qwenGenerationTokenHash(request.promptTokenIDs))
        try w.number("promptCount", request.promptCount); try w.number("chunkSize", request.chunkSize)
        try w.number("outputCount", request.outputCount); try w.field("prefillSchedule", "serial_v1")
        try w.key("stopTokenIDs"); try w.integers(request.stopTokenIDs.sorted()); try w.raw(",")
        try w.key("selectedTokenIDs"); try w.integers(result.selectedTokenIDs); try w.raw(",")
        try w.field("selectedTokenIDsSHA256", qwenGenerationTokenHash(result.selectedTokenIDs))
        try w.field("tokenChainSHA256", result.tokenChainSHA256)
        try w.number("completedFrames", result.completedFrames); try w.number("committedTokens", result.committedTokens)
        try w.field("finishReason", result.finishReason.rawValue)
        try w.flag("bothRequestStatesRetired", result.bothRequestStatesRetired)
        try w.number("logicalStateBytes", e.logicalStateBytes); try w.field("stageStateSHA256", e.stageStateSHA256)
        try w.key("stateEntries"); try w.raw("[")
        for (index, entry) in e.stateEntries.enumerated() {
            try check()
            if index > 0 { try w.raw(",") }; try w.raw("{")
            try w.number("globalLayerIndex", entry.globalLayerIndex); try w.field("component", entry.component)
            try w.key("shape"); try w.integers(entry.shape); try w.raw(",")
            try w.field("dtype", entry.dtype); try w.number("byteCount", entry.byteCount)
            try w.field("sha256", entry.sha256, comma: false); try w.raw("}")
        }
        try w.raw("],"); try w.key("finalLogits")
        if let row = e.finalLogits?.record { try logits(row, into: w, check: check) }
        else { try w.raw("null") }
        try w.raw(","); try w.key("captureBudget"); try w.raw("{")
        let b = e.captureBudget
        try w.number("originalRequestReservedBytes", b.originalRequestReservedBytes)
        try w.number("logicalRowBytes", b.logicalRowBytes); try w.number("float32RowBytes", b.float32RowBytes)
        try w.number("extraHostBytes", b.extraHostBytes); try w.number("extraNativeBytes", b.extraNativeBytes)
        try w.number("protectedReservedBytes", QwenResidentProtectedExperiment.reservedBytes)
        try w.number("exportHostAllowanceBytes", QwenProtectedEvidenceBudget.additionalHostBytes)
        try w.number("maximumEncodedBytes", QwenProtectedEvidenceBudget.maximumEncodedBytes)
        try w.number("totalReservedBytes", totalReservedBytes, comma: false); try w.raw("},")
        try w.number("captureResourceObservationCount", e.resourceObservationCount)
        try w.number("minimumCaptureActualFreeBytes", e.minimumObservedActualFreeBytes)
        try w.number("minimumCaptureAllocatorLimitBytes", e.minimumObservedAllocatorLimitBytes)
        try w.flag("correctnessOnly", true); try w.flag("throughputMeasurementValid", false)
        try w.flag("stateBytesIncluded", false); try w.flag("intermediateLogitRowsCompared", false)
        try w.flag("independentNumericalComparisonPerformed", false)
        try w.flag("ownerCleanupIndependentlyVerified", false); try w.flag("wholeProcessPeakProven", false)
        try w.flag("servingEnabled", false, comma: false); try w.raw("}")
    }

    private static func strings(_ values: [String], into w: QwenProtectedEvidenceJSON) throws {
        guard values.count == 2, values.allSatisfy(qwenStageWireIsSHA256) else {
            throw ProbeError("Protected evidence requires both exact stage/build hashes")
        }
        try w.raw("["); try w.string(values[0]); try w.raw(","); try w.string(values[1]); try w.raw("]")
    }

    static func logits(_ row: QwenRecordedLogitValues, into w: QwenProtectedEvidenceJSON,
                       check: () throws -> Void) throws {
        try w.raw("{"); try w.key("shape"); try w.integers(row.shape); try w.raw(",")
        try w.field("dtype", row.dtype); try w.number("byteCount", row.byteCount)
        try w.field("logicalBytesSHA256", row.logicalBytesSHA256); try w.key("values"); try w.raw("[")
        for (index, value) in row.values.enumerated() {
            if index % 1024 == 0 { try check() }
            if index > 0 { try w.raw(",") }; try w.floating(value)
        }
        try w.raw("]}")
    }
}
