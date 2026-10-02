import Foundation
import MLX

/// Explicit registered workload admission, separate from every short-prompt
/// diagnostic. Retain and pin raw input bytes before initializing MLX.
enum QwenLongPrefillReferenceCLI {
    static func validateOptions(_ value: Options) throws {
        guard value.mode == .qwenLongPrefillReference, !value.synthetic,
              value.modelDirectory != nil, value.tokensFile != nil,
              let aggregate = value.expectedArtifactAggregateSHA256,
              QwenRegistered9BLongPrefillReferenceAdmission.isSHA256(aggregate),
              let promptSHA = value.longPromptSHA256,
              QwenRegistered9BLongPrefillReferenceAdmission.isSHA256(promptSHA),
              value.promptCount == 8192, value.chunkSize == 512, value.decodeCount == 1,
              value.repeats == 1, value.warmups == 0, value.seed == 7,
              (1...300).contains(value.timeoutSeconds),
              value.executionPath == .cbv2Contiguous, value.transport == .jaccl,
              value.partition == .ffn, !value.localCorrectness,
              value.attentionOutputPrecision == .native, value.ffnOutputPrecision == .native,
              value.ffnBranchPrecision == .native, value.teacherTokensFile == nil,
              value.logitsFile == nil, value.epoch == nil, !value.hasRoutingDiagnostic,
              !value.gemmaDiagnostic, value.gemmaBoundaryFile == nil,
              value.stagePrefillPolicy == nil, value.stageLogitsDType == nil,
              value.soloReferenceFile == nil, value.soloReferenceSHA256 == nil,
              value.soloBaselineEvidenceSHA256 == nil else {
            throw ProbeError("Long reference requires a pinned registered model and prompt, native CBv2 8192/512/1, one run, zero warmups, seed7, timeout<=300 and no other diagnostics")
        }
    }

    static func preflight(_ options: Options,
        arithmetic: QwenLongPrefillArithmeticEnvironment.Receipt
    ) throws -> QwenRegistered9BLongPrefillReferenceAdmission {
        try validateOptions(options)
        let configuration = try BoundedProbeInput.data(
            options.modelDirectory!.appendingPathComponent("config.json"), maximumBytes: 1024 * 1024)
        let prompt = try BoundedProbeInput.data(options.tokensFile!, maximumBytes: 65_536)
        return try .init(configuration: configuration,
            expectedArtifactAggregateSHA256: options.expectedArtifactAggregateSHA256!,
            promptData: prompt, expectedPromptSHA256: options.longPromptSHA256!,
            request: .init(profile: .longPrefill8KV1, requestID: UUID(), batchSize: 1,
                promptCount: 8192, chunkSize: 512, outputCount: 1), arithmetic: arithmetic)
    }
}

struct QwenLongPrefillReferenceReady: Encodable {
    let kind = "qwen_long_prefill_reference_ready", schemaVersion = 1
    let correctnessOnly = true, throughputMeasurementValid = false
    let verifiedModelLoaded = false, freshRequestStateCreated = false
    let profile: QwenLayerStagePrefillProfile
    let profileFingerprint: String, promptFileSHA256: String
    let arithmeticEnvironmentSHA256: String, recordedRequestFingerprint: String
}

struct QwenLongPrefillReferenceReport: Encodable {
    let kind = "qwen_long_prefill_reference_report", schemaVersion = 1
    let completed = true, correctnessOnly = true, throughputMeasurementValid = false
    let interprocessTransportUsed = false, physicalTransferQualified = false
    let allRequestStateRetired = true, modelReleased = true
    let evidence: QwenLongPrefillReferenceEvidence
    let memory: [QwenStageMemoryObservation]
}

func runQwenLongPrefillReference(options: Options,
    admission: QwenRegistered9BLongPrefillReferenceAdmission, check: () throws -> Void
) throws -> QwenLongPrefillReferenceReport {
    try QwenLongPrefillReferenceCLI.validateOptions(options)
    let before = QwenStageMemoryObservation("before_full_model_load")
    try emitJSON(QwenLongPrefillReferenceReady(profile: admission.request.request.profile,
        profileFingerprint: admission.request.request.profile.fingerprint,
        promptFileSHA256: admission.promptFileSHA256,
        arithmeticEnvironmentSHA256: admission.arithmeticEnvironmentSHA256,
        recordedRequestFingerprint: admission.request.fingerprint))
    let evidence = try produceQwenRegistered9BLongPrefillReference(
        directory: options.modelDirectory!, admission: admission, check: check)
    return .init(evidence: evidence,
        memory: [before, QwenStageMemoryObservation("full_model_released_cache_cleared")])
}
