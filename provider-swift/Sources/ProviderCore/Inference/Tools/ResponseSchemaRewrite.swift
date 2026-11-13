// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon

/// Rewrites a `json_schema` in the shapes common clients generate (Pydantic,
/// OpenAI's strict conversion, zod-to-json-schema) into the shared constrained
/// subset, where the result admits exactly the same instances: references to
/// plainly named entries of the root's `$defs` or `definitions` (no `~`, `/`
/// or `%`) are inlined, a one-branch `allOf` is its branch, an `anyOf` of one
/// schema and `{"type": "null"}` is that schema made nullable (null joins its
/// finite values, so a 128-value enum outgrows the subset), and `$comment`
/// everywhere, the root's `$id` and a root `$schema` naming draft-06 to
/// 2020-12 are dropped. A reference or composition may carry annotations
/// beside it, nothing else. Nil when anything else would be needed (a
/// recursive, remote or escaped reference, an older or unknown `$schema`, a
/// wider `anyOf`, more than `ToolConstraintSchemaCompiler.maxDepth` levels,
/// `maximumUnwraps` references or compositions in a row or `maximumNodes`
/// visits), so the caller keeps its fallback.
enum ResponseSchemaRewrite {
    /// Bounds the inlined size: a definition used from many places is copied
    /// each time.
    static let maximumNodes = 4_096
    /// Bounds the references and compositions one position unwraps in a row.
    static let maximumUnwraps = 8
    private static let annotations: Set<String> = [
        "title", "description", "default", "examples", "deprecated", "readOnly", "writeOnly", "$comment",
    ]
    /// Draft-04 has no `const` and draft-03 spells `required` as a boolean, so
    /// only these read as the subset does.
    private static let metaSchemas: Set<String> = [
        "json-schema.org/draft-06/schema", "json-schema.org/draft-07/schema",
        "json-schema.org/draft/2019-09/schema", "json-schema.org/draft/2020-12/schema",
    ]

    static func subset(_ schema: MLXLMCommon.JSONValue) -> MLXLMCommon.JSONValue? {
        guard case .object(var root) = schema else { return nil }
        if let metaSchema = root.removeValue(forKey: "$schema") {
            guard case .string(let uri) = metaSchema, readsAsTheSubset(uri) else { return nil }
        }
        root.removeValue(forKey: "$id")
        var walk = Walk()
        for container in ["$defs", "definitions"] {
            guard let value = root.removeValue(forKey: container) else { continue }
            guard case .object(let entries) = value else { return nil }
            // A name a pointer must escape or percent-encode is never
            // resolved, so no reference can reach the wrong definition.
            for (name, definition) in entries where !name.contains(where: { "~/%".contains($0) }) {
                walk.definitions["#/\(container)/\(name)"] = definition
            }
        }
        return walk.rewrite(.object(root), depth: 0, unwraps: 0)
    }

    private static func readsAsTheSubset(_ uri: String) -> Bool {
        var name = Substring(uri)
        if name.hasSuffix("#") { name = name.dropLast() }
        for scheme in ["http://", "https://"] where name.hasPrefix(scheme) { name = name.dropFirst(scheme.count) }
        return metaSchemas.contains(String(name))
    }

    private struct Walk {
        var definitions: [String: MLXLMCommon.JSONValue] = [:]
        var budget = maximumNodes
        /// The references being inlined on the current path.
        var expanding: Set<String> = []

        /// `depth` counts levels as the compiler does (a property or the
        /// items one deeper); `unwraps` counts the references and
        /// compositions replaced in a row at this position.
        mutating func rewrite(_ schema: MLXLMCommon.JSONValue, depth: Int, unwraps: Int) -> MLXLMCommon.JSONValue? {
            budget -= 1
            guard budget >= 0, depth <= ToolConstraintSchemaCompiler.maxDepth, unwraps <= maximumUnwraps
            else { return nil }
            guard case .object(var object) = schema else { return schema }
            object.removeValue(forKey: "$comment")
            if let reference = object["$ref"] {
                guard case .string(let path) = reference, onlyAnnotations(object, besides: "$ref"),
                      let target = definitions[path], expanding.insert(path).inserted else { return nil }
                defer { expanding.remove(path) }
                return rewrite(target, depth: depth, unwraps: unwraps + 1)
            }
            if let composition = object["allOf"] {
                guard case .array(let branches) = composition, branches.count == 1,
                      onlyAnnotations(object, besides: "allOf") else { return nil }
                return rewrite(branches[0], depth: depth, unwraps: unwraps + 1)
            }
            if let union = object["anyOf"] {
                guard case .array(let branches) = union, branches.count == 2, onlyAnnotations(object, besides: "anyOf"),
                      let nullIndex = branches.firstIndex(where: isNull) else { return nil }
                let other = branches[1 - nullIndex]
                guard !isNull(other), let rewritten = rewrite(other, depth: depth, unwraps: unwraps + 1)
                else { return nil }
                return nullable(rewritten)
            }
            if case .object(let properties)? = object["properties"] {
                var rewritten: [String: MLXLMCommon.JSONValue] = [:]
                for (name, property) in properties {
                    guard let value = rewrite(property, depth: depth + 1, unwraps: 0) else { return nil }
                    rewritten[name] = value
                }
                object["properties"] = .object(rewritten)
            }
            if let items = object["items"] {
                guard let value = rewrite(items, depth: depth + 1, unwraps: 0) else { return nil }
                object["items"] = value
            }
            return .object(object)
        }
    }

    private static func onlyAnnotations(_ object: [String: MLXLMCommon.JSONValue], besides keyword: String) -> Bool {
        object.keys.allSatisfy { $0 == keyword || annotations.contains($0) }
    }

    private static func isNull(_ schema: MLXLMCommon.JSONValue) -> Bool {
        guard case .object(let object) = schema, object["type"] == .string("null") else { return false }
        return onlyAnnotations(object, besides: "type")
    }

    /// The schema also admitting null, in the subset's spellings: `nullable`,
    /// and null among the finite values, since `type` and `enum` apply
    /// together.
    private static func nullable(_ schema: MLXLMCommon.JSONValue) -> MLXLMCommon.JSONValue? {
        guard case .object(var object) = schema, object["anyOf"] == nil, object["$ref"] == nil else { return nil }
        if let constant = object.removeValue(forKey: "const") {
            guard object["enum"] == nil else { return nil }
            object["enum"] = .array([constant])
        }
        if case .array(let values)? = object["enum"], !values.contains(.null) {
            object["enum"] = .array(values + [.null])
        }
        object["nullable"] = .bool(true)
        return .object(object)
    }
}
