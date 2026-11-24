// Copyright © 2026 Eigen Labs.
//
// Gemma4-specific tool-spec enforcement (E1 last line of defense, 2026-07-15
// platform errors deep dive). The served Gemma template's
// `format_parameters` macro renders `{{ value['type'] | upper }}` (and
// subscripts `value['description']` / `value['items']` / …) over EVERY
// property value it iterates, and `format_function_declaration` only closes
// its `parameters:{` block inside the `params['type']` branch. The shared
// normalizers (`ToolSchemaNormalization` here; `NormalizeToolSchemas` on the
// coordinator) repair schemas exhaustively, but this walk is the FINAL
// invariant for gemma4 even when a caller bypasses them:
//
//   1. `function.parameters`, when present, is a mapping — a non-mapping (or
//      an empty one) is dropped so the template's `{%- if params -%}` guard
//      skips the block instead of opening an unclosable `parameters:{`.
//   2. Every property value is a MAPPING with a String `type` (scalars that
//      the shared normalizer deliberately leaves — e.g. `"x": 5` — become
//      `{"type":"string"}`; a bool is already rewritten by the shared pass).
//   3. A non-empty parameters root carries a String `type` (the macro renders
//      `params['type'] | upper` and the closing brace lives in that branch).
//   4. An OBJECT-typed node without a mapping `properties` gains
//      `properties: {}` — otherwise the template's
//      `{%- elif value is mapping -%}` fallback iterates the node's OWN
//      non-standard keys as if they were property schemas (the
//      `filter_keys=true` branch), subscripting arbitrary junk.
//   5. `required` members are coerced to strings (scalars stringified,
//      composites dropped); a non-array `required` is removed.
//   6. `description` values the template interpolates are coerced to strings.
//   7. A property the shared normalizer typed `string` only because a union of
//      `string` and exactly one other scalar type (integer, number, boolean)
//      put `string` first renders as that other type: the template prints the
//      single render type and never the union, and STRING made the model quote
//      typed values ("-4200" for -4200). The union stays on the wire, so
//      validation still accepts both branches.
//   8. A property the caller declared without a type or any other schema
//      keyword (`{}`: any value) renders an empty type instead of the
//      `string` the shared normalizer injected, as the served template renders
//      a typeless property (`type:<|"|><|"|>`). The same holds behind a local
//      `$ref`, for an `anyOf`/`oneOf`/`allOf` whose non-null members all accept
//      any value, and for a typeless `enum` whose values have more than one
//      JSON type (the template prints an enum only under STRING, which quoted
//      its numbers). A tuple (`prefixItems` with `items` false or absent)
//      renders no `items` block, as the template renders one without a
//      mapping `items`, instead of the repair's STRING items. This needs the
//      declarations as sent; without them the repair's render stays.
//
// Mirrors the per-model precedent of `GPTOSSHarmonyTemplateFix.normalizeTools`.

import Foundation

enum Gemma4ToolSchemaEnforcement {

    static func normalizeToolSpecs(
        _ tools: [[String: any Sendable]],
        declared: [[String: any Sendable]]? = nil
    ) -> [[String: any Sendable]] {
        normalizeToolSpecsReportingRenderType(tools, declared: declared).tools
    }

    /// `normalizeToolSpecs`, also reporting whether invariant 7 or 8 changed
    /// any property's render type (the prompt then differs from one rendered
    /// without them). `declared` are the caller's tool specs as sent, before
    /// the shared normalizer; invariant 8 reads them.
    static func normalizeToolSpecsReportingRenderType(
        _ tools: [[String: any Sendable]],
        declared: [[String: any Sendable]]? = nil
    ) -> (tools: [[String: any Sendable]], changedRenderType: Bool) {
        // The inbound pass's node budget, so a request it left as sent is not
        // rewritten here instead.
        var budget = ToolSchemaNormalization.maxNormalizedNodes
        var changed = false
        var declaredParameters: [String: [String: any Sendable]] = [:]
        for tool in declared ?? [] {
            guard let function = tool["function"] as? [String: any Sendable],
                let name = function["name"] as? String,
                let parameters = function["parameters"] as? [String: any Sendable]
            else { continue }
            declaredParameters[name] = parameters
        }
        let normalized = tools.map { tool -> [String: any Sendable] in
            var output = normalizeToolSpec(tool, budget: &budget, changedUnionType: &changed)
            guard var function = output["function"] as? [String: any Sendable],
                let name = function["name"] as? String,
                let parameters = function["parameters"] as? [String: any Sendable],
                let declaredRoot = declaredParameters[name]
            else { return output }
            function["parameters"] = renderingDeclaredTypeless(
                parameters, declared: declaredRoot, root: declaredRoot, changed: &changed)
            output["function"] = function
            return output
        }
        return (normalized, changed)
    }

    /// Keywords that make a declared schema node typed or structured; a node
    /// with none of them accepts any value.
    private static let schemaKeywords = [
        "type", "properties", "patternProperties", "additionalProperties", "items", "prefixItems",
        "anyOf", "oneOf", "allOf", "not", "enum", "const", "$ref",
    ]

    /// Invariant 8: whether a declared property accepts any value (a mapping
    /// with no schema keyword, such as `{}` or one with only a description).
    static func declaresAnyValue(_ declared: Any?) -> Bool {
        guard let mapping = declared as? [String: Any] else { return false }
        return !schemaKeywords.contains { mapping[$0] != nil }
    }

    /// The node a declaration that is only a local `$ref` (plus annotations)
    /// points to in `root`'s `$defs` or `definitions`, followed up to eight
    /// hops; any other declaration is returned as is.
    static func resolvingLocalReference(_ declared: Any?, root: [String: Any]) -> Any? {
        var current = declared
        for _ in 0..<8 {
            guard let mapping = current as? [String: Any], let reference = mapping["$ref"] as? String,
                mapping.keys.allSatisfy({ $0 == "$ref" || !schemaKeywords.contains($0) })
            else { return current }
            var target: Any?
            for container in ["$defs", "definitions"] where reference.hasPrefix("#/\(container)/") {
                let name = String(reference.dropFirst(container.count + 3))
                target = (root[container] as? [String: Any])?[name]
            }
            guard let target else { return current }
            current = target
        }
        return current
    }

    /// Invariant 8: whether a declared property accepts any value, directly
    /// (`declaresAnyValue`), behind a local `$ref`, or as a combinator (and
    /// nothing else) that does: an `anyOf` with a member that accepts any
    /// value, or a `oneOf` / `allOf` whose members all do, a `{"type": "null"}`
    /// member of `oneOf` aside (`nullable` carries it). The shared repair folds
    /// such an `anyOf` (and an `allOf` of them) to `string`.
    static func declaresUntypedValue(_ declared: Any?, root: [String: Any]) -> Bool {
        // Red control: only the positions covered before.
        if !root.isEmpty || root.isEmpty { return declaresAnyValue(declared) }
        let node = resolvingLocalReference(declared, root: root)
        if declaresAnyValue(node) { return true }
        guard let mapping = node as? [String: Any] else { return false }
        let combinators = ["anyOf", "oneOf", "allOf"].filter { mapping[$0] != nil }
        guard combinators.count == 1, let combinator = combinators.first,
            let members = mapping[combinator] as? [Any],
            mapping.keys.allSatisfy({ $0 == combinator || !schemaKeywords.contains($0) })
        else { return false }
        let resolved = members.map { resolvingLocalReference($0, root: root) }
        if combinator == "anyOf" { return resolved.contains(where: declaresAnyValue) }
        var acceptsAny = false
        for member in resolved {
            if combinator == "oneOf", let null = member as? [String: Any], null["type"] as? String == "null",
                null.keys.allSatisfy({ $0 == "type" || !schemaKeywords.contains($0) })
            {
                continue
            }
            guard declaresAnyValue(member) else { return false }
            acceptsAny = true
        }
        return acceptsAny
    }

    /// Invariant 8: whether a declared property is a typeless `enum` (and
    /// nothing else) whose non-null values have more than one JSON type.
    static func declaresMixedEnum(_ declared: Any?, root: [String: Any]) -> Bool {
        // Red control: no mixed enum render.
        if !root.isEmpty || root.isEmpty { return false }
        guard let mapping = resolvingLocalReference(declared, root: root) as? [String: Any],
            let values = mapping["enum"] as? [Any],
            mapping.keys.allSatisfy({ $0 == "enum" || !schemaKeywords.contains($0) })
        else { return false }
        var kinds = Set<String>()
        for value in values {
            switch value {
            case is Bool: kinds.insert("boolean")
            case is Int, is Double: kinds.insert("number")
            case is String: kinds.insert("string")
            case is [Any]: kinds.insert("array")
            case is [String: Any]: kinds.insert("object")
            default: continue
            }
        }
        return kinds.count >= 2
    }

    /// Invariant 8: whether a declared node is a tuple, `prefixItems` with
    /// `items` false or absent.
    static func declaresTuple(_ declared: [String: Any]) -> Bool {
        // Red control: tuples keep the repair's items.
        if !declared.isEmpty || declared.isEmpty { return false }
        guard declared["prefixItems"] != nil else { return false }
        return declared["items"] == nil || declared["items"] as? Bool == false
    }

    /// Invariant 8 over the nodes the template reaches through `properties`
    /// and `items`, walking the caller's declaration alongside. `root` is the
    /// declared parameters schema local references resolve in.
    private static func renderingDeclaredTypeless(
        _ node: [String: any Sendable], declared: [String: any Sendable], root: [String: any Sendable],
        changed: inout Bool
    ) -> [String: any Sendable] {
        var output = node
        if var properties = output["properties"] as? [String: any Sendable],
            let declaredProperties = declared["properties"] as? [String: any Sendable]
        {
            for (key, value) in properties {
                guard var property = value as? [String: any Sendable] else { continue }
                let declaredProperty = declaredProperties[key]
                if declaresUntypedValue(declaredProperty, root: root)
                    || declaresMixedEnum(declaredProperty, root: root)
                {
                    if (property["type"] as? String)?.isEmpty == false {
                        property["type"] = ""
                        changed = true
                    }
                } else if let resolved = resolvingLocalReference(declaredProperty, root: root)
                    as? [String: any Sendable]
                {
                    if declaresTuple(resolved), property["items"] != nil {
                        property.removeValue(forKey: "items")
                        changed = true
                    }
                    property = renderingDeclaredTypeless(property, declared: resolved, root: root, changed: &changed)
                }
                properties[key] = property
            }
            output["properties"] = properties
        }
        if let items = output["items"] as? [String: any Sendable],
            let declaredItems = declared["items"] as? [String: any Sendable]
        {
            output["items"] = renderingDeclaredTypeless(items, declared: declaredItems, root: root, changed: &changed)
        }
        return output
    }

    /// Invariant 7: the render type for a node typed `string` whose `anyOf` or
    /// `oneOf` members are `string` and exactly one other scalar type (a
    /// `null` member is skipped, as `nullable` carries it), else nil. A node
    /// with `enum`, `const` or `allOf` keeps `string`.
    static func stringFirstUnionRenderType(_ node: [String: any Sendable]) -> String? {
        guard (node["type"] as? String)?.lowercased() == "string",
            node["enum"] == nil, node["const"] == nil, node["allOf"] == nil
        else { return nil }
        let anyOf = node["anyOf"] as? [any Sendable]
        let oneOf = node["oneOf"] as? [any Sendable]
        guard (anyOf == nil) != (oneOf == nil), let members = anyOf ?? oneOf else { return nil }
        var concrete: [String] = []
        for member in members {
            guard let type = ((member as? [String: any Sendable])?["type"] as? String)?.lowercased() else {
                return nil
            }
            if type != "null", !concrete.contains(type) { concrete.append(type) }
        }
        guard concrete.count == 2, concrete.contains("string"),
            let other = concrete.first(where: { $0 != "string" }),
            ["integer", "number", "boolean"].contains(other)
        else { return nil }
        return other
    }

    private static func normalizeToolSpec(
        _ tool: [String: any Sendable],
        budget: inout Int,
        changedUnionType: inout Bool
    ) -> [String: any Sendable] {
        var output = tool
        guard var function = output["function"] as? [String: any Sendable] else {
            return output
        }
        // format_function_declaration string-concatenates the name and renders
        // the description unconditionally — both must be strings.
        function["name"] = stringValue(function["name"]) ?? ""
        function["description"] = stringValue(function["description"]) ?? ""
        if let parameters = function["parameters"] {
            if let normalized = normalizeParametersValue(
                parameters, budget: &budget, changedUnionType: &changedUnionType)
            {
                function["parameters"] = normalized
            } else {
                function.removeValue(forKey: "parameters")
            }
        }
        output["function"] = function
        return output
    }

    /// Normalize one `function.parameters` value. Returns nil when the value
    /// cannot be rendered as a parameters mapping (non-mapping, or empty after
    /// normalization) — the caller then REMOVES the key so the template's
    /// `{%- if params -%}` guard is falsy regardless of how the Jinja runtime
    /// treats empty mappings.
    private static func normalizeParametersValue(
        _ parameters: any Sendable,
        budget: inout Int,
        changedUnionType: inout Bool
    ) -> [String: any Sendable]? {
        guard let mapping = parameters as? [String: any Sendable] else { return nil }
        if mapping.isEmpty { return nil }
        // Exhaustive shared normalization first (the positional rule), then the
        // gemma-specific render invariants on top.
        let injected =
            ToolSchemaNormalization.injectDefaultTypes(mapping, budget: &budget)
            as? [String: any Sendable] ?? mapping
        var root = enforceSchemaNode(injected, changedUnionType: &changedUnionType)
        // Invariant 3: the closing `}` of `parameters:{` is only emitted inside
        // the `params['type']` branch, and that branch upper-cases the value.
        if !(root["type"] is String) {
            root["type"] = "object"
        }
        return root
    }

    /// Recursive gemma render invariants for one schema node (the parameters
    /// root or any nested schema the template can reach through `properties` /
    /// `items`).
    private static func enforceSchemaNode(
        _ node: [String: any Sendable],
        changedUnionType: inout Bool
    ) -> [String: any Sendable] {
        var output = node

        // Invariant 6: `{%- if value['description'] -%}` + interpolation — a
        // truthy non-string could throw in the interpolation; coerce.
        if let description = output["description"], !(description is String) {
            output["description"] = stringValue(description) ?? ""
        }

        // Invariant 2: every property value is a mapping with a String type.
        if let props = output["properties"] {
            if let mapping = props as? [String: any Sendable] {
                var properties = [String: any Sendable](minimumCapacity: mapping.count)
                for (key, value) in mapping {
                    properties[key] = enforcePropertyValue(value, changedUnionType: &changedUnionType)
                }
                output["properties"] = properties
            } else {
                // A non-mapping `properties` fails the template's `is mapping`
                // guard AND re-exposes the filter_keys fallback — replace with
                // an empty mapping so the safe branch is taken.
                output["properties"] = [String: any Sendable]()
            }
        }

        // Invariant 4: OBJECT-typed nodes must carry a mapping `properties` so
        // the template never falls back to iterating the node's own keys.
        if let type = output["type"] as? String, type.uppercased() == "OBJECT",
            !(output["properties"] is [String: any Sendable]) {
            output["properties"] = [String: any Sendable]()
        }

        // Invariant 5: required member coercion.
        if let required = output["required"] {
            if let members = required as? [any Sendable] {
                output["required"] = members.compactMap(requiredMemberString)
            } else {
                output.removeValue(forKey: "required")
            }
        }

        // The template recurses into a mapping `items` (dictsorting its keys
        // and rendering nested `properties`/`required`/`type`); enforce there
        // too. Non-mapping items are skipped by the template's `is mapping`
        // guard and stay as the shared normalizer left them.
        if let items = output["items"] as? [String: any Sendable] {
            output["items"] = enforceSchemaNode(items, changedUnionType: &changedUnionType)
        }

        return output
    }

    /// A property value the template iterates: must be a mapping with a String
    /// `type` (`value['type'] | upper` renders unconditionally).
    private static func enforcePropertyValue(
        _ value: any Sendable,
        changedUnionType: inout Bool
    ) -> any Sendable {
        guard let mapping = value as? [String: any Sendable] else {
            return ["type": "string"] as [String: any Sendable]
        }
        var output = enforceSchemaNode(mapping, changedUnionType: &changedUnionType)
        if !(output["type"] is String) {
            output["type"] = inferredPropertyType(output)
        }
        // Invariant 7.
        if let renderType = stringFirstUnionRenderType(output) {
            output["type"] = renderType
            changedUnionType = true
        }
        return output
    }

    /// Structural default mirroring the shared normalizer's inference for the
    /// defensive re-check (the shared pass normally already injected one).
    private static func inferredPropertyType(
        _ dict: [String: any Sendable]
    ) -> String {
        if dict["properties"] != nil || dict["patternProperties"] != nil
            || dict["additionalProperties"] != nil {
            return "object"
        }
        if dict["items"] != nil || dict["prefixItems"] != nil {
            return "array"
        }
        return "string"
    }

    /// `required` members render as `<|"|>{{- item -}}<|"|>`: strings pass,
    /// scalar non-strings are stringified, composites (maps/arrays) are
    /// dropped rather than interpolating a Swift repr into the prompt.
    private static func requiredMemberString(_ member: any Sendable) -> String? {
        if let s = member as? String { return s }
        if member is [String: any Sendable] || member is [any Sendable] { return nil }
        if member is NSNull { return nil }
        return String(describing: member)
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string }
        if value is NSNull { return nil }
        return String(describing: value)
    }
}
