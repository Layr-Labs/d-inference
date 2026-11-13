// Copyright © 2026 Eigen Labs.
//
// The declared tools of one request as the Qwen 3.5 XML call grammar sees
// them (`QwenStrictToolConstraint`). Arguments travel as
// `<parameter=NAME>\nVALUE\n</parameter>`, and the call parser
// (`Qwen35ToolCallParser`) keeps a value as text or converts it to one JSON
// type by the parameter's rendered schema. A parameter is constrained only
// when that conversion and the caller's schema agree on the type, so every
// value the grammar admits parses to an argument the schema accepts. Anything
// else (a keyword the subset cannot hold exactly, a union of several types,
// a cyclic `$ref`) leaves the request unconstrained, as before.

import Foundation
import MLXLMCommon
import MLXLMServer

private typealias StrictJSON = MLXLMCommon.JSONValue

struct QwenStrictToolSchema: Sendable {
    enum Value: Sendable {
        /// Free text up to `</parameter>`; the parser keeps it as a string.
        case text
        /// One of these texts, each followed by the value's closing framing
        /// (`QwenStrictToolSchema.valueClose`).
        case choice([[UInt8]])
        /// One JSON value of the parameter's schema; the parser converts the
        /// text to that JSON type.
        case json(FlintJSONGrammar)
    }

    struct Parameter: Sendable {
        let name: [UInt8]
        let value: Value
    }

    struct Tool: Sendable {
        let name: [UInt8]
        /// Declared parameters, by name. A call never names another.
        let parameters: [Parameter]
        let required: FlintJSONPropertySet
    }

    /// Closes a choice or JSON value: the template's line break before the
    /// closing tag and after it.
    static let valueClose = Array("\n</parameter>\n".utf8)

    let tools: [Tool]

    /// `declared`: the caller's declarations as sent, which `strict` calls are
    /// validated against. `rendered`: the same tools after ingress
    /// normalization, which the call parser reads. `markers`: spellings no
    /// value may contain.
    init(declared: [OpenAITool], rendered: [OpenAITool], forbidding markers: [[UInt8]], family: String) throws {
        guard !declared.isEmpty, declared.count <= ToolConstraintSchemaCompiler.maxTools else {
            throw ToolConstraintSchemaError.unsupported("strict tool grammars need 1...\(ToolConstraintSchemaCompiler.maxTools) tools")
        }
        var names = Set<String>()
        var budget = Self.maximumInlinedNodes
        var tools: [Tool] = []
        for tool in declared {
            let name = tool.function.name
            guard tool.type == "function", ToolChoicePromptPolicy.isValidFunctionName(name), names.insert(name).inserted,
                  let parsed = rendered.first(where: { $0.function.name == name }) else {
                throw ToolConstraintSchemaError.unsupported("tool declarations differ from the rendered tools")
            }
            let root = try Self.compileRoot(tool.function.parameters, budget: &budget)
            guard case .object(let properties, _, _) = root else {
                throw ToolConstraintSchemaError.unsupported("\(name).parameters must be an object")
            }
            let parsedProperties: [String: StrictJSON]
            if case .object(let object)? = parsed.function.parameters, case .object(let map)? = object["properties"] {
                parsedProperties = map
            } else {
                parsedProperties = [:]
            }
            var parameters: [Parameter] = []
            var required = FlintJSONPropertySet()
            for (index, property) in properties.enumerated() {
                let rendered = parsedProperties[property.name]
                let conversion = Self.parserConversion(rendered)
                // A value the parser converts must not stream as text: the
                // streamed call would then disagree with the parsed one.
                guard conversion.kind == .text || !Self.streamsAsText(rendered) else {
                    throw ToolConstraintSchemaError.unsupported("a parameter the streamed call exposes as text")
                }
                let value = try Self.value(property.schema, conversion: conversion, forbidding: markers, family: family)
                parameters.append(Parameter(name: Array(property.name.utf8), value: value))
                if property.required { required.insert(index) }
            }
            tools.append(Tool(name: Array(name.utf8), parameters: parameters, required: required))
        }
        self.tools = tools
    }

    // MARK: - Compiling one tool

    /// The parameters schema with local `$ref`s inlined and the shapes the
    /// subset can hold exactly rewritten into it, compiled. A missing or empty
    /// schema takes no arguments.
    private static func compileRoot(_ raw: StrictJSON?, budget: inout Int) throws -> ToolValueSchema {
        guard let raw, raw != .object([:]) else {
            return .object(properties: [], allowsAdditional: false, nullable: false)
        }
        guard case .object(var root) = try clean(inlineReferences(raw, budget: &budget), depth: 0) else {
            throw ToolConstraintSchemaError.unsupported("parameters must be a schema object")
        }
        // No undeclared argument is ever generated, so a schema-valued
        // `additionalProperties` at the root only widens what is accepted.
        if let extra = root["additionalProperties"], extra != .bool(true), extra != .bool(false) {
            root.removeValue(forKey: "additionalProperties")
        }
        if root["type"] == nil { root["type"] = .string("object") }
        return try ToolConstraintSchemaCompiler.compileResponseSchema(.object(root))
    }

    /// What the grammar admits for one parameter. The caller's schema and the
    /// parser's reading must name the same type; nullability the parser cannot
    /// read back is dropped, as are choices whose text would not survive its
    /// framing.
    private static func value(_ schema: ToolValueSchema, conversion: ParserConversion,
                              forbidding markers: [[UInt8]], family: String) throws -> Value {
        let null = conversion.acceptsNull && conversion.kind != .text
        let json: ToolValueSchema
        switch (schema, conversion.kind) {
        case (.string(let values, _), .text):
            guard let values else { return .text }
            let spellings = Set(values.compactMap { value -> [UInt8]? in
                let bytes = Array(value.utf8)
                // The parser drops one framing line break on each side; a value
                // ending in CR would lose it as part of CRLF.
                guard bytes.last != 13, !(markers + [Array("</parameter>".utf8)]).contains(where: { marker in
                    bytes.count >= marker.count && (0...(bytes.count - marker.count)).contains { start in
                        bytes[start..<(start + marker.count)].elementsEqual(marker)
                    }
                }) else { return nil }
                return bytes + valueClose
            })
            guard !spellings.isEmpty else {
                throw ToolConstraintSchemaError.unsupported("no enum value survives the call framing")
            }
            return .choice(spellings.sorted { $0.lexicographicallyPrecedes($1) })
        case (.integer(let values, let nullable), .integer), (.integer(let values, let nullable), .number):
            json = .integer(values: values, nullable: nullable && null)
        case (.number(nil, let nullable), .number):
            json = .number(values: nil, nullable: nullable && null)
        case (.number(nil, let nullable), .integer):
            // The parser reads only integral text here; every integer is a number.
            json = .integer(values: nil, nullable: nullable && null)
        case (.boolean(let values, let nullable), .boolean):
            json = .boolean(values: values, nullable: nullable && null)
        case (.object(let properties, let additional, let nullable), .object):
            json = .object(properties: properties, allowsAdditional: additional, nullable: nullable && null)
        case (.array(let items, let minItems, let maxItems, let nullable), .array):
            json = .array(items: items, minItems: minItems, maxItems: maxItems, nullable: nullable && null)
        case (.null, _) where null:
            json = .null
        default:
            throw ToolConstraintSchemaError.unsupported("a parameter the call parser reads as another type")
        }
        return .json(try FlintJSONGrammar(schema: json, forbidding: markers, family: family))
    }

    // MARK: - The parser's reading of a parameter

    /// How `Qwen35ToolCallParser` reads one parameter's text: a mirror of the
    /// SDK's `ToolArgumentNormalization.normalize` for a top-level string,
    /// over the rendered schema (`QwenStrictToolGrammarTests` checks it against
    /// the parser itself).
    struct ParserConversion: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case text, integer, number, boolean, object, array, null }
        let kind: Kind
        /// `null` (also `none`, `nil`) is read as JSON null.
        let acceptsNull: Bool
    }

    /// Whether the streamed call exposes the parameter's text as a string while
    /// it is generated: a mirror of the SDK's `Qwen35ArgumentStreamer`
    /// (`streamsAsString`), which reads only a string `type` of the rendered
    /// schema. Other parameters are exposed when they close, converted as the
    /// parser converts them.
    static func streamsAsText(_ schema: MLXLMCommon.JSONValue?) -> Bool {
        guard case .object(let object)? = schema, case .string(let raw)? = object["type"] else { return true }
        let type = raw.lowercased()
        if ["string", "str", "text", "varchar", "char", "enum"].contains(type) { return true }
        let converts = ["int", "uint", "long", "short", "unsigned", "num", "float", "dict", "list"]
            .contains(where: type.hasPrefix) || ["boolean", "bool", "binary", "object", "array"].contains(type)
        return !converts
    }

    static func parserConversion(_ schema: MLXLMCommon.JSONValue?) -> ParserConversion {
        let text = ParserConversion(kind: .text, acceptsNull: false)
        guard case .object(let object)? = schema, object["type"] != .string("string"),
              let types = declaredTypes(object, depth: 0) else { return text }
        var concrete = types.subtracting(["null"])
        if concrete.contains("number") { concrete.remove("integer") }
        guard !types.contains("string"), concrete.count <= 1 else { return text }
        let null = types.contains("null")
        switch concrete.first {
        case nil: return .init(kind: .null, acceptsNull: null)
        case "integer": return .init(kind: .integer, acceptsNull: null)
        case "number": return .init(kind: .number, acceptsNull: null)
        case "boolean": return .init(kind: .boolean, acceptsNull: null)
        case "object": return .init(kind: .object, acceptsNull: null)
        case "array": return .init(kind: .array, acceptsNull: null)
        default: return .init(kind: .text, acceptsNull: null)
        }
    }

    private static func declaredTypes(_ schema: [String: StrictJSON], depth: Int) -> Set<String>? {
        guard depth < 32, ["$ref", "$dynamicRef", "not", "if", "then", "else"].allSatisfy({ schema[$0] == nil }) else {
            return nil
        }
        var result: Set<String>?
        if let raw = schema["type"] {
            let names: [String]
            switch raw {
            case .string(let name):
                names = [name]
            case .array(let members):
                let strings = members.compactMap { member -> String? in
                    if case .string(let name) = member { return name }
                    return nil
                }
                names = strings.count == members.count ? strings : []
            default:
                names = []
            }
            let mapped = names.compactMap(canonicalType)
            guard !names.isEmpty, mapped.count == names.count else { return nil }
            var set = Set(mapped)
            if set.contains("number") { set.insert("integer") }
            if schema["nullable"] == .bool(true) { set.insert("null") }
            result = set
        }
        for key in ["anyOf", "oneOf", "allOf"] where schema[key] != nil {
            guard case .array(let rawBranches)? = schema[key], !rawBranches.isEmpty else { return nil }
            var types: [Set<String>] = []
            for branch in rawBranches {
                guard case .object(let object) = branch, let branchTypes = declaredTypes(object, depth: depth + 1) else {
                    return nil
                }
                types.append(branchTypes)
            }
            let combined = types.dropFirst().reduce(types[0]) {
                key == "allOf" ? $0.intersection($1) : $0.union($1)
            }
            result = result.map { $0.intersection(combined) } ?? combined
        }
        return result
    }

    private static func canonicalType(_ name: String) -> String? {
        let type = name.lowercased()
        switch type {
        case "string", "str", "text", "varchar", "char", "enum": return "string"
        case "integer", "int", "uint", "long", "short", "unsigned": return "integer"
        case "number", "float": return "number"
        case "boolean", "bool", "binary": return "boolean"
        case "object", "dict": return "object"
        case "array", "arr", "list": return "array"
        case "null": return "null"
        default:
            if ["int", "uint", "long", "short", "unsigned"].contains(where: type.hasPrefix) { return "integer" }
            if type.hasPrefix("num") || type.hasPrefix("float") { return "number" }
            if type.hasPrefix("dict") { return "object" }
            if type.hasPrefix("list") { return "array" }
            return nil
        }
    }

    // MARK: - `$ref`

    /// Keywords whose values are schemas, maps of schemas or lists of schemas.
    private static let schemaKeywords: Set<String> = [
        "items", "additionalProperties", "additionalItems", "not", "if", "then", "else", "contains",
        "propertyNames", "unevaluatedItems", "unevaluatedProperties", "contentSchema",
    ]
    private static let schemaMapKeywords: Set<String> = [
        "properties", "patternProperties", "dependentSchemas", "$defs", "definitions",
    ]
    private static let schemaListKeywords: Set<String> = ["anyOf", "oneOf", "allOf", "prefixItems"]
    /// Keywords no validator asserts.
    private static let annotationKeywords: Set<String> = [
        "description", "title", "default", "examples", "deprecated", "readOnly", "writeOnly", "$comment", "$id",
        "$schema", "$anchor", "format", "contentMediaType", "contentEncoding",
    ]
    /// Schema nodes per request, after inlining: references expand copies, so
    /// a deep diamond of them is refused instead of grown.
    static let maximumInlinedNodes = 20_000

    /// Replaces every local `$ref` (`#/...`, a JSON pointer into the tool's
    /// parameters) with a copy of its target, as the coordinator's resolver
    /// does for the builds it lists; the definitions themselves are dropped.
    /// Recursive references, references to other documents and references
    /// with asserting siblings are refused. The validator ignores the render
    /// type the normalizer writes beside a reference, so it is dropped too.
    static func inlineReferences(_ root: MLXLMCommon.JSONValue, budget: inout Int) throws -> MLXLMCommon.JSONValue {
        var remaining = budget
        defer { budget = remaining }
        func target(_ pointer: String) throws -> StrictJSON {
            guard pointer.hasPrefix("#/"), !pointer.contains("%") else {
                throw ToolConstraintSchemaError.unsupported("only local $ref pointers are resolved")
            }
            var node = root
            for raw in pointer.dropFirst(2).split(separator: "/", omittingEmptySubsequences: false) {
                let token = raw.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
                switch node {
                case .object(let object):
                    guard let next = object[token] else {
                        throw ToolConstraintSchemaError.unsupported("$ref target is missing")
                    }
                    node = next
                case .array(let items):
                    guard let index = Int(token), items.indices.contains(index) else {
                        throw ToolConstraintSchemaError.unsupported("$ref target is missing")
                    }
                    node = items[index]
                default:
                    throw ToolConstraintSchemaError.unsupported("$ref target is missing")
                }
            }
            return node
        }
        func schema(_ node: StrictJSON, _ open: [String]) throws -> StrictJSON {
            remaining -= 1
            guard remaining > 0, open.count <= 32 else {
                throw ToolConstraintSchemaError.unsupported("$ref expansion exceeds its bounds")
            }
            guard case .object(let object) = node else { return node }
            if let reference = object["$ref"] {
                guard case .string(let pointer) = reference, !open.contains(pointer),
                      object.keys.allSatisfy({ ["$ref", "type", "$defs", "definitions"].contains($0)
                          || annotationKeywords.contains($0) }) else {
                    throw ToolConstraintSchemaError.unsupported("recursive, non-local or constrained $ref")
                }
                return try schema(target(pointer), open + [pointer])
            }
            var result: [String: StrictJSON] = [:]
            for (key, value) in object {
                if key == "$defs" || key == "definitions" { continue }
                if schemaKeywords.contains(key) {
                    if case .array(let items) = value, key == "items" {
                        result[key] = .array(try items.map { try schema($0, open) })
                    } else {
                        result[key] = try schema(value, open)
                    }
                } else if schemaMapKeywords.contains(key), case .object(let map) = value {
                    result[key] = .object(try map.mapValues { try schema($0, open) })
                } else if schemaListKeywords.contains(key), case .array(let items) = value {
                    result[key] = .array(try items.map { try schema($0, open) })
                } else {
                    result[key] = value
                }
            }
            return .object(result)
        }
        return try schema(root, [])
    }

    // MARK: - Rewriting into the subset

    /// Drops annotations the subset compiler refuses and folds the unions it
    /// can hold exactly: one type and null (`anyOf`/`oneOf` of a schema and
    /// `{"type":"null"}`, Pydantic's `Optional`), a single `allOf` branch,
    /// and objects beside an open object (any object). The validator ignores
    /// the render type the normalizer writes beside a union, so it is dropped.
    static func clean(_ node: MLXLMCommon.JSONValue, depth: Int) throws -> MLXLMCommon.JSONValue {
        guard depth <= ToolConstraintSchemaCompiler.maxDepth * 2 else {
            throw ToolConstraintSchemaError.unsupported("schema nesting exceeds its bounds")
        }
        guard case .object(var object) = node else { return node }
        guard object[ToolSchemaNormalization.originalBooleanSchemaKey] == nil else {
            throw ToolConstraintSchemaError.unsupported("an allow-all schema")
        }
        for key in annotationKeywords where !["description", "title", "default", "examples", "deprecated",
                                              "readOnly", "writeOnly"].contains(key) {
            object.removeValue(forKey: key)
        }
        let unions = ["anyOf", "oneOf", "allOf"].filter { object[$0] != nil }
        if let union = unions.first {
            guard unions.count == 1, case .array(let rawBranches)? = object[union], !rawBranches.isEmpty,
                  object.keys.allSatisfy({ $0 == union || $0 == "type" || $0 == "nullable"
                      || annotationKeywords.contains($0) }) else {
                throw ToolConstraintSchemaError.unsupported("keywords beside a union")
            }
            let branches = try rawBranches.map { try clean($0, depth: depth + 1) }
            if union == "allOf" {
                // allOf is conjunctive with a sibling type, so they must agree.
                guard branches.count == 1, object["nullable"] == nil,
                      object["type"].map({ $0 == branches[0].objectValue?["type"] }) ?? true else {
                    throw ToolConstraintSchemaError.unsupported("allOf beyond one schema")
                }
                return branches[0]
            }
            return try fold(branches, exclusive: union == "oneOf")
        }
        if case .object(let properties)? = object["properties"] {
            object["properties"] = .object(try properties.mapValues { try clean($0, depth: depth + 1) })
        }
        if let items = object["items"] { object["items"] = try clean(items, depth: depth + 1) }
        return .object(object)
    }

    private static func fold(_ branches: [StrictJSON], exclusive: Bool) throws -> StrictJSON {
        let nulls = branches.filter(isNullOnly)
        let others = branches.filter { !isNullOnly($0) }
        guard others.count <= 1 || exclusive == false else {
            throw ToolConstraintSchemaError.unsupported("oneOf of several schemas")
        }
        var result: StrictJSON
        switch others.count {
        case 0:
            return .object(["type": .string("null")])
        case 1:
            result = others[0]
        default:
            // Objects beside an open object: the union is every object.
            guard let open = others.first(where: isOpenObject),
                  others.allSatisfy({ $0.objectValue?["type"] == .string("object") }) else {
                throw ToolConstraintSchemaError.unsupported("a union of several schemas")
            }
            result = open
        }
        guard !nulls.isEmpty else { return result }
        guard case .object(var object) = result else {
            throw ToolConstraintSchemaError.unsupported("a nullable union branch that is not a schema object")
        }
        // oneOf: null must match exactly one branch.
        if exclusive, admitsNull(object) {
            throw ToolConstraintSchemaError.unsupported("oneOf whose branches both admit null")
        }
        object["nullable"] = .bool(true)
        if case .array(var values)? = object["enum"], !values.contains(.null) {
            values.append(.null)
            object["enum"] = .array(values)
        }
        if let constant = object.removeValue(forKey: "const") {
            object["enum"] = .array(constant == .null ? [.null] : [constant, .null])
        }
        return .object(object)
    }

    private static func isNullOnly(_ schema: StrictJSON) -> Bool {
        guard case .object(let object) = schema else { return false }
        let assertions = object.filter { !annotationKeywords.contains($0.key) }
        return assertions == ["type": .string("null")] || assertions == ["enum": .array([.null])]
            || assertions == ["const": .null]
    }

    private static func isOpenObject(_ schema: StrictJSON) -> Bool {
        guard case .object(let object) = schema else { return false }
        let assertions = object.filter { !annotationKeywords.contains($0.key) }
        guard assertions["type"] == .string("object"), assertions["additionalProperties"].map({ $0 == .bool(true) }) ?? true
        else { return false }
        if case .object(let properties)? = assertions["properties"], !properties.isEmpty { return false }
        return assertions.keys.allSatisfy { ["type", "additionalProperties", "properties"].contains($0) }
    }

    private static func admitsNull(_ object: [String: StrictJSON]) -> Bool {
        if object["nullable"] == .bool(true) { return true }
        if case .array(let types)? = object["type"], types.contains(.string("null")) { return true }
        if case .array(let values)? = object["enum"], values.contains(.null) { return true }
        return object["const"] == .null
    }
}

private extension MLXLMCommon.JSONValue {
    var objectValue: [String: MLXLMCommon.JSONValue]? {
        if case .object(let object) = self { return object }
        return nil
    }
}
