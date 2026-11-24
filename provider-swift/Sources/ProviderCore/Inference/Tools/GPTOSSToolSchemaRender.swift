// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer

/// GPT-OSS's Harmony template renders a tool schema as written: a `type` list
/// as `string | integer`, a `oneOf` as the union of its members and a node
/// without a type as `any`. The shared repair (`ToolSchemaNormalization`)
/// writes one type into each of those nodes, the first member's or `string`,
/// and the model then wrote strings for numbers, booleans and objects. GPT-OSS
/// renders each tool's parameters from the body's own declaration through the
/// repair without the types it invents (`repairedParameters`,
/// `writesRenderTypes` false). A tool that this leaves as the repair leaves it
/// renders as before, so a body whose tools arrive already repaired renders
/// unchanged.
enum GPTOSSToolSchemaRender {
    static func applies(modelId: String?, modelType: String?) -> Bool {
        GPTOSSHarmonyTemplateFix.applies(to: .init(modelId: modelId, modelType: modelType))
    }

    /// The tools GPT-OSS renders: `tools`, each tool whose declaration in
    /// `declared` (by name, the first of a repeated name) the repair's render
    /// types change with that declaration's parameters without them. Other
    /// families, and every tool without such a declaration, keep `tools`.
    static func renderedTools(
        _ tools: [OpenAITool]?, declared: [OpenAITool]?, modelId: String?, modelType: String?
    ) -> [OpenAITool]? {
        guard applies(modelId: modelId, modelType: modelType), let tools, let declared else { return tools }
        let byName = Dictionary(declared.map { ($0.function.name, $0) }, uniquingKeysWith: { first, _ in first })
        return tools.map { tool in
            guard let declaration = byName[tool.function.name],
                let parameters = parametersWithoutRenderTypes(declaration)
            else { return tool }
            var copy = tool
            copy.function.parameters = parameters
            return copy
        }
    }

    /// Whether `renderedTools` changes any of `tools`. Declared tools are a
    /// superset of the rendered ones (tool choice only narrows them), so
    /// passing the request's tools never misses a changed prompt.
    static func changesRender(
        _ tools: [OpenAITool]?, declared: [OpenAITool]?, modelId: String?, modelType: String?
    ) -> Bool {
        guard applies(modelId: modelId, modelType: modelType), let tools, let declared else { return false }
        let names = Set(tools.map(\.function.name))
        var seen: Set<String> = []
        return declared.contains { declaration in
            let name = declaration.function.name
            guard names.contains(name), seen.insert(name).inserted else { return false }
            return parametersWithoutRenderTypes(declaration) != nil
        }
    }

    /// `declaration`'s parameters through the repair without its render
    /// types, or nil when that equals the repair's own result (or either is
    /// out of the repair's bounds).
    static func parametersWithoutRenderTypes(_ declaration: OpenAITool) -> MLXLMCommon.JSONValue? {
        guard let repaired = repairedParameters(declaration, writesRenderTypes: true),
            let plain = repairedParameters(declaration, writesRenderTypes: false),
            plain != repaired
        else { return nil }
        return plain
    }

    /// The tools GPT-OSS's served prompt shows for `declared` when nothing
    /// repaired them yet (the template utility): each tool's parameters
    /// through the repair without its render types, which equals the
    /// repair's own result wherever the served prompt keeps it. Other
    /// families keep `declared`.
    static func servedTools(_ declared: [OpenAITool]?, modelId: String?, modelType: String?) -> [OpenAITool]? {
        guard applies(modelId: modelId, modelType: modelType), let declared else { return declared }
        return declared.map { tool in
            guard let parameters = repairedParameters(tool, writesRenderTypes: false) else { return tool }
            var copy = tool
            copy.function.parameters = parameters
            return copy
        }
    }

    private static func repairedParameters(_ declaration: OpenAITool, writesRenderTypes: Bool)
        -> MLXLMCommon.JSONValue?
    {
        guard let parameters = declaration.function.parameters,
            let data = try? JSONEncoder().encode([parameters]),
            data.count <= ToolSchemaNormalization.maxNormalizationBytes,
            let node = (try? JSONSerialization.jsonObject(with: data)) as? [Any], let root = node.first
        else { return nil }
        var budget = ToolSchemaNormalization.maxNormalizedNodes
        return ToolSchemaNormalization.repairedParameters(
            root, writesRenderTypes: writesRenderTypes, budget: &budget).flatMap(jsonValue)
    }

    private static func jsonValue(_ node: Any) -> MLXLMCommon.JSONValue? {
        guard let data = try? JSONSerialization.data(withJSONObject: [node]) else { return nil }
        return (try? JSONDecoder().decode([MLXLMCommon.JSONValue].self, from: data))?.first
    }
}
