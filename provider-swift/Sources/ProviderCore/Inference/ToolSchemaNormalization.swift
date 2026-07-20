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
    static let originalBooleanSchemaKey =
        "x-darkbloom-original-boolean-schema"
    static let metadataProtocolVersion = 1

    static func containsReservedMetadata(in data: Data) -> Bool {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let tools = root["tools"] as? [Any]
        else {
            return false
        }
        return tools.contains { tool in
            guard let tool = tool as? [String: Any],
                let function = tool["function"] as? [String: Any],
                let parameters = function["parameters"]
            else {
                return false
            }
            return schemaContainsReservedMetadata(parameters)
        }
    }

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

    /// Recursively default-fill `type` on JSON-Schema nodes, starting from a
    /// tool's schema home (a NON-positional root: a bare `{}` parameters object
    /// stays `{}`, and a type is only invented when the map carries a schema
    /// marker key). The inferred default favours structure: object when it has
    /// properties, array when it has items, otherwise string.
    ///
    /// Semantically mirrors the coordinator's Go `injectDefaultTypes`
    /// (`coordinator/api/toolschema.go`) including its POSITIONAL rule: any
    /// value in a schema-positional slot — under `properties` /
    /// `patternProperties`, `items` (including tuple-form members),
    /// `prefixItems`, a map-valued `additionalProperties`, or a member of
    /// `anyOf`/`oneOf`/`allOf` — IS a schema by definition, so it needs no
    /// marker-key evidence: booleans (the valid allow/deny-all shorthand)
    /// become render-safe string schemas carrying their original semantic
    /// value, and maps are guaranteed a string `type`.
    static func injectDefaultTypes(_ node: Any) -> Any {
        injectTypes(node, positional: false)
    }

    /// Traversal core behind ``injectDefaultTypes(_:)``; `positional` reports
    /// whether `node` sits in a schema-positional slot (see the mirror note
    /// above). Arrays keep positionality for their members (tuple-form
    /// `items`, `prefixItems`, union member lists).
    private static func injectTypes(_ node: Any, positional: Bool) -> Any {
        if positional, isJSONBoolean(node) {
            return [
                "type": "string",
                originalBooleanSchemaKey: node,
            ] as [String: Any]
        }
        if let arr = node as? [Any] {
            return arr.map { injectTypes($0, positional: positional) }
        }
        guard var dict = node as? [String: Any] else { return node }

        for key in ["properties", "patternProperties"] {
            if let props = dict[key] as? [String: Any] {
                dict[key] = props.mapValues { injectTypes($0, positional: true) }
            }
        }
        if let items = dict["items"] {
            dict["items"] = injectTypes(items, positional: true)
        }
        if let prefix = dict["prefixItems"] as? [Any] {
            dict["prefixItems"] = prefix.map { injectTypes($0, positional: true) }
        }
        // additionalProperties may itself be a schema (map-shaped params, e.g.
        // {"additionalProperties":{"type":"string"}}) — recurse so its inner schema
        // gets a default type too. A bare `true`/`false` is left untouched (the
        // standard allow/deny-all switch; templates never subscript it) — only
        // the MAP-valued form is schema-positional.
        if let addl = dict["additionalProperties"], addl is [String: Any] {
            dict["additionalProperties"] = injectTypes(addl, positional: true)
        }
        for key in ["anyOf", "oneOf", "allOf"] {
            if let variants = dict[key] as? [Any] {
                dict[key] = variants.map { injectTypes($0, positional: true) }
            }
        }
        if dict["type"] == nil,
            nullableCombinatorUnion(dict),
            dict["nullable"] as? Bool != true
        {
            dict["nullable"] = true
        }

        // A type that is PRESENT but not a string crashes `| upper` just like a
        // missing one. The common real-world shape is the JSON-Schema array form
        // for nullable fields — `"type": ["string","null"]` — which Pydantic
        // emits for every Optional[...] tool parameter. Collapse it to a single
        // representative string (never delete the key: a node whose only content
        // is its type would not be refilled below and would crash anyway). A
        // scalar non-string `type` (e.g. `"type": 123`) collapses the same way,
        // to the structural inference. Nullability is preserved losslessly: the
        // gemma template natively renders the standard `nullable` key, so
        // collapsing away a "null" member sets it to true. An explicit false
        // cannot override the union's null member without changing semantics.
        if let t = dict["type"], !(t is String) {
            let members =
                (t as? [Any])?.compactMap { ($0 as? String)?.lowercased() } ?? []
            if members.contains("null"), members.contains(where: { $0 != "null" }),
                dict["nullable"] as? Bool != true {
                dict["nullable"] = true
            }
            dict["type"] = collapsedType(members: members, in: dict)
        }

        // A positional node IS a schema by definition, so a missing type is
        // always filled; a non-positional map (a tool schema root) still needs
        // marker-key evidence before we invent one.
        if dict["type"] == nil, positional || looksLikeSchemaNode(dict) {
            dict["type"] = inferredType(for: dict)
        }

        // An OBJECT-typed schema node must carry a mapping `properties` —
        // otherwise the served Gemma template's OBJECT branch falls back to
        // iterating the node's OWN keys (`filter_keys=true`) as property
        // schemas; containers like `patternProperties` carry no `type`, so
        // `value['type'] | upper` throws. Mirrors coordinator toolschema.go
        // and gemma4 enforcement invariant 4; runs AFTER type resolution so
        // inferred-object nodes are covered, and is render-neutral elsewhere
        // (an empty dict is falsy in Jinja truthiness guards).
        if let t = dict["type"] as? String, t.uppercased() == "OBJECT",
            !(dict["properties"] is [String: Any]) {
            dict["properties"] = [String: Any]()
        }
        return dict
    }

    private static func schemaContainsReservedMetadata(_ node: Any) -> Bool {
        if let array = node as? [Any] {
            return array.contains(where: schemaContainsReservedMetadata)
        }
        guard let object = node as? [String: Any] else { return false }
        if object[originalBooleanSchemaKey] != nil { return true }
        for key in [
            "additionalProperties", "additionalItems", "contains", "contentSchema",
            "if", "then", "else", "not", "propertyNames",
            "unevaluatedItems", "unevaluatedProperties", "items",
        ] {
            if let child = object[key], schemaContainsReservedMetadata(child) {
                return true
            }
        }
        for key in ["allOf", "anyOf", "oneOf", "prefixItems"] {
            if let children = object[key] as? [Any],
                children.contains(where: schemaContainsReservedMetadata)
            {
                return true
            }
        }
        for key in [
            "properties", "patternProperties", "dependentSchemas",
            "dependencies", "definitions", "$defs",
        ] {
            if let children = object[key] as? [String: Any],
                children.values.contains(where: schemaContainsReservedMetadata)
            {
                return true
            }
        }
        return false
    }

    /// Marker-key evidence gate for NON-positional nodes (the tool schema
    /// roots): only maps carrying a JSON-Schema marker key receive a defaulted
    /// `type` there.
    private static func looksLikeSchemaNode(_ dict: [String: Any]) -> Bool {
        for key in [
            "properties", "patternProperties", "items", "prefixItems",
            "additionalProperties", "enum", "description", "anyOf", "oneOf", "allOf",
        ] where dict[key] != nil {
            return true
        }
        return false
    }

    /// True only for a REAL boolean. JSONSerialization delivers JSON booleans
    /// as `NSNumber` (CFBoolean), and `as? Bool` alone would also match numeric
    /// 0/1 NSNumbers — a schema value of `0`/`1` must NOT be mistaken for a
    /// boolean schema, so the underlying CF type is checked.
    private static func isJSONBoolean(_ node: Any) -> Bool {
        if type(of: node) == Bool.self { return true }
        guard let number = node as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func nullableCombinatorUnion(
        _ dict: [String: Any]
    ) -> Bool {
        for key in ["anyOf", "oneOf"] {
            guard let variants = dict[key] as? [[String: Any]] else { continue }
            var hasNull = false
            var hasConcrete = false
            for variant in variants {
                hasNull = hasNull || variant["nullable"] as? Bool == true
                let members: [String]
                if let type = variant["type"] as? String {
                    members = [type.lowercased()]
                } else {
                    members =
                        (variant["type"] as? [Any])?
                        .compactMap { ($0 as? String)?.lowercased() } ?? []
                }
                hasNull = hasNull || members.contains("null")
                hasConcrete = hasConcrete || members.contains(where: { $0 != "null" })
            }
            if hasNull && hasConcrete { return true }
        }
        return false
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
    /// properties / patternProperties / additionalProperties, array when it has
    /// items / prefixItems, a union member's type when it is an
    /// anyOf/oneOf/allOf (skipping "null" — mislabelling a union as a string
    /// would be wrong), otherwise string.
    private static func inferredType(for dict: [String: Any]) -> String {
        if dict["properties"] != nil || dict["patternProperties"] != nil
            || dict["additionalProperties"] != nil {
            return "object"
        }
        if dict["items"] != nil || dict["prefixItems"] != nil {
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
