import Foundation

/// Small host commit metadata; no cache snapshots, logit vectors or native roots.
struct QwenLayerStagePrefillCommit: Encodable {
    let identity: QwenLayerStageSessionIdentity
    let recordedRequestFingerprint: String
    let frame: QwenLayerStageFrame
    let committedTokens: Int
    let outputKind: String
    let outputShape: [Int]
    let outputDType: String
}

/// The caller owns this native boundary until completed transfer and release.
/// The context does not retain it. It is intentionally not Encodable.
struct QwenLayerStagePrefillPrepared {
    let boundary: QwenLayerStageBoundary
    let expectation: QwenLayerStageBoundaryWireExpectation
    let commit: QwenLayerStagePrefillCommit
}

/// Local CPU selection evidence only, not a wire message or token-delivery ACK.
/// A future receipt protocol must separately admit the cohort epoch and sender.
struct QwenLayerStagePrefillTokenReceipt: Encodable {
    let kind = "qwen_layer_stage_prefill_local_token"
    let identity: QwenLayerStageSessionIdentity
    let recordedRequestFingerprint: String
    let frame: QwenLayerStageFrame
    let committedTokens: Int
    let vocabularySize: Int
    let outputOrdinal: Int
    let selectionPolicy: String
    let tokenID: Int
    let logitsShape: [Int]
    let logitsDType: String
    let selectionDType: String
    let allLogitsFinite: Bool
}

struct QwenLayerStagePrefillLogitMetadata: Encodable {
    let kind = "qwen_layer_stage_prefill_final_logits"
    let identity: QwenLayerStageSessionIdentity
    let recordedRequestFingerprint: String
    let frame: QwenLayerStageFrame
    let committedTokens: Int
    let vocabularySize: Int
    let shape: [Int]
    let dtype: String
    let byteCount: Int
    let logicalBytesSHA256: String
}

/// Exact copied native logical bytes, privately retained on CPU. Encoding emits
/// metadata/SHA only: no MLXArray, raw byte vector or full-vocabulary Float JSON.
struct QwenLayerStagePrefillLogitReceipt: Encodable {
    let metadata: QwenLayerStagePrefillLogitMetadata
    private let logicalBytes: Data

    init(metadata: QwenLayerStagePrefillLogitMetadata, logicalBytes: Data) throws {
        guard logicalBytes.count == metadata.byteCount,
              sha256(logicalBytes) == metadata.logicalBytesSHA256 else {
            throw ProbeError("Final-logit receipt differs from its copied logical bytes")
        }
        self.metadata = metadata
        self.logicalBytes = logicalBytes
    }

    /// Checks numerical bytes only. Caller must independently bind source and
    /// input identity when comparing separate runs with different request UUIDs.
    func requireExactLogicalMatch(_ candidate: QwenLayerStagePrefillLogitReceipt) throws {
        guard metadata.shape == candidate.metadata.shape, metadata.dtype == candidate.metadata.dtype,
              metadata.byteCount == candidate.metadata.byteCount,
              metadata.logicalBytesSHA256 == candidate.metadata.logicalBytesSHA256,
              logicalBytes == candidate.logicalBytes else {
            throw ProbeError("Final native vocabulary logits differ in shape, dtype or logical bytes")
        }
    }

    /// Baseline bridge requires root's planned QwenRecordedLogits byte-check
    /// method; no private native bytes are exposed to transport or JSON.
    func requireExact(_ baseline: QwenRecordedLogits) throws {
        try baseline.requireExactNativeBytes(shape: metadata.shape, dtype: metadata.dtype,
            bytes: logicalBytes, frontier: metadata.committedTokens)
    }

    func encode(to encoder: Encoder) throws { try metadata.encode(to: encoder) }
}
