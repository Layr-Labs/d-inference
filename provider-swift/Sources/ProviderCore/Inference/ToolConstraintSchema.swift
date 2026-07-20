// Copyright © 2026 Eigen Labs.
//
// Fail-closed JSON-Schema subset used by Gemma inference-time tool grammar.
// The subset is intentionally small and exact. Unsupported assertion keywords
// are rejected for required/named choices instead of being prompt-only theater.

import Foundation
import MLXLMCommon
import MLXLMServer

private typealias SchemaJSONValue = MLXLMCommon.JSONValue

enum ToolConstraintMode: Sendable, Equatable {
    case none
    case auto
    case required
    case named(String)

    var requiresInferenceGrammar: Bool {
        switch self {
        case .none, .required, .named: true
        case .auto: false
        }
    }

    var telemetryValue: String {
        switch self {
        case .none: "none"
        case .auto: "auto"
        case .required: "required"
        case .named: "named"
        }
    }
}

struct CompiledToolSchema: Sendable {
    let name: String
    let parameters: ToolValueSchema
}

indirect enum ToolValueSchema: Sendable {
    struct Property: Sendable {
        let name: String
        let schema: ToolValueSchema
        let required: Bool
    }

    case object(properties: [Property], allowsAdditional: Bool, nullable: Bool)
    case array(items: ToolValueSchema, minItems: Int, maxItems: Int?, nullable: Bool)
    case string(values: [String]?, nullable: Bool)
    case boolean(values: [Bool]?, nullable: Bool)
    case integer(values: [Int]?, nullable: Bool)
    case number(values: [Double]?, nullable: Bool)
    case null

    var nullable: Bool {
        switch self {
        case .object(_, _, let nullable),
            .array(_, _, _, let nullable),
            .string(_, let nullable),
            .boolean(_, let nullable),
            .integer(_, let nullable),
            .number(_, let nullable):
            nullable
        case .null:
            true
        }
    }
}

enum ToolConstraintSchemaError: LocalizedError, Equatable {
    case invalid(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let detail):
            "invalid tool constraint schema: \(detail)"
        case .unsupported(let detail):
            "unsupported tool constraint schema: \(detail)"
        }
    }
}

enum ToolConstraintSchemaCompiler {
    static let maxTools = 64
    static let maxProperties = 128
    static let maxDepth = 16
    static let maxArrayItems = 16
    static let maxGrammarComplexity = 50_000

    static func compile(
        tools: [OpenAITool]?,
        mode: ToolConstraintMode
    ) throws -> [CompiledToolSchema] {
        let tools = tools ?? []
        guard tools.count <= maxTools else {
            throw ToolConstraintSchemaError.invalid("at most \(maxTools) tools are allowed")
        }
        if mode.requiresInferenceGrammar {
            switch mode {
            case .required, .named:
                guard !tools.isEmpty else {
                    throw ToolConstraintSchemaError.invalid(
                        "required tool_choice needs at least one declared function")
                }
            case .none, .auto:
                break
            }
        }

        var names = Set<String>()
        var compiled: [CompiledToolSchema] = []
        var grammarComplexity = 0
        compiled.reserveCapacity(tools.count)
        for tool in tools {
            guard tool.type == "function" else {
                throw ToolConstraintSchemaError.unsupported(
                    "only function tools can be inference-constrained")
            }
            let name = tool.function.name
            guard ToolChoicePromptPolicy.isValidFunctionName(name) else {
                throw ToolConstraintSchemaError.invalid(
                    "tool function names must match ^[a-zA-Z0-9_-]{1,64}$")
            }
            guard names.insert(name).inserted else {
                throw ToolConstraintSchemaError.invalid(
                    "tool function names must be unique")
            }
            let raw = tool.function.parameters ?? .object(["type": .string("object")])
            let schema = try compileSchema(raw, depth: 0, path: "\(name).parameters")
            guard case .object = schema else {
                throw ToolConstraintSchemaError.invalid(
                    "\(name).parameters must have type object")
            }
            grammarComplexity += name.utf8.count + grammarCost(schema)
            guard grammarComplexity <= maxGrammarComplexity else {
                throw ToolConstraintSchemaError.unsupported(
                    "combined tool grammar exceeds the \(maxGrammarComplexity)-unit safety limit")
            }
            compiled.append(CompiledToolSchema(name: name, parameters: schema))
        }

        if case .named(let selected) = mode, !names.contains(selected) {
            throw ToolConstraintSchemaError.invalid(
                "tool_choice names an undeclared function")
        }
        return compiled
    }

    private static func grammarCost(_ schema: ToolValueSchema) -> Int {
        switch schema {
        case .object(let properties, _, _):
            return properties.reduce(2) {
                min(
                    maxGrammarComplexity + 1,
                    $0 + $1.name.utf8.count + 2 + grammarCost($1.schema))
            }
        case .array(let items, _, let maxItems, _):
            let count = maxItems ?? maxArrayItems
            let (product, overflow) = (grammarCost(items) + 1)
                .multipliedReportingOverflow(by: count)
            return overflow
                ? maxGrammarComplexity + 1
                : min(maxGrammarComplexity + 1, 2 + product)
        case .string(let values, _):
            return values?.reduce(0) { $0 + $1.utf8.count + 10 } ?? 16
        case .boolean(let values, _):
            return (values?.count ?? 2) * 5
        case .integer(let values, _):
            return values?.reduce(0) { $0 + String($1).count } ?? 20
        case .number(let values, _):
            return values?.reduce(0) { $0 + String($1).count } ?? 40
        case .null:
            return 4
        }
    }

    private static func compileSchema(
        _ raw: SchemaJSONValue,
        depth: Int,
        path: String
    ) throws -> ToolValueSchema {
        guard depth <= maxDepth else {
            throw ToolConstraintSchemaError.unsupported(
                "\(path) exceeds maximum nesting depth \(maxDepth)")
        }
        guard case .object(let object) = raw else {
            throw ToolConstraintSchemaError.invalid("\(path) must be a schema object")
        }

        let supported: Set<String> = [
            "type", "properties", "required", "additionalProperties", "items",
            "minItems", "maxItems", "nullable", "enum", "const", "description",
            "title", "default", "examples", "deprecated", "readOnly", "writeOnly",
        ]
        if let keyword = object.keys.first(where: { !supported.contains($0) }) {
            throw ToolConstraintSchemaError.unsupported(
                "\(path) uses \(keyword)")
        }

        let explicitNullable = try bool(
            object["nullable"], default: false, path: "\(path).nullable")
        let (kind, typeNullable) = try schemaType(
            object, path: "\(path).type")
        let nullable = explicitNullable || typeNullable
        let enumValues = try finiteValues(object: object, path: path)

        switch kind {
        case "object":
            return try compileObject(
                object, finiteValues: enumValues, nullable: nullable,
                depth: depth, path: path)
        case "array":
            guard enumValues == nil else {
                throw ToolConstraintSchemaError.unsupported(
                    "\(path) uses enum/const on an array")
            }
            guard let items = object["items"] else {
                throw ToolConstraintSchemaError.unsupported(
                    "\(path) array requires a single items schema")
            }
            let minItems = try nonnegativeInt(
                object["minItems"], default: 0, path: "\(path).minItems")
            let maxItems = try optionalNonnegativeInt(
                object["maxItems"], path: "\(path).maxItems")
            guard minItems <= maxArrayItems,
                maxItems.map({ $0 <= maxArrayItems && $0 >= minItems }) ?? true
            else {
                throw ToolConstraintSchemaError.unsupported(
                    "\(path) array bounds must be within 0...\(maxArrayItems)")
            }
            return .array(
                items: try compileSchema(
                    items, depth: depth + 1, path: "\(path).items"),
                minItems: minItems,
                maxItems: maxItems,
                nullable: nullable)
        case "string":
            try rejectKeywords(
                object, ["pattern", "format", "minLength", "maxLength"],
                path: path)
            let values = try enumValues.map { values in
                try values.compactMap { value -> String? in
                    if value == .null, nullable { return nil }
                    guard case .string(let string) = value else {
                        throw ToolConstraintSchemaError.invalid(
                            "\(path) enum/const does not match type string")
                    }
                    return string
                }
            }
            return .string(values: values, nullable: nullable)
        case "boolean":
            let values = try enumValues.map { values in
                try values.compactMap { value -> Bool? in
                    if value == .null, nullable { return nil }
                    guard case .bool(let flag) = value else {
                        throw ToolConstraintSchemaError.invalid(
                            "\(path) enum/const does not match type boolean")
                    }
                    return flag
                }
            }
            return .boolean(values: values, nullable: nullable)
        case "integer":
            try rejectNumericAssertions(object, path: path)
            let values = try enumValues.map { values in
                try values.compactMap { value -> Int? in
                    if value == .null, nullable { return nil }
                    guard case .int(let integer) = value else {
                        throw ToolConstraintSchemaError.invalid(
                            "\(path) enum/const does not match type integer")
                    }
                    return integer
                }
            }
            return .integer(values: values, nullable: nullable)
        case "number":
            try rejectNumericAssertions(object, path: path)
            guard enumValues == nil else {
                throw ToolConstraintSchemaError.unsupported(
                    "\(path) uses enum/const on number; use integer or string for exact choices")
            }
            return .number(values: nil, nullable: nullable)
        case "null":
            guard enumValues == nil || enumValues == [.null] else {
                throw ToolConstraintSchemaError.invalid(
                    "\(path) enum/const does not match type null")
            }
            return .null
        default:
            throw ToolConstraintSchemaError.unsupported(
                "\(path) has unsupported type \(kind)")
        }
    }

    private static func compileObject(
        _ object: [String: SchemaJSONValue],
        finiteValues: [SchemaJSONValue]?,
        nullable: Bool,
        depth: Int,
        path: String
    ) throws -> ToolValueSchema {
        guard finiteValues == nil else {
            throw ToolConstraintSchemaError.unsupported(
                "\(path) uses enum/const on an object")
        }
        let rawProperties: [String: SchemaJSONValue]
        if let value = object["properties"] {
            guard case .object(let properties) = value else {
                throw ToolConstraintSchemaError.invalid(
                    "\(path).properties must be an object")
            }
            rawProperties = properties
        } else {
            rawProperties = [:]
        }
        guard rawProperties.count <= maxProperties else {
            throw ToolConstraintSchemaError.invalid(
                "\(path) has more than \(maxProperties) properties")
        }
        let required: Set<String>
        if let value = object["required"] {
            guard case .array(let values) = value else {
                throw ToolConstraintSchemaError.invalid(
                    "\(path).required must be an array")
            }
            var names = Set<String>()
            for value in values {
                guard case .string(let name) = value, rawProperties[name] != nil else {
                    throw ToolConstraintSchemaError.invalid(
                        "\(path).required contains an undeclared property")
                }
                guard names.insert(name).inserted else {
                    throw ToolConstraintSchemaError.invalid(
                        "\(path).required contains a duplicate property")
                }
            }
            required = names
        } else {
            required = []
        }

        let allowsAdditional: Bool
        if let additional = object["additionalProperties"] {
            guard case .bool(let flag) = additional else {
                throw ToolConstraintSchemaError.unsupported(
                    "\(path).additionalProperties must be boolean")
            }
            allowsAdditional = flag
        } else {
            allowsAdditional = true
        }

        var properties: [ToolValueSchema.Property] = []
        properties.reserveCapacity(rawProperties.count)
        for (name, raw) in rawProperties.sorted(by: { $0.key < $1.key }) {
            guard ToolChoicePromptPolicy.isValidFunctionName(name) else {
                throw ToolConstraintSchemaError.unsupported(
                    "\(path) property names must match ^[a-zA-Z0-9_-]{1,64}$")
            }
            properties.append(.init(
                name: name,
                schema: try compileSchema(
                    raw, depth: depth + 1, path: "\(path).properties.\(name)"),
                required: required.contains(name)))
        }
        return .object(
            properties: properties,
            allowsAdditional: allowsAdditional,
            nullable: nullable)
    }

    private static func schemaType(
        _ object: [String: SchemaJSONValue],
        path: String
    ) throws -> (String, Bool) {
        guard let value = object["type"] else {
            if object["properties"] != nil || object["additionalProperties"] != nil {
                return ("object", false)
            }
            if object["items"] != nil {
                return ("array", false)
            }
            return ("string", false)
        }
        if value == .null {
            if object["properties"] != nil || object["additionalProperties"] != nil {
                return ("object", false)
            }
            if object["items"] != nil {
                return ("array", false)
            }
            return ("string", false)
        }
        if case .string(let type) = value { return (type.lowercased(), false) }
        if case .array(let members) = value {
            let types = try members.map { member -> String in
                guard case .string(let type) = member else {
                    throw ToolConstraintSchemaError.invalid("\(path) members must be strings")
                }
                return type.lowercased()
            }
            let nonNull = types.filter { $0 != "null" }
            guard types.contains("null"), nonNull.count == 1 else {
                throw ToolConstraintSchemaError.unsupported(
                    "\(path) supports only one type plus null")
            }
            return (nonNull[0], true)
        }
        throw ToolConstraintSchemaError.invalid("\(path) must be a string")
    }

    private static func finiteValues(
        object: [String: SchemaJSONValue],
        path: String
    ) throws -> [SchemaJSONValue]? {
        if let constant = object["const"] {
            guard object["enum"] == nil else {
                throw ToolConstraintSchemaError.invalid(
                    "\(path) cannot contain both const and enum")
            }
            return [constant]
        }
        guard let raw = object["enum"] else { return nil }
        guard case .array(let values) = raw, !values.isEmpty, values.count <= 128 else {
            throw ToolConstraintSchemaError.invalid(
                "\(path).enum must contain 1...128 values")
        }
        return values
    }

    private static func rejectKeywords(
        _ object: [String: SchemaJSONValue],
        _ keys: [String],
        path: String
    ) throws {
        if let key = keys.first(where: { object[$0] != nil }) {
            throw ToolConstraintSchemaError.unsupported("\(path) uses \(key)")
        }
    }

    private static func rejectNumericAssertions(
        _ object: [String: SchemaJSONValue],
        path: String
    ) throws {
        try rejectKeywords(
            object,
            ["minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf"],
            path: path)
    }

    private static func bool(
        _ value: SchemaJSONValue?,
        default defaultValue: Bool,
        path: String
    ) throws -> Bool {
        guard let value else { return defaultValue }
        guard case .bool(let flag) = value else {
            throw ToolConstraintSchemaError.invalid("\(path) must be boolean")
        }
        return flag
    }

    private static func nonnegativeInt(
        _ value: SchemaJSONValue?,
        default defaultValue: Int,
        path: String
    ) throws -> Int {
        guard let value else { return defaultValue }
        guard case .int(let number) = value, number >= 0 else {
            throw ToolConstraintSchemaError.invalid("\(path) must be a nonnegative integer")
        }
        return number
    }

    private static func optionalNonnegativeInt(
        _ value: SchemaJSONValue?,
        path: String
    ) throws -> Int? {
        guard let value else { return nil }
        return try nonnegativeInt(value, default: 0, path: path)
    }
}
