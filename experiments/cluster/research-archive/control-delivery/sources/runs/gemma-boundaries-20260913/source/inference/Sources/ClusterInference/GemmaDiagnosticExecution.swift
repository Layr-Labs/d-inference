import MLX
import MLXLMCommon

func evaluateGemmaDiagnostic(_ output: LMOutput, trace: GemmaBoundaryTrace?) throws {
    // Complete every branch in the current forward before inspecting captures.
    // Cache-only prepare deliberately prunes work and is unsafe for this trace.
    eval([output.logits] + (trace?.pendingArrays ?? []))
    try trace?.drain()
}

func gemmaDiagnosticPrefill(loaded: LoadedModel, prompt: [Int], cache: [KVCache],
                             chunkSize: Int) throws -> LMOutput {
    guard loaded.family == .gemma4, !prompt.isEmpty, prompt.count <= 128 else {
        throw ProbeError("Gemma diagnostic prefill requires a bounded Gemma prompt")
    }
    var final: LMOutput?
    var state: LMOutput.State?
    for start in stride(from: 0, to: prompt.count, by: chunkSize) {
        let chunk = Array(prompt[start..<min(start + chunkSize, prompt.count)])
        let input = LMInput.Text(tokens: MLXArray(chunk).reshaped(1, chunk.count))
        let output = loaded.model(input, cache: cache, state: state)
        try evaluateGemmaDiagnostic(output, trace: loaded.gemmaTrace)
        state = output.state; final = output
    }
    return final!
}
