// Copyright © 2026 Eigen Labs.
//
// Gemma 4 currently uses the upstream/MLX template directly. Keep this explicit
// no-op hook so future Gemma-specific template fixes stay separate from GPT-OSS.

enum Gemma4TemplateFix {
    static func applies(to context: ChatTemplateFixContext) -> Bool {
        guard let modelType = context.modelType?.lowercased() else {
            return context.modelId?.lowercased().contains("gemma-4") == true
        }
        return modelType.hasPrefix("gemma4")
    }

    static func normalizeMessages(
        _ messages: [[String: any Sendable]]
    ) throws -> [[String: any Sendable]] {
        messages
    }

    static func normalizeTools(
        _ tools: [[String: any Sendable]]
    ) -> [[String: any Sendable]] {
        tools
    }

    static func extraEOSTokenIds(tokenToId: (String) -> Int?) -> Set<Int> {
        []
    }
}
