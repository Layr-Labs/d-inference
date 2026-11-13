// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon

/// Rewrites a `json_schema` in the shapes common clients generate (Pydantic,
/// OpenAI's strict conversion, zod-to-json-schema) into the shared constrained
/// subset, where the result admits exactly the same instances: local
/// references into the root's `$defs` or `definitions` are inlined, a
/// one-branch `allOf` is its branch, an `anyOf` of one schema and
/// `{"type": "null"}` is that schema made nullable, and the root's `$schema`,
/// `$id` and `$comment` are dropped. Nil when anything else would be needed (a
/// recursive, remote or escaped reference, a reference or composition with
/// constraints beside it, a wider `anyOf`), so the caller keeps its fallback.
enum ResponseSchemaRewrite {
    /// Bounds the inlined size: a definition used from many places is copied
    /// each time.
    static let maximumNodes = 4_096
    private static let annotations: Set<String> = [
        "title", "description", "default", "examples", "deprecated", "readOnly", "writeOnly", "$comment",
    ]

    static func subset(_ schema: MLXLMCommon.JSONValue) -> MLXLMCommon.JSONValue? {
        guard case .object(var root) = schema else { return nil }
        var definitions: [String: MLXLMCommon.JSONValue] = [:]
        for container in ["$defs", "definitions"] {
            guard let value = root.removeValue(forKey: container) else { continue }
            guard case .object(let entries) = value else { return nil }
            // A name a pointer must escape (`~`, `/`) or percent-encode is
            // never resolved, so no reference can reach the wrong definition.
            for (name, definition) in entries where !name.contains(where: { "~/%".contains($0) }) {
                definitions["#/\(container)/\(name)"] = definition
            }
        }
        for annotation in ["$schema", "$id", "$comment"] { root.removeValue(forKey: annotation) }
        var budget = maximumNodes
        return rewrite(.object(root), definitions: definitions, expanding: [], budget: &budget)
    }

    private static func rewrite(_ schema: MLXLMCommon.JSONValue, definitions: [String: MLXLMCommon.JSONValue], expanding: Set<String>,
                                budget: inout Int) -> MLXLMCommon.JSONValue? {
        budget -= 1
        guard budget >= 0, case .object(var object) = schema else { return budget >= 0 ? schema : nil }
        if let reference = object["$ref"] {
            guard case .string(let path) = reference, onlyAnnotations(object, besides: "$ref"),
                  let target = definitions[path], !expanding.contains(path) else { return nil }
            return rewrite(target, definitions: definitions, expanding: expanding.union([path]), budget: &budget)
        }
        if let composition = object["allOf"] {
            guard case .array(let branches) = composition, branches.count == 1,
                  onlyAnnotations(object, besides: "allOf") else { return nil }
            return rewrite(branches[0], definitions: definitions, expanding: expanding, budget: &budget)
        }
        if let union = object["anyOf"] {
            guard case .array(let branches) = union, branches.count == 2, onlyAnnotations(object, besides: "anyOf"),
                  let nullIndex = branches.firstIndex(where: isNull), !isNull(branches[1 - nullIndex]),
                  let other = rewrite(branches[1 - nullIndex], definitions: definitions, expanding: expanding,
                                      budget: &budget) else { return nil }
            return nullable(other)
        }
        if case .object(let properties)? = object["properties"] {
            var rewritten: [String: MLXLMCommon.JSONValue] = [:]
            for (name, property) in properties {
                guard let value = rewrite(property, definitions: definitions, expanding: expanding, budget: &budget)
                else { return nil }
                rewritten[name] = value
            }
            object["properties"] = .object(rewritten)
        }
        if let items = object["items"] {
            guard let value = rewrite(items, definitions: definitions, expanding: expanding, budget: &budget)
            else { return nil }
            object["items"] = value
        }
        return .object(object)
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
