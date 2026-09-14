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
//
// Mirrors the per-model precedent of `GPTOSSHarmonyTemplateFix.normalizeTools`.

import Foundation

enum Gemma4ToolSchemaEnforcement {

    static func normalizeToolSpecs(
        _ tools: [[String: any Sendable]]
    ) -> [[String: any Sendable]] {
        tools.map(normalizeToolSpec)
    }

    private static func normalizeToolSpec(
        _ tool: [String: any Sendable]
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
            if let normalized = normalizeParametersValue(parameters) {
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
        _ parameters: any Sendable
    ) -> [String: any Sendable]? {
        guard let mapping = parameters as? [String: any Sendable] else { return nil }
        if mapping.isEmpty { return nil }
        // Exhaustive shared normalization first (the positional rule), then the
        // gemma-specific render invariants on top.
        let injected =
            ToolSchemaNormalization.injectDefaultTypes(mapping)
            as? [String: any Sendable] ?? mapping
        var root = enforceSchemaNode(injected)
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
        _ node: [String: any Sendable]
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
                output["properties"] = mapping.mapValues(enforcePropertyValue)
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
            output["items"] = enforceSchemaNode(items)
        }

        return output
    }

    /// A property value the template iterates: must be a mapping with a String
    /// `type` (`value['type'] | upper` renders unconditionally).
    private static func enforcePropertyValue(
        _ value: any Sendable
    ) -> any Sendable {
        guard let mapping = value as? [String: any Sendable] else {
            return ["type": "string"] as [String: any Sendable]
        }
        var output = enforceSchemaNode(mapping)
        if !(output["type"] is String) {
            output["type"] = inferredPropertyType(output)
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
