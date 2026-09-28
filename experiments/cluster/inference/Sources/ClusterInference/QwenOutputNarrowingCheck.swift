import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

private struct QwenNarrowingTensor: Encodable {
    let shape: [Int]
    let dtype: String
    let logicalBytesSHA256: String

    init(_ array: MLXArray) {
        shape = array.shape
        dtype = String(describing: array.dtype)
        // The array remains owned throughout hashing; noncontiguous inputs copy.
        logicalBytesSHA256 = sha256(array.asData(access: .noCopyIfContiguous).data)
    }
}

private struct QwenNarrowingRow: Encodable {
    let tensor: QwenNarrowingTensor
    let argmaxToken: Int
    let argmaxValue: Float

    init(_ array: MLXArray, values: [Float]) throws {
        guard !values.isEmpty, values.allSatisfy(\.isFinite) else {
            throw ProbeError("Output narrowing produced an empty or nonfinite row")
        }
        tensor = QwenNarrowingTensor(array)
        var index = 0
        for i in values.indices.dropFirst() where values[i] > values[index] { index = i }
        argmaxToken = index
        argmaxValue = values[index]
    }
}

private struct QwenNarrowingDifference: Encodable {
    let comparedValues: Int
    let exactValues: Bool
    let differingValues: Int
    let maximumAbsoluteError: Double
    let rootMeanSquareError: Double
    let relativeRMSError: Double

    init(reference: [Float], candidate: [Float]) throws {
        guard !reference.isEmpty, reference.count == candidate.count,
              reference.allSatisfy(\.isFinite), candidate.allSatisfy(\.isFinite) else {
            throw ProbeError("Output narrowing comparison has invalid values or dimensions")
        }
        var count = 0, maximum = 0.0, squares = 0.0, referenceSquares = 0.0
        for (a, b) in zip(reference, candidate) {
            let difference = Double(b) - Double(a)
            if a != b { count += 1 }
            maximum = max(maximum, abs(difference))
            squares += difference * difference
            referenceSquares += Double(a) * Double(a)
        }
        comparedValues = reference.count; differingValues = count; exactValues = count == 0
        maximumAbsoluteError = maximum
        rootMeanSquareError = sqrt(squares / Double(reference.count))
        relativeRMSError = sqrt(squares / max(referenceSquares, 1e-30))
    }
}

private struct QwenOutputNarrowingResult: Encodable {
    let schemaVersion = 1
    let kind = "qwen_output_narrowing_check"
    let diagnosticOnly = true
    let throughputValid = false
    let timestampUTC: String
    let executionPath = "ordinary"
    let mtpEnabled = false
    let model: String
    let syntheticWeights: Bool
    let syntheticProfile: String
    let seed: UInt64
    let configurationSHA256: String
    let parameterLayoutSHA256: String
    let embeddingActivationDType: String
    let ffnScaleDTypes: [String]
    let bf16ConversionEnabled: Bool
    let promptSHA256: String
    let promptTokenIDs: [Int]
    let chunkSize: Int
    let evaluatedChunkWidths: [Int]
    let hidden: QwenNarrowingTensor
    let fullNormalized: QwenNarrowingTensor
    let fullOrdinaryLogits: QwenNarrowingTensor
    let normPath: String
    let normEpsilon: Float
    let normWeight: QwenNarrowingTensor
    let headPath: String
    let headQuantization = "affine-W4-G64"
    let headWeight: QwenNarrowingTensor
    let headScales: QwenNarrowingTensor
    let headBiases: QwenNarrowingTensor
    let normAfterFullValues: [Float]
    let normAfterSliceValues: [Float]
    let normAfterFull: QwenNarrowingTensor
    let normAfterSlice: QwenNarrowingTensor
    let ordinaryFullLast: QwenNarrowingRow
    let recomputedFullLast: QwenNarrowingRow
    let sliceAfterNormBeforeHead: QwenNarrowingRow
    let sliceBeforeNormAndHead: QwenNarrowingRow
    let originalVersusRecomputedFull: QwenNarrowingDifference
    let normFullVersusSliced: QwenNarrowingDifference
    let headFullVersusSingleRow: QwenNarrowingDifference
    let narrowedNormContribution: QwenNarrowingDifference
    let ordinaryVersusFullyNarrowed: QwenNarrowingDifference
    let sourceSeams: [String]
    let limitations: [String]
}

private func qwenNarrowingValues(_ array: MLXArray, check: () throws -> Void) throws -> [Float] {
    let float = array.asType(.float32)
    eval(float)
    try check()
    let values = float.asArray(Float.self)
    try check()
    guard values.allSatisfy(\.isFinite) else { throw ProbeError("Nonfinite output narrowing tensor") }
    return values
}

/// The public hidden-returning ordinary forward does not require an MTP head.
/// Every chunk is evaluated before advancing its fresh KV/recurrent caches.
private func qwenNarrowingCapture(model: any LanguageModel, capture: any MTPCapable,
                                  prompt: [Int], chunkSize: Int,
                                  check: () throws -> Void) throws
    -> (logits: MLXArray, hidden: MLXArray, widths: [Int]) {
    let caches = model.newCache(parameters: nil)
    var final: (MLXArray, MLXArray)?
    var widths: [Int] = []
    for start in stride(from: 0, to: prompt.count, by: chunkSize) {
        let end = min(start + chunkSize, prompt.count)
        let tokens = MLXArray(Array(prompt[start..<end])).reshaped([1, end - start])
        let output = capture.callWithHidden(input: LMInput.Text(tokens: tokens),
                                            cache: caches, nConfirmed: 0)
        eval([output.0, output.1] + caches.flatMap { $0.innerState() })
        try check()
        widths.append(end - start)
        if end == prompt.count { final = output }
    }
    guard let final else { throw ProbeError("Output narrowing has no final prompt chunk") }
    return (final.0, final.1, widths)
}

/// Isolates norm and vocabulary projection shape changes using one evaluated
/// actual-model hidden tensor. Numeric differences are observations, not failures.
func runQwenOutputNarrowingCheck(options: Options) throws {
    guard options.executionPath == .ordinary, options.partition == .ffn,
          options.attentionOutputPrecision == .native, options.ffnOutputPrecision == .native,
          options.ffnBranchPrecision == .native,
          options.transport == .jaccl, (1...512).contains(options.promptCount),
          (1...512).contains(options.chunkSize), !options.hasRoutingDiagnostic,
          !options.gemmaDiagnostic else {
        throw ProbeError("Output narrowing requires ordinary native solo arithmetic and prompt/chunk bounds 1...512")
    }
    try MLX.withError { error in
        defer { Stream.gpu.synchronize(); Stream.cpu.synchronize() }
        let check = { try error.check() }
        let loaded = try loadModel(options)
        try check()
        guard loaded.family == .qwen35, loaded.feedForwardKind == "dense",
              loaded.partitionPlan == nil, loaded.partitionStorage == nil,
              loaded.model is Qwen35TextModel || loaded.model is Qwen35Model,
              let capture = loaded.model as? any MTPCapable, !capture.hasMTPHead else {
            throw ProbeError("Output narrowing requires an unpartitioned dense Qwen35 model with MTP disabled")
        }
        let prefix = loaded.model is Qwen35Model ? "language_model." : ""
        let normPath = prefix + "model.norm", headPath = prefix + "lm_head"
        let modules = Dictionary(uniqueKeysWithValues: loaded.model.namedModules())
        guard let norm = modules[normPath] as? RMSNorm,
              let head = modules[headPath] as? QuantizedLinear,
              ObjectIdentifier(type(of: head)) == ObjectIdentifier(QuantizedLinear.self),
              head.mode == .affine, head.bits == 4, head.groupSize == 64,
              head.bias == nil, head.weight.dtype == .uint32, head.weight.ndim == 2,
              head.shape.0 == loaded.vocabularySize, head.shape.1 > 0,
              head.shape.1 % 64 == 0, norm.weight.shape == [head.shape.1],
              head.scales.shape == [head.shape.0, head.shape.1 / 64],
              let biases = head.biases, biases.shape == head.scales.shape,
              [norm.weight, head.scales, biases].allSatisfy({ [.float16, .bfloat16, .float32].contains($0.dtype) }) else {
            throw ProbeError("Output narrowing requires the actual final RMSNorm and untied affine W4/G64 lm_head")
        }
        let prompt = try promptTokens(options: options, vocabularySize: loaded.vocabularySize)
        guard (1...512).contains(prompt.count) else { throw ProbeError("Output narrowing allows at most512 actual prompt tokens") }
        guard let configuration = try JSONSerialization.jsonObject(with: loaded.configurationData) as? [String: Any] else {
            throw ProbeError("Output narrowing requires a Qwen configuration object")
        }
        let text = configuration["text_config"] as? [String: Any] ?? configuration
        guard prompt.count <= (try qwenPartitionInteger(text, "max_position_embeddings")) else {
            throw ProbeError("Output narrowing prompt exceeds the model context bound")
        }
        let captured = try qwenNarrowingCapture(model: loaded.model, capture: capture,
            prompt: prompt, chunkSize: options.chunkSize, check: check)
        guard let width = captured.widths.last,
              captured.hidden.shape == [1, width, head.shape.1],
              captured.logits.shape == [1, width, loaded.vocabularySize] else {
            throw ProbeError("Output narrowing capture returned unexpected tensor geometry")
        }
        // Keep the same evaluated hidden tensor alive for every branch.
        let hidden = captured.hidden
        let normalized = norm(hidden)
        let lastAfterNorm = normalized[0..., -1, 0...]
        let lastBeforeNorm = norm(hidden[0..., -1, 0...])
        eval(normalized, lastAfterNorm, lastBeforeNorm)
        try check()
        let ordinaryLast = captured.logits[0..., -1, 0...]
        let recomputedFull = head(normalized)
        let recomputedLast = recomputedFull[0..., -1, 0...]
        let beforeHead = head(lastAfterNorm)
        let beforeNorm = head(lastBeforeNorm)
        eval(ordinaryLast, recomputedFull, beforeHead, beforeNorm)
        try check()
        let normA = try qwenNarrowingValues(lastAfterNorm, check: check)
        let normB = try qwenNarrowingValues(lastBeforeNorm, check: check)
        let original = try qwenNarrowingValues(ordinaryLast, check: check)
        let full = try qwenNarrowingValues(recomputedLast, check: check)
        let slicedHead = try qwenNarrowingValues(beforeHead, check: check)
        let slicedBoth = try qwenNarrowingValues(beforeNorm, check: check)
        let result = QwenOutputNarrowingResult(
            timestampUTC: ISO8601DateFormatter().string(from: Date()), model: loaded.label,
            syntheticWeights: options.synthetic, syntheticProfile: options.synthetic ? options.syntheticProfile : "none",
            seed: options.seed, configurationSHA256: loaded.configHash,
            parameterLayoutSHA256: loaded.parameterLayoutSHA256,
            embeddingActivationDType: loaded.embeddingActivationDType, ffnScaleDTypes: loaded.ffnScaleDTypes,
            bf16ConversionEnabled: loaded.bf16ConversionEnabled,
            promptSHA256: sha256(try JSONEncoder().encode(prompt)), promptTokenIDs: prompt,
            chunkSize: options.chunkSize, evaluatedChunkWidths: captured.widths,
            hidden: QwenNarrowingTensor(hidden), fullNormalized: QwenNarrowingTensor(normalized),
            fullOrdinaryLogits: QwenNarrowingTensor(captured.logits), normPath: normPath,
            normEpsilon: norm.eps, normWeight: QwenNarrowingTensor(norm.weight), headPath: headPath,
            headWeight: QwenNarrowingTensor(head.weight), headScales: QwenNarrowingTensor(head.scales),
            headBiases: QwenNarrowingTensor(biases), normAfterFullValues: normA, normAfterSliceValues: normB,
            normAfterFull: QwenNarrowingTensor(lastAfterNorm), normAfterSlice: QwenNarrowingTensor(lastBeforeNorm),
            ordinaryFullLast: try QwenNarrowingRow(ordinaryLast, values: original),
            recomputedFullLast: try QwenNarrowingRow(recomputedLast, values: full),
            sliceAfterNormBeforeHead: try QwenNarrowingRow(beforeHead, values: slicedHead),
            sliceBeforeNormAndHead: try QwenNarrowingRow(beforeNorm, values: slicedBoth),
            originalVersusRecomputedFull: try .init(reference: original, candidate: full),
            normFullVersusSliced: try .init(reference: normA, candidate: normB),
            headFullVersusSingleRow: try .init(reference: full, candidate: slicedHead),
            narrowedNormContribution: try .init(reference: slicedHead, candidate: slicedBoth),
            ordinaryVersusFullyNarrowed: try .init(reference: original, candidate: slicedBoth),
            sourceSeams: [
                "MLXLLM/Models/Qwen35.swift: Qwen35TextModel.callWithHidden(input:cache:nConfirmed:)",
                "MLXLLM/Models/Qwen35.swift: Qwen35TextModel.cbv2RecurrentPrefill lastPositionLogits",
                "MLXNN/Normalization.swift: RMSNorm.callAsFunction",
                "MLXNN/Quantized.swift: QuantizedLinear.callAsFunction",
                "Cmlx/mlx/mlx/backend/metal/quantized.cpp: QuantizedMatmul::eval_gpu and qmm_splitk",
            ], limitations: [
                "One ordinary prefill capture; no CBv2 trunk or cache-state equality is established.",
                "All prefix chunks evaluate full hidden/logit/cache roots; ordinary prepare normally discards prefix logits.",
                "Same captured hidden and stored norm/head parameters are reused; neither weights nor activations are widened.",
                "Parameter layout is not a complete weight-content attestation; norm and head tensor bytes are hashed explicitly.",
                "Single diagnostic prefill; benchmark decode, repeat, warmup and output-file options are not consumed.",
                "Observed numeric differences are not assigned a pass/fail threshold or a production quality conclusion.",
            ])
        try check()
        try emitJSON(result)
    }
}
