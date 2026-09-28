import Foundation

/// Exactly one full recording, retirement and publication precede the pair.
/// The publisher receives CPU evidence only, after all full-owner release checks.
func runQwenDenseShortParity(directory: URL, admission: QwenDenseShortReferenceAdmission,
    onBaseline: (QwenDenseShortBaselineCheckpoint) throws -> Void, check: () throws -> Void
) throws -> QwenDenseShortParityReport {
    try check()
    let baseline = try recordQwenDenseShortBaseline(directory: directory, admission: admission, check: check)
    try QwenDenseShortParityBinding.requireBaseline(baseline.baseline, admission: admission)
    try check(); try onBaseline(baseline); try check()
    let pair = try compareQwenDenseShortPair(directory: directory, admission: admission,
        baseline: baseline.baseline, check: check)
    try check()
    guard pair.comparison.allRequestStateRetired,
          pair.comparison.baselineEvidenceSHA256 == baseline.baseline.fingerprint,
          pair.comparison.requestSHA256 == admission.request.fingerprint,
          pair.comparison.frames.map(\.committedTokens) == [2, 3, 4],
          pair.comparison.frames.allSatisfy(\.stateMetadataAndDigestsExact),
          pair.comparison.frames.map(\.nativeLogitBytesExact) == [nil, true, true] else {
        throw ProbeError("Short parity omitted its exact recorded comparison or retirement")
    }
    return .init(model: admission.metadata.specification.model,
        referenceAdmissionFingerprint: admission.fingerprint, recordedRequestFingerprint: admission.request.fingerprint,
        promptSHA256: admission.promptSHA256, teacherSHA256: admission.teacherSHA256,
        baselineEvidenceSHA256: baseline.baseline.fingerprint, pair: pair)
}
