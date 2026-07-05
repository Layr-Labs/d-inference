// Copyright © 2026 Eigen Labs.
//
// DeepSeek-V4 has no Jinja chat template at all (unlike the GPT-OSS/Gemma4
// fixes in this directory, which patch an existing template's quirks). This
// hook instead tells the tokenization seam to bypass
// `Tokenizer.applyChatTemplate` entirely and render the prompt with the
// native `DeepseekV4Encoding` port (`ProviderCoreFoundation`). See
// `MultiModelBatchSchedulerEngine`'s `streamChatCompletion`/`applyTemplate`
// and `BatchScheduler.submit(request:)` for the call sites.

enum DeepseekV4TemplateFix {
    static func applies(to context: ChatTemplateFixContext) -> Bool {
        isDeepseekV4Hint(context.modelType) || isDeepseekV4Hint(context.modelId)
    }

    private static func isDeepseekV4Hint(_ value: String?) -> Bool {
        guard let value else { return false }
        let normalized = value.lowercased().replacingOccurrences(of: "-", with: "_")
        return normalized.contains("deepseek_v4")
    }
}
