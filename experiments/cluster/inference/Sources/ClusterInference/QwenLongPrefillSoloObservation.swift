import Foundation
import MLX

/// No fabricated stage identity. Selection is timed; native-row copying is not.
enum QwenLongPrefillSoloObservation {
    static func select(_ logits: MLXArray, request: QwenLayerStageProfiledPrefillRecordedRequest,
        check: () throws -> Void
    ) throws -> QwenLayerStageSoloPrefillSelection {
        try validate(logits, request: request)
        let selected = argMax(logits), finite = all(isFinite(logits))
        eval(logits, selected, finite); try check()
        guard selected.size == 1, selected.dtype == .uint32, finite.size == 1 else {
            throw ProbeError("Long solo finite argmax produced the wrong scalar contract")
        }
        let allFinite = finite.item(Bool.self); try check()
        guard allFinite else { throw ProbeError("Long solo final logits contain nonfinite values") }
        let token = selected.item(Int.self); try check()
        guard (0..<request.vocabularySize).contains(token) else { throw ProbeError("Long solo selected token exceeds vocabulary") }
        return .init(requestFingerprint: request.request.fingerprint,
            recordedRequestFingerprint: request.fingerprint, frame: request.steps.last!.frame,
            committedTokens: 8192, vocabularySize: request.vocabularySize, tokenID: token,
            logitsShape: logits.shape, logitsDType: String(describing: logits.dtype),
            selectionDType: String(describing: selected.dtype), allLogitsFinite: allFinite)
    }

    static func capture(_ logits: MLXArray, request: QwenLayerStageProfiledPrefillRecordedRequest,
        check: () throws -> Void
    ) throws -> QwenLayerStageSoloPrefillReference.Logits {
        try validate(logits, request: request)
        let bytes = logits.asData(access: .copy).data
        try check()
        guard bytes.count == 496_640, bytes.count == logits.nbytes else {
            throw ProbeError("Long solo native logit byte capture is incomplete")
        }
        return .init(shape: logits.shape, dtype: String(describing: logits.dtype),
            byteCount: bytes.count, logicalBytesSHA256: sha256(bytes))
    }

    private static func validate(_ logits: MLXArray,
        request: QwenLayerStageProfiledPrefillRecordedRequest) throws {
        guard request.request.profile == .longPrefill8KV1, request.request.promptCount == 8192,
              request.request.chunkSize == 512, request.request.outputCount == 1,
              request.teacherTokenIDs.isEmpty, request.steps.count == 16,
              request.vocabularySize == 248_320, request.steps.last?.committedTokens == 8192,
              request.steps.last?.frame.finalPromptChunk == true,
              logits.shape == [1, 248_320], logits.dtype == .bfloat16,
              logits.size == 248_320, logits.nbytes == 496_640 else {
            throw ProbeError("Long solo observation requires the registered complete BF16 vocabulary frontier")
        }
    }
}
