import MLX

enum QwenLayerStageGenerationSelection {
    /// Same finite native argmax/scalar mechanics as the existing final-token
    /// observer. No draft/MTP token and no full-vocabulary CPU copy is emitted.
    static func token(_ logits: MLXArray, request: QwenLayerStageGenerationRequest,
                      check: () throws -> Void) throws -> Int {
        guard logits.shape == [1, request.profile.vocabularySize],
              String(describing: logits.dtype) == request.profile.selectedRowDType else {
            throw ProbeError("Generation selected row differs from admitted native shape/dtype")
        }
        if let sampler = request.sampler {
            return try sampled(logits, sampler: sampler, vocabularySize: request.profile.vocabularySize, check: check)
        }
        let selected = argMax(logits), finite = all(isFinite(logits))
        eval(logits, selected, finite); try check()
        guard selected.size == 1, selected.dtype == .uint32, finite.size == 1 else {
            throw ProbeError("Generation finite argmax scalar contract differs")
        }
        let valid = finite.item(Bool.self); try check()
        guard valid else { throw ProbeError("Generation target logits are not finite") }
        let token = Int(selected.item(UInt32.self)); try check()
        guard (0..<request.profile.vocabularySize).contains(token) else { throw ProbeError("Generation selected token outside vocabulary") }
        return token
    }

    /// The product's sampler for a request that is not plain greedy text. The
    /// raw target row must be finite, as for the argmax.
    private static func sampled(_ logits: MLXArray, sampler: QwenStageTokenSampler, vocabularySize: Int,
                                check: () throws -> Void) throws -> Int {
        let selected = sampler.sample(logits).reshaped([-1]).asType(.int32), finite = all(isFinite(logits))
        eval(selected, finite); try check()
        guard selected.size == 1, finite.size == 1 else { throw ProbeError("Generation sampled scalar contract differs") }
        let valid = finite.item(Bool.self); try check()
        guard valid else { throw ProbeError("Generation target logits are not finite") }
        let token = Int(selected.item(Int32.self)); try check()
        guard (0..<vocabularySize).contains(token) else { throw ProbeError("Generation sampled token outside vocabulary") }
        sampler.commit(token)
        return token
    }
}
