import Foundation

struct QwenLayerStageProfiledComputeSource: Encodable {
    let stageIndex: Int
    let artifactAggregateSHA256: String, sourceConfigurationSHA256: String
    let sourceParameterLayoutSHA256: String
    let sourceModelTensorBytes: Int, loadedTensorBytes: Int
    let planSHA256: String, storageCommitmentSHA256: String, sourceLoadReceiptSHA256: String
    let arithmeticEnvironmentSHA256: String, promptFileSHA256: String, promptTokenIDsSHA256: String
    let bf16ConversionEnabled: Bool
    let embeddingActivationDType: String
}

/// Exactly one caller-owned native residual; not a CPU ticket and not Encodable.
/// No copy, cast, send, or ownership claim is hidden in this return type.
struct QwenLayerStageProfiledPrefillPrepared {
    let boundary: QwenLayerStageBoundary
    let expectation: QwenLayerStageProfiledBoundaryWireExpectation
    let commit: QwenLayerStagePrefillCommit
}

/// One stage's final global component namespace. No raw state bytes are retained.
struct QwenLayerStageProfiledStateDigest: Encodable {
    let committedTokens: Int
    let entries: [QwenRecordedState.Entry]
    let logicalByteCount: Int
    let fingerprint: String
}

/// Final-only CPU evidence. The live context must still be explicitly retired.
/// This is neither a reference nor a claim of candidate/reference equality.
struct QwenLayerStageProfiledPrefillFinalDigest: Encodable {
    let kind = "qwen_layer_stage_profiled_prefill_final_digest"
    let schemaVersion = 1
    let correctnessOnly = true, throughputMeasurementValid = false
    let modelForwardCompared = false, physicalTransferQualified = false
    let nativeLogitBytesCompared = false, fullVocabularyValuesExported = false
    let requestStateRetirementStillRequired = true
    let externalPostStopOrderingStillRequired = true
    let profile: QwenLayerStagePrefillProfile
    let profileFingerprint: String, agreementFingerprint: String
    let identity: QwenLayerStageSessionIdentity
    let recordedRequestFingerprint: String
    let source: QwenLayerStageProfiledComputeSource
    let completedFrames: Int, committedTokens: Int
    let finalState: QwenLayerStageProfiledStateDigest
    let finalLogits: QwenLayerStagePrefillLogitMetadata?
    let perFrameStateCaptures = 0, perFrameLogitCaptures = 0
    let finalStateCaptures = 1
    let finalLogitCaptures: Int, nativeTokenSelections: Int
    let fingerprint: String

    init(admission: QwenLayerStageProfiledComputeAdmission, identity: QwenLayerStageSessionIdentity,
         state: QwenLayerStageProfiledStateDigest, logits: QwenLayerStagePrefillLogitMetadata?) throws {
        guard identity.stageIndex == admission.stageIndex,
              identity.requestFingerprint == admission.local.request.request.fingerprint,
              state.committedTokens == 8192, (logits != nil) == (identity.stageIndex == 1) else {
            throw ProbeError("Profiled final evidence is missing its role or final frontier")
        }
        let profile = admission.local.request.request.profile
        self.profile = profile; profileFingerprint = profile.fingerprint
        agreementFingerprint = admission.agreement.fingerprint; self.identity = identity
        recordedRequestFingerprint = admission.local.request.fingerprint; source = admission.source
        completedFrames = 16; committedTokens = 8192; finalState = state; finalLogits = logits
        finalLogitCaptures = logits == nil ? 0 : 1; nativeTokenSelections = logits == nil ? 0 : 1
        let logitMetadataHash = try logits.map { sha256(try canonicalJSONData($0)) } ?? "no-logits"
        fingerprint = sha256(Data(["qwen-layer-stage-profiled-prefill-final-digest-v1",
            agreementFingerprint, profile.rawValue, profileFingerprint, recordedRequestFingerprint,
            sha256(try canonicalJSONData(identity)), sha256(try canonicalJSONData(source)),
            state.fingerprint, logitMetadataHash,
        ].joined(separator: "\n").utf8))
    }
}
