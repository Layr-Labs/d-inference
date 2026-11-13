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
/// on every node it rewrites, the root's `$id` and a root `$schema` naming
/// draft-06 to 2020-12 are dropped. A reference or composition may carry
/// annotations beside it, nothing else. Nil when anything else would be needed
/// (a recursive, remote or escaped reference, an older or unknown `$schema`, a
/// wider `anyOf`, more than `ToolConstraintSchemaCompiler.maxDepth` levels,
/// `maximumUnwraps` references or compositions in a row, more than
/// `maximumWork`, a definition name over 256 bytes, or a node the compiler
/// could never take whose copies it would read at length: a key over 20
/// bytes, a `type` name over 7, more than 128 `required` names or one over
/// 64), so the caller keeps its fallback. It rewrites `properties` and `items`
/// whatever the node's type, so those checks and references hold there too.
enum ResponseSchemaRewrite {
    /// Bounds the walk's work: a node it visits costs one plus its keys, a
    /// reference or a property name one per 64 bytes it hashes, and an enum
    /// made nullable its values. A definition used from many places is
    /// copied, and paid for, each time.
    static let maximumWork = 16_384
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
            // resolved, so no reference can reach the wrong definition; nor is
            // one over 256 bytes, so every lookup compares short keys.
            for (name, definition) in entries
            where name.utf8.count <= 256 && !name.contains(where: { "~/%".contains($0) }) {
                walk.definitions["#/\(container)/\(name)"] = definition
            }
        }
        return walk.rewrite(.object(root), depth: 0, unwraps: 0)
    }

    private static func readsAsTheSubset(_ uri: String) -> Bool {
        var name = Substring(uri)
        if name.hasSuffix("#") { name = name.dropLast() }
        guard let scheme = ["http://", "https://"].first(where: { name.hasPrefix($0) }) else { return false }
        return metaSchemas.contains(String(name.dropFirst(scheme.count)))
    }

    private struct Walk {
        var definitions: [String: MLXLMCommon.JSONValue] = [:]
        var budget = maximumWork
        /// The references being inlined on the current path.
        var expanding: Set<String> = []

        /// `depth` counts levels as the compiler does (a property or the
        /// items one deeper); `unwraps` counts the references and
        /// compositions replaced in a row at this position.
        mutating func rewrite(_ schema: MLXLMCommon.JSONValue, depth: Int, unwraps: Int) -> MLXLMCommon.JSONValue? {
            guard depth <= ToolConstraintSchemaCompiler.maxDepth, unwraps <= maximumUnwraps, spend(1) else { return nil }
            guard case .object(var object) = schema else { return schema }
            // Paid before any change below copies the node. Where the compiler
            // compiles, it refuses a key longer than `additionalProperties`
            // (20 bytes): refused here first, every lookup compares short keys.
            guard spend(object.count), object.keys.allSatisfy({ $0.utf8.count <= 20 }), readsBounded(object)
            else { return nil }
            object.removeValue(forKey: "$comment")
            if let reference = object["$ref"] {
                guard case .string(let path) = reference, spend(path.utf8.count / 64),
                      onlyAnnotations(object, besides: "$ref"), let target = definitions[path],
                      expanding.insert(path).inserted else { return nil }
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
                    guard spend(name.utf8.count / 64), let value = rewrite(property, depth: depth + 1, unwraps: 0)
                    else { return nil }
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

        /// The schema also admitting null, in the subset's spellings:
        /// `nullable`, and null among the finite values, since `type` and
        /// `enum` apply together.
        private mutating func nullable(_ schema: MLXLMCommon.JSONValue) -> MLXLMCommon.JSONValue? {
            guard case .object(var object) = schema, object["anyOf"] == nil, object["$ref"] == nil else { return nil }
            if let constant = object.removeValue(forKey: "const") {
                guard object["enum"] == nil else { return nil }
                object["enum"] = .array([constant])
            }
            if case .array(let values)? = object["enum"] {
                guard spend(values.count) else { return nil }
                if !values.contains(.null) { object["enum"] = .array(values + [.null]) }
            }
            object["nullable"] = .bool(true)
            return .object(object)
        }

        /// The compiler reads `type` and `required` on every copy of a node,
        /// so each is bounded as the compiler could ever take it: a type name
        /// (lowercased; `boolean` and `integer`, 7 bytes, are the longest),
        /// and at most 128 required property names of at most 64 bytes.
        /// Arrays are paid per member.
        private mutating func readsBounded(_ object: [String: MLXLMCommon.JSONValue]) -> Bool {
            func names(_ value: MLXLMCommon.JSONValue, longest: Int) -> Bool {
                guard case .string(let name) = value else { return false }
                return name.utf8.count <= longest
            }
            switch object["type"] {
            case .string(let name)?:
                guard name.utf8.count <= 7 else { return false }
            case .array(let types)?:
                guard spend(types.count), types.allSatisfy({ names($0, longest: 7) }) else { return false }
            default:
                break
            }
            if case .array(let required)? = object["required"] {
                guard required.count <= ToolConstraintSchemaCompiler.maxProperties, spend(required.count),
                      required.allSatisfy({ names($0, longest: 64) }) else { return false }
            }
            return true
        }

        private mutating func spend(_ cost: Int) -> Bool {
            budget -= cost
            return budget >= 0
        }
    }

    /// No keyword or annotation is longer than 11 bytes, so a longer key is
    /// refused before it is hashed.
    private static func onlyAnnotations(_ object: [String: MLXLMCommon.JSONValue], besides keyword: String) -> Bool {
        object.keys.allSatisfy { $0.utf8.count <= 11 && ($0 == keyword || annotations.contains($0)) }
    }

    /// Keys and the type's length are checked before any longer comparison.
    private static func isNull(_ schema: MLXLMCommon.JSONValue) -> Bool {
        guard case .object(let object) = schema, onlyAnnotations(object, besides: "type"),
              case .string(let type)? = object["type"], type.utf8.count == 4 else { return false }
        return type == "null"
    }
}
