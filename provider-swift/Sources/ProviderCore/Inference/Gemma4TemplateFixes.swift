// Copyright © 2026 Eigen Labs.
//
// Gemma 4 uses the upstream/MLX chat template directly (byte-identical to
// mlx-community/gemma-4-26b-a4b-it-qat-4bit, sha 94899c0f…). That template has
// request-shape landmines the fixes here defuse in code — the artifact is NOT
// repinned (2026-07-15 platform errors deep dive, E1/E2/E3):
//
//   • `format_parameters` renders `{{ value['type'] | upper }}` over every
//     tool property → `normalizeTools` enforces "every property value is a
//     mapping with a String type" (Gemma4ToolSchemaEnforcement).
//   • the tool-response forward scan only reads the CONTIGUOUS run after an
//     assistant tool_calls message, and consecutive assistant text turns
//     close/continue incorrectly → `normalizeMessages` re-pairs results,
//     rejects orphans as 400, and merges dangling assistant text
//     (Gemma4TurnStructure).
//
// Mirrors the per-model hook pattern of `GPTOSSHarmonyTemplateFix`.

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
        try Gemma4TurnStructure.normalizeMessages(messages)
    }

    static func normalizeTools(
        _ tools: [[String: any Sendable]]
    ) -> [[String: any Sendable]] {
        Gemma4ToolSchemaEnforcement.normalizeToolSpecs(tools)
    }

    static func extraEOSTokenIds(tokenToId: (String) -> Int?) -> Set<Int> {
        []
    }
}
