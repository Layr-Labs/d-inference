import Foundation
import MLX

/// Actual solo observation with no fabricated stage identity. Call only inside
/// the request owner's MLX error scope. Selection is inside its clock; byte
/// copying/hashing is a separate post-stop operation.
enum QwenLayerStageSoloPrefillObservation {
    static func select(_ logits: MLXArray, request: QwenLayerStageRecordedRequest,
        frame: QwenLayerStageFrame, check: () throws -> Void
    ) throws -> QwenLayerStageSoloPrefillSelection {
        try validate(logits, request: request, frame: frame)
        // Same operations/order as QwenLayerStagePrefillFinalObservation.select.
        let selected = argMax(logits)
        let finite = all(isFinite(logits))
        eval(logits, selected, finite)
        try check()
        guard selected.size == 1, selected.dtype == .uint32, finite.size == 1 else {
            throw ProbeError("Solo finite argmax did not return the pinned native scalar contract")
        }
        let allFinite = finite.item(Bool.self); try check()
        guard allFinite else { throw ProbeError("Solo final target logits contain nonfinite values") }
        let token = selected.item(Int.self); try check()
        guard (0..<request.vocabularySize).contains(token) else { throw ProbeError("Solo selected token exceeds vocabulary") }
        return .init(requestFingerprint: request.request.fingerprint, recordedRequestFingerprint: request.fingerprint,
            frame: frame, committedTokens: request.request.promptCount, vocabularySize: request.vocabularySize,
            tokenID: token, logitsShape: logits.shape, logitsDType: String(describing: logits.dtype),
            selectionDType: String(describing: selected.dtype), allLogitsFinite: allFinite)
    }

    static func capture(_ logits: MLXArray, request: QwenLayerStageRecordedRequest,
        frame: QwenLayerStageFrame, check: () throws -> Void
    ) throws -> QwenLayerStageSoloPrefillReference.Logits {
        try validate(logits, request: request, frame: frame)
        // This is an owned copy of native logical bytes, not reconstructed
        // Float32 values. Only metadata and the SHA leave this scope.
        let bytes = logits.asData(access: .copy).data
        try check()
        guard bytes.count == logits.nbytes else { throw ProbeError("Solo native logit byte capture is incomplete") }
        return .init(shape: logits.shape, dtype: String(describing: logits.dtype),
            byteCount: bytes.count, logicalBytesSHA256: sha256(bytes))
    }

    private static func validate(_ logits: MLXArray, request: QwenLayerStageRecordedRequest,
        frame: QwenLayerStageFrame) throws {
        guard request.request.outputCount == 1, request.teacherTokenIDs.isEmpty,
              frame == request.steps.last?.frame, frame.phase == .prefill, frame.finalPromptChunk,
              (1...262_144).contains(request.vocabularySize), logits.shape == [1, request.vocabularySize],
              [.float16, .bfloat16, .float32].contains(logits.dtype),
              logits.size == request.vocabularySize,
              logits.nbytes == request.vocabularySize * logits.dtype.size else {
            throw ProbeError("Solo observation requires the complete bounded native final vocabulary row")
        }
    }
}
