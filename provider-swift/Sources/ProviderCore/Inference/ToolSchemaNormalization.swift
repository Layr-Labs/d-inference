import Foundation

/// Defends Gemma-style chat templates that render `{{ value['type'] | upper }}`
/// over each tool parameter against schemas that omit an explicit `type` — a
/// legitimate OpenAI shape (e.g. an `enum`-only or `anyOf` property). Without a
/// `type`, the Jinja `| upper` filter operates on an undefined value and the
/// render throws, surfacing to the consumer as a 500 (DAR-130). We inject a
/// default `type` into every JSON-Schema node under each tool's
/// `function.parameters` before the request is decoded, so the template always
/// has a string to upper-case.
///
/// This is pure Foundation JSON surgery applied at the single inbound decode
/// boundary (`ProviderLoop.decodeOpenAIRequest`): the chat-template code in
/// mlx-swift-lm is left untouched, and non-tool requests pay zero cost (the work
/// is gated on the body actually carrying `tools`).
enum ToolSchemaNormalization {
    /// Return `data` with default `type`s injected into tool parameter schemas.
    /// Fast-paths out (returns the input unchanged) when the body carries no
    /// `tools`, or when it isn't a JSON object we can repair.
    /// Upper bound on the body we'll JSON round-trip for tool-schema normalization.
    /// Tool definitions are tiny (KB), so a multi-MB body — e.g. a long prompt that
    /// merely contains the word "tools" — should not trigger a full parse + recursive
    /// traversal. Above this we skip normalization, bounding the cost on the
    /// (already size-capped) inference path.
    static let maxNormalizationBytes = 4 * 1024 * 1024

    static func ensureParameterTypes(in data: Data) -> Data {
        // Bound the work: skip the round-trip for oversized bodies (see the constant).
        guard data.count <= maxNormalizationBytes else { return data }
        // Cheap gate: only pay the JSON round-trip for requests that carry tools.
        guard data.range(of: Data("\"tools\"".utf8)) != nil else { return data }
        guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tools = root["tools"] as? [Any]
        else {
            return data
        }
        let normalizedTools: [Any] = tools.map { tool in
            guard var toolDict = tool as? [String: Any],
                  var function = toolDict["function"] as? [String: Any],
                  let parameters = function["parameters"]
            else { return tool }
            function["parameters"] = injectDefaultTypes(parameters)
            toolDict["function"] = function
            return toolDict
        }
        root["tools"] = normalizedTools
        guard let out = try? JSONSerialization.data(withJSONObject: root) else { return data }
        return out
    }

    /// Recursively default-fill `type` on JSON-Schema nodes. A node gets a type
    /// only when it looks like a schema node (has properties / items / enum /
    /// description / anyOf / oneOf / allOf) — we never invent types on arbitrary
    /// maps. The inferred default favours structure: object when it has
    /// properties, array when it has items, otherwise string.
    static func injectDefaultTypes(_ node: Any) -> Any {
        if let arr = node as? [Any] {
            return arr.map(injectDefaultTypes)
        }
        guard var dict = node as? [String: Any] else { return node }

        if let props = dict["properties"] as? [String: Any] {
            dict["properties"] = props.mapValues(injectDefaultTypes)
        }
        if let items = dict["items"] {
            dict["items"] = injectDefaultTypes(items)
        }
        // additionalProperties may itself be a schema (map-shaped params, e.g.
        // {"additionalProperties":{"type":"string"}}) — recurse so its inner schema
        // gets a default type too. A bare `true`/`false` is left untouched.
        if let addl = dict["additionalProperties"], addl is [String: Any] {
            dict["additionalProperties"] = injectDefaultTypes(addl)
        }
        for key in ["anyOf", "oneOf", "allOf"] {
            if let variants = dict[key] as? [Any] {
                dict[key] = variants.map(injectDefaultTypes)
            }
        }

        let looksLikeSchemaNode =
            dict["properties"] != nil || dict["items"] != nil ||
            dict["additionalProperties"] != nil ||
            dict["enum"] != nil || dict["description"] != nil ||
            dict["anyOf"] != nil || dict["oneOf"] != nil || dict["allOf"] != nil
        if dict["type"] == nil, looksLikeSchemaNode {
            if dict["properties"] != nil || dict["additionalProperties"] != nil {
                dict["type"] = "object"
            } else if dict["items"] != nil {
                dict["type"] = "array"
            } else if let unionType = unionMemberType(dict) {
                // anyOf/oneOf/allOf without a parent type: borrow the first concrete
                // member type (skipping "null") rather than mislabelling a union as a
                // string. The template still gets a usable type and can't crash.
                dict["type"] = unionType
            } else {
                dict["type"] = "string"
            }
        }
        return dict
    }

    /// Derive a representative `type` for a union node from the first member that
    /// declares a concrete, non-"null" type. Returns nil when none is found.
    private static func unionMemberType(_ dict: [String: Any]) -> String? {
        for key in ["anyOf", "oneOf", "allOf"] {
            guard let variants = dict[key] as? [Any] else { continue }
            for variant in variants {
                if let v = variant as? [String: Any],
                    let t = v["type"] as? String, t != "null" {
                    return t
                }
            }
        }
        return nil
    }
}
