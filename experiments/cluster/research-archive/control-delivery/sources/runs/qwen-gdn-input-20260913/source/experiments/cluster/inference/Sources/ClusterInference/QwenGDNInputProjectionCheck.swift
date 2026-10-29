import Foundation
import MLX
import MLXLLM
import MLXLMCommon

private struct QwenGDNInputProjectionReport: Encodable {
    let schemaVersion = 1
    let kind = "qwen_gdn_input_projection_check"
    let correctnessOnly = true
    let throughputMeasurementValid = false
    let timestampUTC: String
    let executionPath = "cbv2-contiguous"
    let mtpEnabled = false
    let model: String
    let modelFamily = "qwen35"
    let syntheticWeights: Bool
    let syntheticProfile: String
    let seed: UInt64
    let configurationSHA256: String
    let parameterLayoutSHA256: String
    let bf16ConversionEnabled: Bool
    let verifiedDiagnosticLoad: VerifiedQwenDiagnosticReceipt?
    let promptSHA256: String
    let promptTokenIDs: [Int]
    let chunkSize: Int
    let captureCalls: Int
    let captureAfterNormalStateCommit = true
    let inputNormPath: String
    let inputNormEpsilon: Float
    let inputNormWeight: GDNProjectionTensorIdentity
    let normalizedInput: GDNProjectionValues
    let firstLogits: GDNProjectionValues
    let firstLogitArgmaxToken: Int
    let sourceProjections: [GDNProjectionSource]
    let sourceProjectionsSHA256: String
    let fusionEligibilityValidatedBeforeAndAfter = true
    let operatorEvidence = "reconstructed fused qkv,z,b,a operator on actual-forward captured normalized input"
    let rawValuesEncoding = "row-major Float32 numbers preserving original finite floating values; dtype/hash cover original logical bytes"
    let full: GDNProjectionEvaluation
    let ranks: [GDNProjectionEvaluation]
    let componentDifferences: [GDNProjectionDifference]
    let sourceSeams: [String]
    let limitations: [String]
}

/// Root admission/loading supplies an unpartitioned dense model and one bounded
/// chunk. The caller owns the MLX error scope, synchronization and native alarm.
func runQwenGDNInputProjectionCheck(loaded: LoadedModel, options: Options, prompt: [Int],
                                    check: () throws -> Void) throws {
    guard options.executionPath == .cbv2Contiguous,
          options.attentionOutputPrecision == .native, options.ffnOutputPrecision == .native,
          options.ffnBranchPrecision == .native, loaded.family == .qwen35,
          loaded.feedForwardKind == "dense", loaded.partitionPlan == nil, loaded.partitionStorage == nil,
          loaded.model is Qwen35TextModel || loaded.model is Qwen35Model,
          let mtp = loaded.model as? any MTPCapable, !mtp.hasMTPHead,
          (1...32).contains(prompt.count), options.promptCount == prompt.count,
          options.chunkSize >= prompt.count, options.chunkSize <= 32,
          options.decodeCount == 1, options.repeats == 1, options.warmups == 0,
          (4...262144).contains(loaded.vocabularySize),
          prompt.allSatisfy({ (0..<loaded.vocabularySize).contains($0) }),
          options.synthetic || loaded.verifiedDiagnosticLoad != nil else {
        throw ProbeError("GDN input check requires verified or synthetic dense solo Qwen, native CBv2, and one bounded chunk/output")
    }
    if let receipt = loaded.verifiedDiagnosticLoad {
        guard receipt.configurationSHA256 == loaded.configHash,
              receipt.parameterLayoutSHA256 == loaded.parameterLayoutSHA256,
              receipt.bf16ConversionEnabled == loaded.bf16ConversionEnabled else {
            throw ProbeError("GDN diagnostic model differs from its verified loading receipt")
        }
    }
    guard let root = try JSONSerialization.jsonObject(with: loaded.configurationData) as? [String: Any] else {
        throw ProbeError("GDN input check requires a configuration object")
    }
    let text = root["text_config"] as? [String: Any] ?? root
    let plan = try QwenGDNPartition(text: text)
    let fusedWidth = 2 * plan.keyWidth + 2 * plan.valueWidth + 2 * plan.valueHeads
    guard (1...8192).contains(plan.hiddenSize), (1...32768).contains(fusedWidth),
          try qwenPartitionInteger(text, "full_attention_interval") > 1 else {
        throw ProbeError("GDN input check exceeds its first-layer input/output width bounds")
    }
    // Inspect eligibility, then release these original references before native
    // fusion replaces the named projections with views of its fused allocation.
    func validateEligibility() throws { _ = try GDNProjectionInputs(loaded: loaded, plan: plan) }
    try validateEligibility()
    let capture = try captureQwenGDNNormalizedInput(loaded: loaded, prompt: prompt, check: check)
    guard capture.input.shape == [1, prompt.count, plan.hiddenSize],
          String(describing: capture.input.dtype) == loaded.embeddingActivationDType else {
        throw ProbeError("Captured GDN normalized input differs from the loaded activation geometry")
    }
    let normalized = try GDNProjectionValues(capture.input, maximumValues: 32 * 8192, check: check)
    let logits = try GDNProjectionValues(capture.logits, maximumValues: 262144, check: check)
    var argmax = 0
    for index in logits.values.indices.dropFirst() where logits.values[index] > logits.values[argmax] { argmax = index }
    let inputs = try GDNProjectionInputs(loaded: loaded, plan: plan)
    let sources = try inputs.sourceRecords(check: check)
    let full = try inputs.evaluate(input: capture.input, rank: nil, check: check)
    let ranks = try (0..<2).map { try inputs.evaluate(input: capture.input, rank: $0, check: check) }
    let differences = try ranks.flatMap { try compareGDNProjectionComponents(full: full, rank: $0) }
    let result = QwenGDNInputProjectionReport(
        timestampUTC: ISO8601DateFormatter().string(from: Date()), model: loaded.label,
        syntheticWeights: options.synthetic, syntheticProfile: options.synthetic ? options.syntheticProfile : "none",
        seed: options.seed, configurationSHA256: loaded.configHash,
        parameterLayoutSHA256: loaded.parameterLayoutSHA256, bf16ConversionEnabled: loaded.bf16ConversionEnabled,
        verifiedDiagnosticLoad: loaded.verifiedDiagnosticLoad,
        promptSHA256: sha256(try JSONEncoder().encode(prompt)), promptTokenIDs: prompt,
        chunkSize: options.chunkSize, captureCalls: capture.calls,
        inputNormPath: capture.normPath, inputNormEpsilon: capture.norm.eps,
        inputNormWeight: try GDNProjectionTensorIdentity(capture.norm.weight, check: check),
        normalizedInput: normalized, firstLogits: logits, firstLogitArgmaxToken: argmax,
        sourceProjections: sources, sourceProjectionsSHA256: sha256(try canonicalJSONData(sources)),
        full: full, ranks: ranks, componentDifferences: differences,
        sourceSeams: [
            "MLXNN/Normalization.swift: RMSNorm.callAsFunction",
            "MLXLLM/Models/Qwen35.swift: Qwen35DecoderLayer.cbv2Forward inputLayerNorm",
            "MLXLLM/Models/Qwen35.swift: prepareFusedInputProjection and projectInputs",
            "MLXNN/Quantized.swift: QuantizedLinear.callAsFunction",
            "Cmlx/mlx/mlx/backend/metal/quantized.cpp: QuantizedMatmul::eval_gpu and qmm_splitk",
        ], limitations: [
            "Only the normalized input is captured from the normal model; fused outputs are reconstructed afterward.",
            "The original GDN input Linear classes and normal fusion eligibility remain unchanged.",
            "Full input K and native activation precision are preserved; each rank selects matching semantic output rows.",
            "Raw CPU Float32 values preserve source floating values; no FP32 projection variant or dequantized oracle is used.",
            "First-logit values permit an external no-hook control; this run alone does not establish control parity.",
            "Numeric differences are measurements without a pass threshold, causal attribution, throughput or model-quality claim.",
        ])
    try check()
    try emitJSON(result)
}
