import Foundation

extension EngineV2Bridge {
    /// Built-in realistic prose/code, never a retained customer's prompt. Full
    /// templates are rendered at every size; token arrays are not truncated.
    func mimoCalibrationPrompt(targetTokens: Int, variant: Int) throws -> [Int] {
        let passage = variant.isMultiple(of: 2)
            ? "A small team maintains an inference service. Incoming requests vary in length, and machines share memory between model weights and cached attention state. The team measures latency and throughput before changing how requests are assigned. Explain the tradeoffs with concrete examples. "
            : "Review this Python function and explain its behavior, complexity, and edge cases: def merge_sorted(a, b): result = []; i = j = 0; while i < len(a) and j < len(b): if a[i] <= b[j]: result.append(a[i]); i += 1; else: result.append(b[j]); j += 1; return result + a[i:] + b[j:]. Suggest a readable correction. "
        func render(_ repetitions: Int) throws -> [Int] {
            try tokenizer.inner.applyChatTemplate(messages: [["role": "user",
                "content": "Calibration example \(variant). " + String(repeating: passage, count: repetitions)
                    + "\nGive a detailed answer."]], tools: nil,
                additionalContext: ["enable_thinking": false])
        }
        var low = 0, high = max(1, targetTokens / 8)
        var result = try render(0)
        guard result.count <= targetTokens else { throw InferenceError.generationFailed("calibration template exceeds cell") }
        while low <= high {
            let middle = low + (high - low) / 2
            let tokens = try render(middle)
            if tokens.count <= targetTokens { result = tokens; low = middle + 1 }
            else { high = middle - 1 }
        }
        return result
    }
}
