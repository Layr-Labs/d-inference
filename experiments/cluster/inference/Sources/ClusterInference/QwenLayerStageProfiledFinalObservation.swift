import Foundation
import MLX

/// Native work only at the final frontier. Caller supplies the active MLX error
/// check; context operation guards fence callback/reentry failures separately.
enum QwenLayerStageProfiledFinalObservation {
    static func select(_ logits: MLXArray, identity: QwenLayerStageSessionIdentity,
        request: QwenLayerStageProfiledPrefillRecordedRequest, check: () throws -> Void
    ) throws -> QwenLayerStagePrefillTokenReceipt {
        try validate(logits, identity: identity, request: request)
        let selected = argMax(logits), finite = all(isFinite(logits))
        eval(logits, selected, finite); try check()
        guard selected.size == 1, selected.dtype == .uint32, finite.size == 1 else {
            throw ProbeError("Profiled native finite argmax produced the wrong scalar contract")
        }
        let allFinite = finite.item(Bool.self); try check()
        guard allFinite else { throw ProbeError("Profiled native final logits are not finite") }
        let token = selected.item(Int.self); try check()
        guard (0..<request.vocabularySize).contains(token) else { throw ProbeError("Profiled selected token exceeds vocabulary") }
        return .init(identity: identity, recordedRequestFingerprint: request.fingerprint,
            frame: request.steps.last!.frame, committedTokens: 8192, vocabularySize: request.vocabularySize,
            outputOrdinal: 0, selectionPolicy: QwenLayerStageProfiledPrefillMeasurementFlow.selectionPolicy,
            tokenID: token, logitsShape: logits.shape, logitsDType: "bfloat16",
            selectionDType: "uint32", allLogitsFinite: true)
    }

    /// One bounded copied row is hashed, then discarded before return. The
    /// resulting metadata cannot claim raw candidate/reference byte comparison.
    static func capture(_ logits: MLXArray, identity: QwenLayerStageSessionIdentity,
        request: QwenLayerStageProfiledPrefillRecordedRequest, check: () throws -> Void
    ) throws -> QwenLayerStagePrefillLogitMetadata {
        try validate(logits, identity: identity, request: request)
        let finite = all(isFinite(logits))
        eval(logits, finite); try check()
        guard finite.size == 1 else { throw ProbeError("Profiled diagnostic finiteness guard did not produce a scalar") }
        let allFinite = finite.item(Bool.self); try check()
        guard allFinite else { throw ProbeError("Profiled diagnostic final logits are not finite") }
        let bytes = logits.asData(access: .copy).data
        try check()
        guard bytes.count == 496_640, bytes.count == logits.nbytes else {
            throw ProbeError("Profiled copied final native row is incomplete")
        }
        let result = QwenLayerStagePrefillLogitMetadata(identity: identity,
            recordedRequestFingerprint: request.fingerprint, frame: request.steps.last!.frame,
            committedTokens: 8192, vocabularySize: request.vocabularySize,
            shape: logits.shape, dtype: "bfloat16", byteCount: bytes.count, logicalBytesSHA256: sha256(bytes))
        try check()
        return result
    }

    private static func validate(_ logits: MLXArray, identity: QwenLayerStageSessionIdentity,
                                 request: QwenLayerStageProfiledPrefillRecordedRequest) throws {
        guard identity.stageIndex == 1, identity.requestFingerprint == request.request.fingerprint,
              identity.activationDType == "bfloat16", request.request.profile == .longPrefill8KV1,
              request.request.promptCount == 8192, request.request.chunkSize == 512,
              request.request.outputCount == 1, request.teacherTokenIDs.isEmpty, request.steps.count == 16,
              request.vocabularySize == 248_320, request.steps.last?.committedTokens == 8192,
              request.steps.last?.frame.finalPromptChunk == true,
              logits.shape == [1, 248_320], logits.dtype == .bfloat16,
              logits.size == 248_320, logits.nbytes == 496_640 else {
            throw ProbeError("Profiled final observation requires the exact registered native vocabulary frontier")
        }
    }
}
