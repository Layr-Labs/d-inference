import Foundation
import MLXLMCommon

/// Benchmark-only metadata from the already-normalized message structure.
/// It does not classify untrusted token strings as message boundaries.
enum BenchmarkInstructionPrefix {
    static func count(
        input: ProviderPromptContractPipeline.NormalizedInput,
        fullTokens: [Int], tokenizer: any MLXLMCommon.Tokenizer, modelType: String?
    ) -> Int? {
        guard modelType == "gpt_oss",
              let firstUser = input.messages.firstIndex(where: { $0["role"] as? String == "user" })
        else { return nil }
        var messages = Array(input.messages.prefix(firstUser + 1))
        // Render the actual system/developer/tool header followed by an empty
        // first user. The last user marker is therefore a structural boundary,
        // even when an earlier tool description contains the same token text.
        messages[firstUser]["content"] = ""
        guard let header = try? tokenizer.applyChatTemplate(
            messages: messages, tools: input.tools, additionalContext: input.additionalContext)
        else { return nil }
        let marker = tokenizer.encode(text: "<|start|>user<|message|>", addSpecialTokens: false)
        return verifiedBoundary(fullTokens: fullTokens, emptyUserTokens: header, userMarker: marker)
    }

    static func verifiedBoundary(
        fullTokens: [Int], emptyUserTokens: [Int], userMarker: [Int]
    ) -> Int? {
        guard !userMarker.isEmpty, emptyUserTokens.count >= userMarker.count else { return nil }
        for start in stride(from: emptyUserTokens.count - userMarker.count, through: 0, by: -1) {
            guard emptyUserTokens[start..<(start + userMarker.count)].elementsEqual(userMarker) else { continue }
            let end = start + userMarker.count
            guard fullTokens.count >= end,
                  fullTokens.prefix(end).elementsEqual(emptyUserTokens.prefix(end)) else { return nil }
            return end
        }
        return nil
    }
}
