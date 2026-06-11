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

        // A type that is PRESENT but not a string crashes `| upper` just like a
        // missing one. The common real-world shape is the JSON-Schema array form
        // for nullable fields — `"type": ["string","null"]` — which Pydantic
        // emits for every Optional[...] tool parameter. Collapse it to a single
        // representative string (never delete the key: a node whose only content
        // is its type would not be refilled below and would crash anyway).
        // Nullability is preserved losslessly: the gemma template natively
        // renders the standard `nullable` key, so collapsing away a "null"
        // member sets it (without clobbering an explicit value).
        if let t = dict["type"], !(t is String) {
            let members = (t as? [Any])?.compactMap { $0 as? String } ?? []
            if members.contains("null"), members.contains(where: { $0 != "null" }),
                dict["nullable"] == nil {
                dict["nullable"] = true
            }
            dict["type"] = collapsedType(members: members, in: dict)
        }

        let looksLikeSchemaNode =
            dict["properties"] != nil || dict["items"] != nil ||
            dict["additionalProperties"] != nil ||
            dict["enum"] != nil || dict["description"] != nil ||
            dict["anyOf"] != nil || dict["oneOf"] != nil || dict["allOf"] != nil
        if dict["type"] == nil, looksLikeSchemaNode {
            dict["type"] = inferredType(for: dict)
        }
        return dict
    }

    /// Collapse a non-string `type` value (pre-extracted string members of the
    /// array form) to one renderable string: the first concrete (non-"null")
    /// member, the lone "null" when that is all the array declares, else fall
    /// back to structural inference.
    private static func collapsedType(members: [String], in dict: [String: Any]) -> String {
        if let concrete = members.first(where: { $0 != "null" }) {
            return concrete
        }
        if let nullOnly = members.first {
            return nullOnly
        }
        return inferredType(for: dict)
    }

    /// Structural default for a schema node's `type`: object when it has
    /// properties, array when it has items, a union member's type when it is an
    /// anyOf/oneOf/allOf (skipping "null" — mislabelling a union as a string
    /// would be wrong), otherwise string.
    private static func inferredType(for dict: [String: Any]) -> String {
        if dict["properties"] != nil || dict["additionalProperties"] != nil {
            return "object"
        }
        if dict["items"] != nil {
            return "array"
        }
        if let unionType = unionMemberType(dict) {
            return unionType
        }
        return "string"
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
