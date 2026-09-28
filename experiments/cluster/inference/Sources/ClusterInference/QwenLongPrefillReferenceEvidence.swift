import Foundation

/// Source identity includes the canonical arithmetic receipt digest, ready for
/// a separately versioned future agreement. No host/path or resident content
/// hash is inferred from the deterministic loaded parameter layout.
struct QwenLongPrefillReferenceSource: Encodable {
    let artifactAggregateSHA256: String, sourceConfigurationSHA256: String
    let sourceParameterLayoutSHA256: String, planSHA256: String
    let arithmeticEnvironmentSHA256: String
    let bf16ConversionEnabled: Bool, embeddingActivationDType: String
    let sourceModelTensorBytes: Int, layerCount: Int, vocabularySize: Int
}

struct QwenLongPrefillReferenceSelection: Encodable {
    let requestFingerprint: String, recordedRequestFingerprint: String
    let frame: QwenLayerStageFrame
    let committedTokens: Int, vocabularySize: Int
    let outputOrdinal = 0
    let policy = "mlx_argmax_all_axes_with_finite_guard_v1"
    let cpuCrosscheckPolicy = "finite_maximum_lowest_vocabulary_index_v1"
    let tokenID: Int, maximumTieCount: Int
    let maximumLogit: Float
    let logitsShape: [Int], logitsDType: String, selectionDType: String
    let allLogitsFinite = true
    let nativeSelectionMatchesCapturedFullRow = true

    /// Bit-pattern spelling avoids making evidence identity depend on JSON
    /// floating-number formatting and preserves a possible signed zero.
    var fingerprint: String {
        sha256(Data([
            "qwen-long-prefill-reference-selection-v1", requestFingerprint, recordedRequestFingerprint,
            "\(frame.sequence)|\(frame.phase.rawValue)|\(frame.tokenOffset)|\(frame.tokenCount)|\(frame.finalPromptChunk)",
            "tokens=\(committedTokens)", "vocabulary=\(vocabularySize)", "ordinal=\(outputOrdinal)",
            policy, cpuCrosscheckPolicy, "token=\(tokenID)", "ties=\(maximumTieCount)",
            "maximumFloat32Bits=\(maximumLogit.bitPattern)", "\(logitsShape)|\(logitsDType)|\(selectionDType)",
            "finite=\(allLogitsFinite)", "selectionMatches=\(nativeSelectionMatchesCapturedFullRow)",
        ].joined(separator: "\n").utf8))
    }
}

/// One final row retains copied CPU native bytes privately through the existing
/// recorded-logit type, and exports all finite Float values plus the byte hash.
/// No native array, model, session, closure or state byte history escapes here.
struct QwenLongPrefillReferenceRequestResult: Encodable {
    let source: QwenLongPrefillReferenceSource
    let sourceLoad: VerifiedQwenDiagnosticReceipt
    let request: QwenLayerStageProfiledPrefillRecordedRequest
    let commits: [QwenLayerStageSoloPrefillCommit]
    let selection: QwenLongPrefillReferenceSelection
    let finalState: QwenRecordedState
    let finalLogits: QwenRecordedLogits
    let completedFrames: Int, committedTokens: Int
    let perFrameStateCaptures = 0, perFrameLogitCaptures = 0
    let finalStateCaptures = 1, finalLogitCaptures = 1, nativeTokenSelections = 1
    let allRequestStateRetired = true
    let intermediateNumericalStatesExported = false
    let candidateNumericalComparisonPerformed = false
}

/// New reference namespace; it neither decodes nor accepts the old65 reference.
/// Created only after the owner has checked both request retirement and model
/// release. The fingerprint uses CPU identities and the full native row hash.
struct QwenLongPrefillReferenceEvidence: Encodable {
    let kind = "qwen_registered9b_long_prefill_reference"
    let schemaVersion = 1
    let correctnessOnly = true, throughputMeasurementValid = false
    let interprocessTransportUsed = false, physicalTransferQualified = false
    let fullModelLoads = 1, freshFullModelRequests = 1, stageModelsLoaded = 0
    let modelReleased = true, allRequestStateRetired = true
    let profile: QwenLayerStagePrefillProfile
    let profileFingerprint: String
    let promptFileSHA256: String, promptTokenIDsSHA256: String
    let arithmeticEnvironment: QwenLongPrefillArithmeticEnvironment.Receipt
    let arithmeticEnvironmentSHA256: String
    let resourceAdmission: QwenRegistered9BLongPrefillAdmission.Receipt
    let execution: QwenLongPrefillReferenceRequestResult
    let fingerprint: String

    init(admission: QwenRegistered9BLongPrefillReferenceAdmission,
         execution: QwenLongPrefillReferenceRequestResult) throws {
        let profile = admission.request.request.profile
        guard execution.request.fingerprint == admission.request.fingerprint,
              execution.source.arithmeticEnvironmentSHA256 == admission.arithmeticEnvironmentSHA256,
              execution.completedFrames == 16, execution.committedTokens == 8192,
              execution.commits.count == admission.request.steps.count,
              zip(execution.commits, admission.request.steps).allSatisfy({ commit, step in
                  commit.frame == step.frame && commit.committedTokens == step.committedTokens
                      && commit.outputShape == [1, step.expectsLogits ? admission.request.vocabularySize : 1]
                      && commit.outputKind == (step.expectsLogits ? "logits" : "evaluation_handle")
                      && commit.outputDType == "bfloat16"
              }), execution.finalState.committedTokens == 8192,
              execution.finalState.entries.count == 72,
              execution.finalLogits.record.shape == [1, 248_320],
              execution.finalLogits.record.dtype == "bfloat16",
              execution.finalLogits.record.byteCount == 496_640,
              execution.selection.frame == admission.request.steps.last?.frame else {
            throw ProbeError("Long reference result omitted its exact profile, final row or commit coverage")
        }
        self.profile = profile
        self.profileFingerprint = profile.fingerprint
        self.promptFileSHA256 = admission.promptFileSHA256
        self.promptTokenIDsSHA256 = admission.promptTokenIDsSHA256
        self.arithmeticEnvironment = admission.arithmetic
        self.arithmeticEnvironmentSHA256 = admission.arithmeticEnvironmentSHA256
        self.resourceAdmission = admission.resource; self.execution = execution
        self.fingerprint = sha256(Data([
            "qwen-registered9b-long-prefill-reference-v1", profile.rawValue, profile.fingerprint,
            admission.request.fingerprint, admission.promptFileSHA256, admission.promptTokenIDsSHA256,
            admission.arithmeticEnvironmentSHA256, sha256(try canonicalJSONData(admission.resource)),
            sha256(try canonicalJSONData(execution.source)), sha256(try canonicalJSONData(execution.sourceLoad)),
            sha256(try canonicalJSONData(execution.commits)), execution.finalState.fingerprint,
            execution.finalLogits.record.logicalBytesSHA256, execution.selection.fingerprint,
        ].joined(separator: "\n").utf8))
    }
}
