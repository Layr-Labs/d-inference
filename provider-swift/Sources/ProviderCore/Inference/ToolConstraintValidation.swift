// Copyright © 2026 Eigen Labs.
//
// Post-parse validation shared by auto and constrained tool output. Constrained
// decoding makes failures unreachable in the supported grammar; retaining the
// validator is defense in depth and the compatibility boundary for historical
// unconstrained auto output.

import Foundation
import MLXLMCommon
import MLXLMServer

private typealias ToolArgumentJSONValue = MLXLMCommon.JSONValue

enum ToolConstraintValidation {
    static func validate(
        _ calls: [ToolCall],
        prepared: ToolChoicePromptPolicy.Prepared
    ) throws {
        if !prepared.allowsParallelCalls, calls.count > 1 {
            throw violation("parallel tool calls are disabled for this request")
        }
        switch prepared.mode {
        case .none:
            guard calls.isEmpty else {
                throw violation("tool_choice none prohibited a tool call")
            }
        case .required:
            guard !calls.isEmpty else {
                throw violation("model did not emit the required tool call")
            }
        case .named(let expected):
            guard !calls.isEmpty,
                calls.allSatisfy({ $0.function.name == expected })
            else {
                throw violation("model did not emit the named tool call")
            }
        case .auto:
            break
        }

        let allowed = prepared.allowedToolNames
        guard calls.allSatisfy({ allowed.contains($0.function.name) }) else {
            throw violation("model emitted an undeclared tool call")
        }
        if let schemas = prepared.compiledTools {
            let byName = Dictionary(
                uniqueKeysWithValues: schemas.map { ($0.name, $0.parameters) })
            for call in calls {
                guard let schema = byName[call.function.name],
                    validate(.object(call.function.arguments), against: schema)
                else {
                    throw violation("tool call arguments do not satisfy the declared schema")
                }
            }
        } else {
            let byName = Dictionary(
                uniqueKeysWithValues: (prepared.tools ?? []).map {
                    ($0.function.name, $0.function.parameters)
                })
            for call in calls {
                guard let raw = byName[call.function.name] else {
                    throw violation("model emitted an undeclared tool call")
                }
                guard let schema = raw else { continue }
                guard validateJSONSchema(
                    .object(call.function.arguments), schema: schema, depth: 0)
                else {
                    throw violation("tool call arguments do not satisfy the declared schema")
                }
            }
        }
    }

    private static func violation(
        _ message: String
    ) -> MultiModelBatchSchedulerEngineError {
        .toolChoiceViolation(message)
    }

    private static func validate(
        _ value: ToolArgumentJSONValue,
        against schema: ToolValueSchema
    ) -> Bool {
        if value == .null { return schema.nullable }
        switch (schema, value) {
        case (.object(let properties, let allowsAdditional, _), .object(let object)):
            let byName = Dictionary(
                uniqueKeysWithValues: properties.map { ($0.name, $0) })
            for property in properties where property.required && object[property.name] == nil {
                return false
            }
            for (name, value) in object {
                guard let property = byName[name] else {
                    if !allowsAdditional { return false }
                    continue
                }
                if !validate(value, against: property.schema) { return false }
            }
            return true
        case (
            .array(let items, let minItems, let maxItems, _),
            .array(let values)
        ):
            guard values.count >= minItems,
                maxItems.map({ values.count <= $0 }) ?? true
            else { return false }
            return values.allSatisfy { validate($0, against: items) }
        case (.string(let allowed, _), .string(let value)):
            return allowed?.contains(value) ?? true
        case (.boolean(let allowed, _), .bool(let value)):
            return allowed?.contains(value) ?? true
        case (.integer(let allowed, _), .int(let value)):
            return allowed?.contains(value) ?? true
        case (.integer(let allowed, _), .double(let value)):
            guard value.isFinite, value.rounded() == value else { return false }
            return allowed?.contains(where: { Double($0) == value }) ?? true
        case (.number(let allowed, _), .int(let value)):
            return allowed?.contains(Double(value)) ?? true
        case (.number(let allowed, _), .double(let value)):
            return value.isFinite && (allowed?.contains(value) ?? true)
        case (.null, .null):
            return true
        default:
            return false
        }
    }

    /// Broader validation path for unconstrained `auto`. Required/named use
    /// the smaller grammar subset above; auto remains model-selected but its
    /// parsed call must still satisfy common JSON-Schema assertions.
    private static func validateJSONSchema(
        _ value: ToolArgumentJSONValue,
        schema: ToolArgumentJSONValue,
        depth: Int
    ) -> Bool {
        guard depth <= 32 else { return false }
        if case .bool(let accepts) = schema { return accepts }
        guard case .object(let object) = schema else { return false }

        if let constant = object["const"], value != constant { return false }
        if case .array(let values)? = object["enum"], !values.contains(value) {
            return false
        }
        if case .array(let variants)? = object["allOf"],
            !variants.allSatisfy({
                validateJSONSchema(value, schema: $0, depth: depth + 1)
            })
        {
            return false
        }
        if case .array(let variants)? = object["anyOf"],
            !variants.contains(where: {
                validateJSONSchema(value, schema: $0, depth: depth + 1)
            })
        {
            return false
        }
        if case .array(let variants)? = object["oneOf"],
            variants.filter({
                validateJSONSchema(value, schema: $0, depth: depth + 1)
            }).count != 1
        {
            return false
        }
        if let negated = object["not"],
            validateJSONSchema(value, schema: negated, depth: depth + 1)
        {
            return false
        }

        if value == .null,
            object["nullable"] == .bool(true)
                || schemaTypes(object["type"]).contains("null")
        {
            return true
        }
        let types = schemaTypes(object["type"])
        if !types.isEmpty, !types.contains(where: { matches(value, type: $0) }) {
            return false
        }

        switch value {
        case .object(let values):
            if case .array(let required)? = object["required"] {
                for member in required {
                    guard case .string(let name) = member, values[name] != nil else {
                        return false
                    }
                }
            }
            let properties: [String: ToolArgumentJSONValue]
            if case .object(let raw)? = object["properties"] {
                properties = raw
            } else {
                properties = [:]
            }
            let patterns: [String: ToolArgumentJSONValue]
            if case .object(let raw)? = object["patternProperties"] {
                patterns = raw
            } else {
                patterns = [:]
            }
            for (name, child) in values {
                if let schema = properties[name],
                    !validateJSONSchema(child, schema: schema, depth: depth + 1)
                {
                    return false
                }
                let matching = patterns.filter {
                    name.range(of: $0.key, options: .regularExpression) != nil
                }
                if matching.contains(where: {
                    !validateJSONSchema(child, schema: $0.value, depth: depth + 1)
                }) {
                    return false
                }
                if properties[name] == nil, matching.isEmpty,
                    let additional = object["additionalProperties"],
                    !validateJSONSchema(child, schema: additional, depth: depth + 1)
                {
                    return false
                }
            }
            return countWithinBounds(
                values.count, minimum: object["minProperties"],
                maximum: object["maxProperties"])

        case .array(let values):
            if !countWithinBounds(
                values.count, minimum: object["minItems"],
                maximum: object["maxItems"])
            {
                return false
            }
            let prefix: [ToolArgumentJSONValue]
            if case .array(let schemas)? = object["prefixItems"] {
                prefix = schemas
            } else {
                prefix = []
            }
            let legacyTuple: [ToolArgumentJSONValue]
            if prefix.isEmpty, case .array(let schemas)? = object["items"] {
                legacyTuple = schemas
            } else {
                legacyTuple = []
            }
            for (index, child) in values.enumerated() {
                let childSchema: ToolArgumentJSONValue?
                if index < prefix.count {
                    childSchema = prefix[index]
                } else if index < legacyTuple.count {
                    childSchema = legacyTuple[index]
                } else if !legacyTuple.isEmpty {
                    childSchema = object["additionalItems"]
                } else if let items = object["items"] {
                    childSchema = items
                } else {
                    childSchema = nil
                }
                if let childSchema,
                    !validateJSONSchema(
                        child, schema: childSchema, depth: depth + 1)
                {
                    return false
                }
            }
            if object["uniqueItems"] == .bool(true), Set(values).count != values.count {
                return false
            }
            return true

        case .string(let string):
            if !countWithinBounds(
                string.count, minimum: object["minLength"],
                maximum: object["maxLength"])
            {
                return false
            }
            if case .string(let pattern)? = object["pattern"],
                string.range(of: pattern, options: .regularExpression) == nil
            {
                return false
            }
            return true

        case .int(let integer):
            return validateNumber(Double(integer), object: object)
        case .double(let number):
            return number.isFinite && validateNumber(number, object: object)
        case .null, .bool:
            return true
        }
    }

    private static func schemaTypes(
        _ raw: ToolArgumentJSONValue?
    ) -> Set<String> {
        switch raw {
        case .string(let type):
            [type.lowercased()]
        case .array(let values):
            Set(values.compactMap {
                if case .string(let type) = $0 { return type.lowercased() }
                return nil
            })
        default:
            []
        }
    }

    private static func matches(
        _ value: ToolArgumentJSONValue,
        type: String
    ) -> Bool {
        switch (type, value) {
        case ("null", .null), ("boolean", .bool), ("object", .object),
            ("array", .array), ("string", .string), ("integer", .int),
            ("number", .int), ("number", .double):
            true
        case ("integer", .double(let number)):
            number.isFinite && number.rounded() == number
        default:
            false
        }
    }

    private static func countWithinBounds(
        _ count: Int,
        minimum: ToolArgumentJSONValue?,
        maximum: ToolArgumentJSONValue?
    ) -> Bool {
        if case .int(let minimum)? = minimum, count < minimum { return false }
        if case .int(let maximum)? = maximum, count > maximum { return false }
        return true
    }

    private static func validateNumber(
        _ value: Double,
        object: [String: ToolArgumentJSONValue]
    ) -> Bool {
        if let minimum = number(object["minimum"]), value < minimum { return false }
        if let maximum = number(object["maximum"]), value > maximum { return false }
        if let minimum = number(object["exclusiveMinimum"]), value <= minimum { return false }
        if let maximum = number(object["exclusiveMaximum"]), value >= maximum { return false }
        if let multiple = number(object["multipleOf"]), multiple > 0 {
            let quotient = value / multiple
            if abs(quotient - quotient.rounded()) > 1e-9 { return false }
        }
        return true
    }

    private static func number(
        _ value: ToolArgumentJSONValue?
    ) -> Double? {
        switch value {
        case .int(let value): Double(value)
        case .double(let value): value
        default: nil
        }
    }
}
