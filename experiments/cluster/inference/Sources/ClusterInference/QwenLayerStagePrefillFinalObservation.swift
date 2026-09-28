import Foundation
import MLX

/// Explicit final-only observation. Call inside the context's MLX error scope.
/// Selection/readback belongs inside any future first-token interval; full row
/// copying/hashing is a separate diagnostic operation after that interval.
enum QwenLayerStagePrefillFinalObservation {
    static let selectionPolicy = "mlx_argmax_all_axes_with_finite_guard_v1"

    static func select(_ logits: MLXArray, identity: QwenLayerStageSessionIdentity,
        request: QwenLayerStageRecordedRequest, frame: QwenLayerStageFrame,
        check: () throws -> Void
    ) throws -> QwenLayerStagePrefillTokenReceipt {
        try validate(logits, request: request, frame: frame)
        // Same uncast full-row argMax as Benchmark.execute. The finite guard is
        // additional explicit native work and must remain in the measured cost.
        let selected = argMax(logits)
        let finite = all(isFinite(logits))
        eval(logits, selected, finite)
        try check()
        guard selected.size == 1, finite.size == 1 else { throw ProbeError("Final-token selection did not produce scalars") }
        let allFinite = finite.item(Bool.self)
        try check()
        guard allFinite else { throw ProbeError("Final target logits contain nonfinite values") }
        let token = selected.item(Int.self)
        try check()
        guard (0..<request.vocabularySize).contains(token) else { throw ProbeError("Final selected token exceeds the vocabulary") }
        return .init(identity: identity, recordedRequestFingerprint: request.fingerprint,
            frame: frame, committedTokens: request.request.promptCount, vocabularySize: request.vocabularySize,
            outputOrdinal: 0, selectionPolicy: selectionPolicy, tokenID: token,
            logitsShape: logits.shape, logitsDType: String(describing: logits.dtype),
            selectionDType: String(describing: selected.dtype), allLogitsFinite: allFinite)
    }

    static func capture(_ logits: MLXArray, identity: QwenLayerStageSessionIdentity,
        request: QwenLayerStageRecordedRequest, frame: QwenLayerStageFrame,
        check: () throws -> Void
    ) throws -> QwenLayerStagePrefillLogitReceipt {
        try validate(logits, request: request, frame: frame)
        let finite = all(isFinite(logits))
        eval(logits, finite)
        try check()
        let allFinite = finite.item(Bool.self)
        try check()
        guard allFinite else { throw ProbeError("Diagnostic final logits contain nonfinite values") }
        let bytes = logits.asData(access: .copy).data
        try check()
        let metadata = QwenLayerStagePrefillLogitMetadata(identity: identity,
            recordedRequestFingerprint: request.fingerprint, frame: frame,
            committedTokens: request.request.promptCount, vocabularySize: request.vocabularySize,
            shape: logits.shape, dtype: String(describing: logits.dtype), byteCount: logits.nbytes,
            logicalBytesSHA256: sha256(bytes))
        return try .init(metadata: metadata, logicalBytes: bytes)
    }

    private static func validate(_ logits: MLXArray, request: QwenLayerStageRecordedRequest,
                                 frame: QwenLayerStageFrame) throws {
        guard request.request.outputCount == 1, request.teacherTokenIDs.isEmpty,
              frame == request.steps.last?.frame, frame.phase == .prefill, frame.finalPromptChunk,
              (1...262_144).contains(request.vocabularySize), logits.shape == [1, request.vocabularySize],
              [.float16, .bfloat16, .float32].contains(logits.dtype),
              logits.size == request.vocabularySize,
              logits.nbytes == request.vocabularySize * logits.dtype.size else {
            throw ProbeError("Final observation requires the complete bounded native last-position vocabulary row")
        }
    }
}
