import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

/// The native decode rectangle, separate from reservation, sampling, wire
/// decisions and cancellation. A caller must admit/fence all participating
/// sessions and commit their schedules only after this returns successfully.
/// Prefill retains the existing per-request chunk path. Only the registered
/// native BF16 contract is admitted; wider dtype batch kernels are unqualified.
enum GPTOSSBatchForward {
    static func decode(model: GPTOSSModel, head: Linear?, stageIndex: Int,
                       hiddenSize: Int, vocabularySize: Int, dtype: DType,
                       tokens: [Int], residual: MLXArray?,
                       histories: [[GPTOSSPagedKVCache]], check: () throws -> Void) throws -> MLXArray {
        let count = tokens.count, layers = model.cbv2LayerKinds.count
        guard dtype == .bfloat16, (1...8).contains(count), (0...1).contains(stageIndex), histories.count == count,
              histories.allSatisfy({ $0.count == layers && !$0.isEmpty }),
              Set(histories.flatMap { $0 }.map(ObjectIdentifier.init)).count == count * layers,
              tokens.allSatisfy({ (0..<vocabularySize).contains($0) }),
              histories.allSatisfy({ row in row.allSatisfy { $0.offset == row[0].offset } }),
              (head != nil) == (stageIndex == 1) else {
            throw ProbeError("GPT-OSS batch forward has incompatible stage, tokens or request histories")
        }
        if stageIndex == 0 {
            guard residual == nil else { throw ProbeError("GPT-OSS producer batch rejects supplied residuals") }
        } else {
            guard let residual, residual.shape == [count, 1, hiddenSize], residual.dtype == dtype else {
                throw ProbeError("GPT-OSS consumer batch residual differs from native [B,1,H]")
            }
        }
        for (layer, kind) in model.cbv2LayerKinds.enumerated() {
            let window: Int?
            switch kind.attention {
            case .full: window = nil
            case .slidingWindow(let size): window = size
            }
            guard kind.sharesKVWithLayer == nil,
                  histories.allSatisfy({ $0[layer].maxSize == window }) else {
                throw ProbeError("GPT-OSS batch history differs from the model's full/sliding geometry")
            }
        }
        let caches = try (0..<layers).map { layer in
            try GPTOSSBatchAttentionCache(histories.map { $0[layer] })
        }
        return try MLX.withError { error in
            func checked() throws { try error.check(); try check() }
            try checked()
            let input = MLXArray(tokens.map(Int32.init)).reshaped([count, 1])
            let hidden = model.model(input, cache: caches, inputEmbeddings: residual)
            let output = if let head { GPTOSSBatchDecodeProjection.linear(head, hidden)[0..., -1, 0...] } else { hidden }
            eval([output] + caches.flatMap { $0.innerState() })
            try checked()
            let expected = stageIndex == 0 ? [count, 1, hiddenSize] : [count, vocabularySize]
            guard output.shape == expected, output.dtype == dtype else {
                throw ProbeError("GPT-OSS batch output differs from its native shape/dtype")
            }
            return output
        }
    }
}
