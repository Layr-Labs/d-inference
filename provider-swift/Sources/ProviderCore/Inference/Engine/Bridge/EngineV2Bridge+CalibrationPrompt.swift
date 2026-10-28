import Foundation

extension EngineV2Bridge {
    /// Built-in realistic prose/code, never a retained customer's prompt. Full
    /// templates are rendered at every size; token arrays are not truncated.
    func modelCalibrationPrompt(targetTokens: Int, variant: Int) throws -> [Int] {
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
        // Each repetition adds an almost constant count. Probing 1 and 2, then
        // the slope's estimate and its successor, sizes a warmup prompt in five
        // renders on this actor instead of ~10; every probe narrows the bounds.
        var planned = [1, 2]
        var oneRepetition: Int?
        while low <= high {
            var middle = low + (high - low) / 2
            if !planned.isEmpty { middle = min(max(planned.removeFirst(), low), high) }
            let tokens = try render(middle)
            if tokens.count <= targetTokens { result = tokens; low = middle + 1 }
            else { high = middle - 1 }
            if middle == 1 { oneRepetition = tokens.count }
            if middle == 2, let one = oneRepetition, tokens.count > one, tokens.count <= targetTokens {
                let estimate = 2 + (targetTokens - tokens.count) / (tokens.count - one)
                planned = [estimate, estimate + 1]
            }
        }
        return result
    }
}
