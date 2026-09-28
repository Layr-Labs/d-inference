import MLX
import MLXLLM
import MLXNN

/// Kept outside Module reflection: a recorded activation is not a parameter.
private final class GDNNormalizedCaptureBox {
    var calls = 0
    var value: MLXArray?
}

private final class GDNInputNormCapture: RMSNorm {
    private let capture: GDNNormalizedCaptureBox

    init(source: RMSNorm, capture: GDNNormalizedCaptureBox) throws {
        self.capture = capture
        super.init(dimensions: source.weight.size, eps: source.eps)
        try update(parameters: source.parameters(), verify: [.all])
        freeze()
    }

    override func callAsFunction(_ input: MLXArray) -> MLXArray {
        let normalized = super.callAsFunction(input)
        capture.calls += 1
        if capture.calls == 1 { capture.value = normalized }
        // No evaluation, conversion or additional arithmetic inside the hook.
        return normalized
    }
}

struct GDNNormalizedInputCapture {
    let input: MLXArray
    let logits: MLXArray
    let norm: RMSNorm
    let normPath: String
    let calls: Int
}

/// One normal noncaptured CBv2 forward; only the first input norm is observed.
/// All request roots are evaluated and committed before inspecting the capture.
func captureQwenGDNNormalizedInput(loaded: LoadedModel, prompt: [Int],
                                   check: () throws -> Void) throws -> GDNNormalizedInputCapture {
    let prefix = loaded.model is Qwen35Model ? "language_model." : ""
    let parentPath = prefix + "model.layers.0"
    let normPath = parentPath + ".input_layernorm"
    let (parent, norm): (Module, RMSNorm) = try {
        // Drop the complete module inventory before native fusion replaces its
        // input projections; retaining it would retain all original weight banks.
        let modules = Dictionary(uniqueKeysWithValues: loaded.model.namedModules())
        guard let parent = modules[parentPath], let norm = modules[normPath] as? RMSNorm,
              ObjectIdentifier(type(of: norm)) == ObjectIdentifier(RMSNorm.self),
              norm.weight.ndim == 1, norm.weight.size > 0,
              norm.eps.isFinite, norm.eps > 0,
              modelParameterLayout(loaded.model) == loaded.parameterLayoutSHA256 else {
            throw ProbeError("GDN input capture requires the original first-layer RMSNorm and model layout")
        }
        return (parent, norm)
    }()
    let box = GDNNormalizedCaptureBox()
    let hook = try GDNInputNormCapture(source: norm, capture: box)
    try parent.update(modules: ModuleChildren(values: ["input_layernorm": .value(hook)]),
                      verify: [.noUnusedKeys])
    var restored = false
    defer {
        if !restored {
            try? parent.update(modules: ModuleChildren(values: ["input_layernorm": .value(norm)]),
                               verify: [.noUnusedKeys])
        }
    }
    guard modelParameterLayout(loaded.model) == loaded.parameterLayoutSHA256,
          loaded.model.trainableParameters().flattened().isEmpty else {
        throw ProbeError("GDN input capture changed parameter layout or frozen eligibility")
    }
    let session = try CBv2RequestSession(loaded: loaded, promptCount: prompt.count, outputCount: 1)
    defer { try? session.close() }
    let logits = try session.prefillChunk(prompt, final: true, check: check)
    guard session.committedTokens == prompt.count,
          session.committedPromptTokens == prompt.count, session.decodeForwardCount == 0 else {
        throw ProbeError("GDN input capture did not commit its exact prompt frontier")
    }
    try session.close()
    try check()
    guard session.isClosed, !session.isFailed, box.calls == 1, let input = box.value,
          input.shape == [1, prompt.count, norm.weight.size],
          logits.shape == [1, loaded.vocabularySize] else {
        throw ProbeError("GDN input capture has an invalid call count, shape or request lifecycle")
    }
    // This is intentionally after all normal CBv2 output/cache/recurrent roots,
    // state commit and cleanup. The hook itself retained only an unevaluated handle.
    eval(input)
    try check()
    try parent.update(modules: ModuleChildren(values: ["input_layernorm": .value(norm)]),
                      verify: [.noUnusedKeys])
    restored = true
    guard modelParameterLayout(loaded.model) == loaded.parameterLayoutSHA256 else {
        throw ProbeError("GDN input capture did not restore the original parameter layout")
    }
    return GDNNormalizedInputCapture(input: input, logits: logits, norm: norm, normPath: normPath, calls: box.calls)
}
