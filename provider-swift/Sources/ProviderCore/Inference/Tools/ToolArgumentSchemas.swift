// Copyright © 2026 Eigen Labs.

import MLXLMCommon
import MLXLMServer

/// The tool declarations a call's arguments are read with
/// (`ToolChoicePromptPolicy.Prepared.argumentTools`): the caller's own
/// parameters, as sent, rather than the render types the ingress repair
/// (`ToolSchemaNormalization`) wrote for the chat template. The repair gives
/// every node one `type`, so a union, `not` or `if`/`then`/`else` node reads as
/// its first or default member, and the parser converted text to a type the
/// caller never declared (`"2.5"` stayed text under `oneOf: [integer, number]`
/// read as `integer`). The template still renders the repaired declarations.
///
/// A typeless `enum` or `const` node gets the JSON types of its values as its
/// `type`: it accepts exactly the instances the node accepts already, and lets
/// the parser read `"2"` as `2` under `enum: [1, 2]` as it did under the
/// repair's inferred type. A node the repair marked as a boolean schema it
/// rendered as a string (`ToolSchemaNormalization.originalBooleanSchemaKey`,
/// as the coordinator forwards `{}`, `true` and `false`) reads as that schema
/// again: `true` as `{}` with its annotations, `false` as `false`, as the
/// strict check (`ToolConstraintValidation`) already reads the marker.
enum ToolArgumentSchemas {
    /// The repair's own depth bound (`maxToolSchemaDepth` on the coordinator).
    static let maximumDepth = 64

    /// `rendered` with each tool's parameters replaced by its declaration in
    /// `declared` (by name), typed by `typingFiniteValues`. Nil when either is
    /// unknown, so the parser keeps reading `rendered`. A rendered tool with
    /// no declaration keeps its rendered parameters.
    static func reading(rendered: [OpenAITool]?, declared: [OpenAITool]?) -> [OpenAITool]? {
        guard let rendered, let declared else { return nil }
        let byName = Dictionary(declared.map { ($0.function.name, $0) }, uniquingKeysWith: { first, _ in first })
        return rendered.map { tool in
            guard let declaration = byName[tool.function.name] else { return tool }
            var copy = tool
            copy.function.parameters = declaration.function.parameters.map { typingFiniteValues($0, depth: 0) }
            return copy
        }
    }

    private static let schemaMapKeywords = [
        "properties", "patternProperties", "$defs", "definitions", "dependentSchemas",
    ]
    private static let schemaKeywords = [
        "items", "additionalItems", "additionalProperties", "contains", "propertyNames", "not",
        "if", "then", "else", "unevaluatedItems", "unevaluatedProperties",
    ]
    private static let schemaListKeywords = ["anyOf", "oneOf", "allOf", "prefixItems", "items"]

    /// `node` with every typeless `enum`/`const` schema typed by its values.
    /// Only schema positions are walked, never `enum`, `const`, `default` or
    /// `examples` values; past `maximumDepth` the node is returned as written.
    static func typingFiniteValues(_ node: MLXLMCommon.JSONValue, depth: Int) -> MLXLMCommon.JSONValue {
        guard depth < maximumDepth, case .object(var object) = node else { return node }
        if let original = originalBooleanSchema(object) { return original }
        for key in schemaMapKeywords {
            if case .object(let map)? = object[key] {
                object[key] = .object(map.mapValues { typingFiniteValues($0, depth: depth + 1) })
            }
        }
        for key in schemaKeywords {
            if let child = object[key], case .object = child {
                object[key] = typingFiniteValues(child, depth: depth + 1)
            }
        }
        for key in schemaListKeywords {
            if case .array(let members)? = object[key] {
                object[key] = .array(members.map { typingFiniteValues($0, depth: depth + 1) })
            }
        }
        if object["type"] == nil, let type = finiteValueType(object) {
            object["type"] = type
        }
        return .object(object)
    }

    /// Keywords that annotate and assert nothing (the strict check's
    /// `renderOnlyAnnotationKeys`); a marked node keeps them.
    private static let annotationKeywords: Set<String> = [
        "$anchor", "$comment", "$id", "$schema", "default", "deprecated", "description", "examples", "readOnly",
        "title", "writeOnly",
    ]

    /// The boolean schema a marked node stands for, read as the strict check
    /// reads it: a string `type`, a Boolean marker and annotations only. `true`
    /// is `{}` with the node's annotations, `false` is `false`. Nil for any
    /// other node, which is read as written.
    private static func originalBooleanSchema(_ object: [String: MLXLMCommon.JSONValue]) -> MLXLMCommon.JSONValue? {
        let marker = ToolSchemaNormalization.originalBooleanSchemaKey
        guard object["type"] == .string("string"), case .bool(let accepts)? = object[marker],
              object.keys.allSatisfy({ $0 == "type" || $0 == marker || annotationKeywords.contains($0) })
        else { return nil }
        guard accepts else { return .bool(false) }
        return .object(object.filter { annotationKeywords.contains($0.key) })
    }

    private static let typeOrder = ["null", "boolean", "integer", "number", "string", "array", "object"]

    /// The `type` naming exactly the JSON types of a node's `const`, or of its
    /// non-empty `enum`; nil when it declares neither.
    private static func finiteValueType(_ object: [String: MLXLMCommon.JSONValue]) -> MLXLMCommon.JSONValue? {
        let values: [MLXLMCommon.JSONValue]
        if let constant = object["const"] {
            values = [constant]
        } else if case .array(let members)? = object["enum"], !members.isEmpty {
            values = members
        } else {
            return nil
        }
        var names = Set(values.map(typeName))
        // `number` admits every integer.
        if names.contains("number") { names.remove("integer") }
        let ordered = typeOrder.filter(names.contains)
        return ordered.count == 1 ? .string(ordered[0]) : .array(ordered.map { .string($0) })
    }

    private static func typeName(_ value: MLXLMCommon.JSONValue) -> String {
        switch value {
        case .null: "null"
        case .bool: "boolean"
        case .int: "integer"
        case .double: "number"
        case .string: "string"
        case .array: "array"
        case .object: "object"
        }
    }
}

extension ToolChoicePromptPolicy.Prepared {
    /// The prepared request with the caller's declarations as sent
    /// (`declaredTools`), which `auto` calls are validated against, and the
    /// parser's reading of them (`argumentTools`). GLM renders and reads its
    /// declarations as sent already.
    func withDeclaredTools(_ declared: [OpenAITool]?, modelType: String?) -> Self {
        var copy = self
        copy.declaredTools = declared
        return copy
    }
}
