import MLX

enum QwenGenerationReferenceCapture {
    /// Independent full-model selection: the existing finite native argmax
    /// mechanics are checked against an actual complete CPU vocabulary copy.
    static func token(_ logits: MLXArray, request: QwenLayerStageGenerationRequest,
                      check: () throws -> Void) throws -> Int {
        guard logits.shape == [1, request.profile.vocabularySize],
              String(describing: logits.dtype) == request.profile.activationDType else {
            throw ProbeError("Generation reference output row differs from admitted geometry/dtype")
        }
        let selected = argMax(logits), finite = all(isFinite(logits))
        eval(selected, finite); try check()
        guard selected.size == 1, selected.dtype == .uint32, finite.size == 1 else {
            throw ProbeError("Generation reference finite argmax scalar differs")
        }
        let valid = finite.item(Bool.self); try check()
        guard valid else { throw ProbeError("Generation reference logits are not finite") }
        let token = Int(selected.item(UInt32.self)); try check()
        guard (0..<request.profile.vocabularySize).contains(token) else {
            throw ProbeError("Generation reference selected token exceeds vocabulary")
        }
        return token
    }

    static func evidence(_ logits: MLXArray, request: QwenLayerStageGenerationRequest,
                         frame: QwenLayerStageFrame, ordinal: Int, token: Int,
                         check: () throws -> Void
    ) throws -> (QwenGenerationReferenceTokenEvidence, QwenRecordedLogits) {
        let captured = try QwenRecordedLogits(logits,
            vocabularySize: request.profile.vocabularySize, check: check)
        guard let maximum = captured.record.values.max(),
              let first = captured.record.values.firstIndex(of: maximum), first == token else {
            throw ProbeError("Generation reference native selection differs from captured full row")
        }
        let evidence = QwenGenerationReferenceTokenEvidence(outputOrdinal: ordinal,
            frame: frame, committedTokens: frame.tokenOffset + frame.tokenCount, tokenID: token,
            maximumTieCount: captured.record.values.reduce(0) { $0 + ($1 == maximum ? 1 : 0) },
            maximumLogit: maximum, logitsShape: captured.record.shape,
            logitsDType: captured.record.dtype, logitsByteCount: captured.record.byteCount,
            logitsLogicalBytesSHA256: captured.record.logicalBytesSHA256)
        return (evidence, captured)
    }
}
