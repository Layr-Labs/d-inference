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

private indirect enum JSONSchemaValueIdentity: Hashable {
    case null
    case bool(Bool)
    case string([UInt32])
    case integer(Int)
    case floating(UInt64)
    case array([JSONSchemaValueIdentity])
    case object([JSONSchemaValueIdentity])
}

enum ToolConstraintValidation {
    private static let maxSafePatternBytes = 128
    private static let maxSafePatternCount = 32
    private static let maxSafePatternInputBytes = 16 * 1024
    private static let exactDoubleIntegerLimit = 9_007_199_254_740_992.0

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

    static func validateAutoSchemas(
        _ tools: [OpenAITool]?,
        allowInternalSchemaMetadata: Bool = true
    ) throws {
        for tool in tools ?? [] {
            guard let parameters = tool.function.parameters else { continue }
            guard autoSchemaIsSupported(
                parameters,
                depth: 0,
                allowInternalSchemaMetadata: allowInternalSchemaMetadata)
            else {
                throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                    "auto tool schema uses unsupported assertions or reserved metadata"
                )
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
            guard value.isFinite,
                abs(value) < exactDoubleIntegerLimit,
                let integer = Int(exactly: value)
            else { return false }
            return allowed?.contains(integer) ?? true
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
        if object["type"] == .string("string"),
            case .bool(let accepts)? =
                object[ToolSchemaNormalization.originalBooleanSchemaKey],
            object.keys.allSatisfy({
                $0 == "type"
                    || $0 == ToolSchemaNormalization.originalBooleanSchemaKey
                    || renderOnlyAnnotationKeys.contains($0)
            })
        {
            return accepts
        }

        if let constant = object["const"],
            !jsonSchemaEqual(value, constant)
        {
            return false
        }
        if case .array(let values)? = object["enum"],
            !values.contains(where: { jsonSchemaEqual(value, $0) })
        {
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
            // Property names compare by Unicode scalar sequence: Swift
            // dictionary lookup uses canonical equivalence, but JSON Schema
            // treats a precomposed declared "é" and a generated decomposed
            // "e\u{301}" key as DISTINCT names — the latter is an additional
            // property and does not satisfy `required`.
            let presentKeys = Set(values.keys.map(unicodeScalarIdentity))
            if case .array(let required)? = object["required"] {
                for member in required {
                    guard case .string(let name) = member,
                        presentKeys.contains(unicodeScalarIdentity(name))
                    else {
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
            let declared: [[UInt32]: ToolArgumentJSONValue] = Dictionary(
                properties.map { (unicodeScalarIdentity($0.key), $0.value) },
                uniquingKeysWith: { first, _ in first })
            let patterns: [String: ToolArgumentJSONValue]
            if case .object(let raw)? = object["patternProperties"] {
                patterns = raw
            } else {
                patterns = [:]
            }
            guard patterns.count <= maxSafePatternCount else { return false }
            for (name, child) in values {
                let nameIdentity = unicodeScalarIdentity(name)
                if let schema = declared[nameIdentity],
                    !validateJSONSchema(child, schema: schema, depth: depth + 1)
                {
                    return false
                }
                let matching = patterns.filter { safePatternMatches(name, pattern: $0.key) }
                if matching.contains(where: {
                    !validateJSONSchema(child, schema: $0.value, depth: depth + 1)
                }) {
                    return false
                }
                if declared[nameIdentity] == nil, matching.isEmpty,
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
            let legacyTuple: [ToolArgumentJSONValue]?
            if prefix.isEmpty, case .array(let schemas)? = object["items"] {
                legacyTuple = schemas
            } else {
                legacyTuple = nil
            }
            for (index, child) in values.enumerated() {
                let childSchema: ToolArgumentJSONValue?
                if index < prefix.count {
                    childSchema = prefix[index]
                } else if let legacyTuple {
                    childSchema = index < legacyTuple.count
                        ? legacyTuple[index]
                        : object["additionalItems"]
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
            if object["uniqueItems"] == .bool(true),
                Set(values.map(jsonSchemaIdentity)).count != values.count
            {
                return false
            }
            if let contains = object["contains"] {
                var minimum = 1
                if let raw = object["minContains"] {
                    guard let value = countBound(raw), value >= 0 else { return false }
                    minimum = value
                }
                var maximum: Int?
                if let raw = object["maxContains"] {
                    guard let value = countBound(raw), value >= 0 else { return false }
                    maximum = value
                }
                let matches = values.reduce(into: 0) { count, child in
                    if validateJSONSchema(
                        child, schema: contains, depth: depth + 1)
                    {
                        count += 1
                    }
                }
                if matches < minimum || maximum.map({ matches > $0 }) == true {
                    return false
                }
            }
            return true

        case .string(let string):
            if !countWithinBounds(
                string.unicodeScalars.count, minimum: object["minLength"],
                maximum: object["maxLength"])
            {
                return false
            }
            if case .string(let pattern)? = object["pattern"],
                !safePatternMatches(string, pattern: pattern)
            {
                return false
            }
            return true

        case .int:
            return validateNumber(value, object: object)
        case .double(let number):
            return number.isFinite && validateNumber(value, object: object)
        case .null, .bool:
            return true
        }
    }

    /// Linear-time subset for post-generation `auto` validation. Foundation's
    /// backtracking regex engine can spend unbounded CPU on user-controlled
    /// schemas. Literal contains/prefix/suffix/exact patterns cover the common
    /// JSON-Schema cases while regex metacharacters fail closed.
    ///
    /// Comparison is by Unicode scalar sequence: Swift `String` equality and
    /// prefix/suffix/contains use canonical equivalence, but JSON Schema regex
    /// matching does not normalize, so a precomposed `^é$` must not match a
    /// generated decomposed `e\u{301}`.
    private static func safePatternMatches(
        _ value: String,
        pattern: String
    ) -> Bool {
        guard value.utf8.count <= maxSafePatternInputBytes,
            let components = safePatternComponents(pattern)
        else { return false }
        let candidate = unicodeScalarIdentity(value)
        let literal = unicodeScalarIdentity(components.literal)
        switch (components.anchoredStart, components.anchoredEnd) {
        case (true, true):
            return candidate == literal
        case (true, false):
            return candidate.starts(with: literal)
        case (false, true):
            return candidate.suffix(literal.count).elementsEqual(literal)
        case (false, false):
            return scalarSequenceContains(candidate, literal)
        }
    }

    /// Bounded naive substring search over Unicode scalars: the literal is at
    /// most 128 pattern bytes and the candidate at most 16 KiB, so the worst
    /// case stays small and allocation-free.
    private static func scalarSequenceContains(
        _ candidate: [UInt32],
        _ literal: [UInt32]
    ) -> Bool {
        guard !literal.isEmpty else { return true }
        guard candidate.count >= literal.count else { return false }
        for start in 0 ... (candidate.count - literal.count) {
            if candidate[start ..< start + literal.count].elementsEqual(literal) {
                return true
            }
        }
        return false
    }

    private static func autoSchemaIsSupported(
        _ schema: ToolArgumentJSONValue,
        depth: Int,
        allowInternalSchemaMetadata: Bool
    ) -> Bool {
        guard depth <= 32 else { return false }
        switch schema {
        case .array(let values):
            return values.allSatisfy {
                autoSchemaIsSupported(
                    $0,
                    depth: depth + 1,
                    allowInternalSchemaMetadata: allowInternalSchemaMetadata)
            }
        case .object(let object):
            if !allowInternalSchemaMetadata,
                object[ToolSchemaNormalization.originalBooleanSchemaKey] != nil
            {
                return false
            }
            if object["$ref"] != nil
                || object["$dynamicRef"] != nil
                || object["$recursiveRef"] != nil
                || object["if"] != nil
                || object["then"] != nil
                || object["else"] != nil
                || object["dependentSchemas"] != nil
                || object["dependentRequired"] != nil
                || object["dependencies"] != nil
                || object["propertyNames"] != nil
                || object["unevaluatedItems"] != nil
                || object["unevaluatedProperties"] != nil
            {
                return false
            }
            if !autoFiniteNumberIdentityIsExact(object) {
                return false
            }
            // Mixed-type const/enum or mixed-family assertions on a typeless
            // node have no single renderable type; normalization would
            // silently break every member outside its picked type. Mirrors
            // the multi-type union policy.
            if object["type"] == nil {
                if let concrete = finiteAutoValueTypes(object) {
                    if concrete.count > 1 { return false }
                } else if typelessAssertionFamiliesAmbiguous(object) {
                    return false
                }
            }
            if case .array(let rawTypes)? = object["type"] {
                var concrete = Set<String>()
                for rawType in rawTypes {
                    guard case .string(let rawType) = rawType else { return false }
                    if rawType.lowercased() != "null" {
                        concrete.insert(rawType.lowercased())
                    }
                }
                if concrete.count > 1 { return false }
            }
            for keyword in ["anyOf", "oneOf"] {
                guard case .array(let variants)? = object[keyword] else { continue }
                var concrete = Set<String>()
                for variant in variants {
                    guard case .object(let variant) = variant else { return false }
                    let declared = schemaTypes(variant["type"])
                    if declared.isEmpty { return false }
                    let members = declared
                        .filter { $0 != "null" }
                    concrete.formUnion(members)
                }
                if concrete.count > 1 { return false }
            }
            if let pattern = object["pattern"] {
                guard case .string(let pattern) = pattern,
                    safePatternComponents(pattern) != nil
                else { return false }
            }
            if let patternProperties = object["patternProperties"] {
                guard case .object(let patterns) = patternProperties,
                    patterns.count <= maxSafePatternCount,
                    patterns.keys.allSatisfy({
                        safePatternComponents($0) != nil
                    })
                else { return false }
            }
            for key in [
                "additionalProperties", "additionalItems", "contains", "contentSchema",
                "if", "then", "else", "not", "propertyNames",
                "unevaluatedItems", "unevaluatedProperties",
            ] {
                if let child = object[key],
                    !autoSchemaIsSupported(
                        child,
                        depth: depth + 1,
                        allowInternalSchemaMetadata: allowInternalSchemaMetadata)
                {
                    return false
                }
            }
            for key in ["allOf", "anyOf", "oneOf", "prefixItems"] {
                if case .array(let children)? = object[key],
                    !children.allSatisfy({
                        autoSchemaIsSupported(
                            $0,
                            depth: depth + 1,
                            allowInternalSchemaMetadata: allowInternalSchemaMetadata)
                    })
                {
                    return false
                }
            }
            if let items = object["items"] {
                if case .array(let tuple) = items {
                    if !tuple.allSatisfy({
                        autoSchemaIsSupported(
                            $0,
                            depth: depth + 1,
                            allowInternalSchemaMetadata: allowInternalSchemaMetadata)
                    }) {
                        return false
                    }
                } else if !autoSchemaIsSupported(
                    items,
                    depth: depth + 1,
                    allowInternalSchemaMetadata: allowInternalSchemaMetadata)
                {
                    return false
                }
            }
            for key in [
                "properties", "patternProperties", "definitions", "$defs",
            ] {
                if case .object(let children)? = object[key],
                    !children.values.allSatisfy({
                        autoSchemaIsSupported(
                            $0,
                            depth: depth + 1,
                            allowInternalSchemaMetadata: allowInternalSchemaMetadata)
                    })
                {
                    return false
                }
            }
            return true
        default:
            return true
        }
    }

    private static func autoFiniteNumberIdentityIsExact(
        _ schema: [String: ToolArgumentJSONValue]
    ) -> Bool {
        var values: [ToolArgumentJSONValue] = []
        if let constant = schema["const"] {
            values.append(constant)
        }
        if case .array(let enumeration)? = schema["enum"] {
            values.append(contentsOf: enumeration)
        }
        return values.allSatisfy {
            switch $0 {
            case .double(let value):
                value.isFinite
                    && value.rounded() == value
                    && abs(value) < exactDoubleIntegerLimit
            default:
                true
            }
        }
    }

    /// Whether a typeless node's assertions cannot determine a single
    /// renderable type: either its assertion keywords span more than one type
    /// family (e.g. `{"minimum":5,"minLength":2}`) or its only assertion is
    /// `not` (e.g. `{"not":{"type":"string"}}`, which accepts every
    /// non-string — no injected type can preserve that, and the string
    /// default would make the schema unsatisfiable). Structural, union, or
    /// finite-value evidence takes priority.
    private static func typelessAssertionFamiliesAmbiguous(
        _ object: [String: ToolArgumentJSONValue]
    ) -> Bool {
        for key in [
            "properties", "patternProperties", "additionalProperties",
            "items", "prefixItems",
        ] where object[key] != nil {
            return false
        }
        for key in ["anyOf", "oneOf", "allOf"] {
            guard case .array(let variants)? = object[key] else { continue }
            let hasConcreteMember = variants.contains { variant in
                if case .object(let variant) = variant,
                    case .string(let kind)? = variant["type"],
                    kind != "null"
                {
                    return true
                }
                return false
            }
            if hasConcreteMember { return false }
        }
        var families = Set<String>()
        for (keyword, family) in ToolSchemaNormalization.assertionFamilyByKeyword
        where object[keyword] != nil {
            families.insert(family)
        }
        if families.count > 1 { return true }
        return families.isEmpty && object["not"] != nil
    }

    /// Concrete (non-null) JSON type names of a node's const/enum values.
    /// nil when the node carries no const and no enum array.
    private static func finiteAutoValueTypes(
        _ object: [String: ToolArgumentJSONValue]
    ) -> Set<String>? {
        let values: [ToolArgumentJSONValue]
        if let constant = object["const"] {
            values = [constant]
        } else if case .array(let members)? = object["enum"] {
            values = members
        } else {
            return nil
        }
        var concrete = Set<String>()
        for value in values {
            switch value {
            case .null:
                continue
            case .bool:
                concrete.insert("boolean")
            case .int, .double:
                concrete.insert("number")
            case .string:
                concrete.insert("string")
            case .array:
                concrete.insert("array")
            case .object:
                concrete.insert("object")
            }
        }
        return concrete
    }

    private static func safePatternComponents(
        _ pattern: String
    ) -> (anchoredStart: Bool, anchoredEnd: Bool, literal: String)? {
        guard pattern.utf8.count <= maxSafePatternBytes else { return nil }
        var literal = pattern[...]
        let anchoredStart = literal.first == "^"
        if anchoredStart { literal.removeFirst() }
        let anchoredEnd = literal.last == "$"
        if anchoredEnd { literal.removeLast() }
        let regexMetacharacters = CharacterSet(charactersIn: #"\\.^$|?*+()[]{}"#)
        guard literal.unicodeScalars.allSatisfy({
            !regexMetacharacters.contains($0)
        }) else { return nil }
        return (anchoredStart, anchoredEnd, String(literal))
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

    private static func jsonSchemaEqual(
        _ lhs: ToolArgumentJSONValue,
        _ rhs: ToolArgumentJSONValue
    ) -> Bool {
        jsonSchemaIdentity(lhs) == jsonSchemaIdentity(rhs)
    }

    private static func jsonSchemaIdentity(
        _ value: ToolArgumentJSONValue
    ) -> JSONSchemaValueIdentity {
        switch value {
        case .null:
            return .null
        case .bool(let value):
            return .bool(value)
        case .string(let value):
            return .string(unicodeScalarIdentity(value))
        case .int(let value):
            return .integer(value)
        case .double(let value):
            if value.isFinite, let integer = Int(exactly: value) {
                return .integer(integer)
            }
            return .floating(value.bitPattern)
        case .array(let values):
            return .array(values.map(jsonSchemaIdentity))
        case .object(let object):
            let keys = object.keys.sorted {
                unicodeScalarIdentity($0).lexicographicallyPrecedes(
                    unicodeScalarIdentity($1))
            }
            return .object(keys.flatMap {
                [.string(unicodeScalarIdentity($0)), jsonSchemaIdentity(object[$0]!)]
            })
        }
    }

    private static func unicodeScalarIdentity(_ value: String) -> [UInt32] {
        value.unicodeScalars.map(\.value)
    }

    private static func countWithinBounds(
        _ count: Int,
        minimum: ToolArgumentJSONValue?,
        maximum: ToolArgumentJSONValue?
    ) -> Bool {
        if let minimum = countBound(minimum), count < minimum { return false }
        if let maximum = countBound(maximum), count > maximum { return false }
        return true
    }

    private static let renderOnlyAnnotationKeys: Set<String> = [
        "$anchor", "$comment", "$id", "$schema", "default", "deprecated",
        "description", "examples", "readOnly", "title", "writeOnly",
    ]

    /// JSON Schema treats numbers with zero fractional part as integers, so
    /// count bounds like `minLength: 1.0` are valid and must be enforced —
    /// not silently ignored because they decode as `.double`.
    private static func countBound(_ raw: ToolArgumentJSONValue?) -> Int? {
        switch raw {
        case .int(let value)?:
            return value
        case .double(let value)? where value.isFinite:
            return Int(exactly: value)
        default:
            return nil
        }
    }

    private static func validateNumber(
        _ value: ToolArgumentJSONValue,
        object: [String: ToolArgumentJSONValue]
    ) -> Bool {
        guard compareNumbers(value, value) != nil else { return false }
        if let minimum = object["minimum"],
            let comparison = compareNumbers(value, minimum)
        {
            let exclusive = object["exclusiveMinimum"] == .bool(true)
            if exclusive
                ? comparison != .orderedDescending
                : comparison == .orderedAscending
            {
                return false
            }
        }
        if let maximum = object["maximum"],
            let comparison = compareNumbers(value, maximum)
        {
            let exclusive = object["exclusiveMaximum"] == .bool(true)
            if exclusive
                ? comparison != .orderedAscending
                : comparison == .orderedDescending
            {
                return false
            }
        }
        if let minimum = object["exclusiveMinimum"],
            let comparison = compareNumbers(value, minimum),
            comparison != .orderedDescending
        {
            return false
        }
        if let maximum = object["exclusiveMaximum"],
            let comparison = compareNumbers(value, maximum),
            comparison != .orderedAscending
        {
            return false
        }
        if let multiple = object["multipleOf"] {
            guard isMultiple(value, of: multiple) == true else { return false }
        }
        return true
    }

    private static func isMultiple(
        _ value: ToolArgumentJSONValue,
        of multiple: ToolArgumentJSONValue
    ) -> Bool? {
        guard let multipleNumber = number(multiple),
            multipleNumber.isFinite,
            multipleNumber > 0,
            let valueDecimal = jsonDecimalMagnitude(value),
            let multipleDecimal = jsonDecimalMagnitude(multiple),
            multipleDecimal.coefficient > 0
        else {
            return nil
        }
        if valueDecimal.coefficient == 0 { return true }
        return decimalRatioIsInteger(valueDecimal, multipleDecimal)
    }

    private struct JSONDecimalMagnitude {
        var coefficient: UInt64
        var exponent: Int
    }

    /// Swift's JSON number representation keeps integers exact and stores
    /// non-integers as Double. A Double's shortest round-tripping String is its
    /// canonical decoded JSON decimal value, so divisibility can be checked as
    /// coefficient × 10^exponent without binary floating-point tolerance.
    private static func jsonDecimalMagnitude(
        _ value: ToolArgumentJSONValue
    ) -> JSONDecimalMagnitude? {
        switch value {
        case .int(let value):
            var coefficient = UInt64(value.magnitude)
            var exponent = 0
            while coefficient > 0, coefficient.isMultiple(of: 10) {
                coefficient /= 10
                exponent += 1
            }
            return .init(coefficient: coefficient, exponent: exponent)
        case .double(let value):
            guard value.isFinite else { return nil }
            return parseJSONDecimalMagnitude(String(abs(value)))
        default:
            return nil
        }
    }

    private static func parseJSONDecimalMagnitude(
        _ decimal: String
    ) -> JSONDecimalMagnitude? {
        let parts = decimal.lowercased().split(
            separator: "e",
            maxSplits: 1,
            omittingEmptySubsequences: false)
        guard let mantissa = parts.first else { return nil }
        let explicitExponent =
            parts.count == 2 ? Int(parts[1]) : 0
        guard let explicitExponent else { return nil }
        let mantissaParts = mantissa.split(
            separator: ".",
            maxSplits: 1,
            omittingEmptySubsequences: false)
        let fractionalDigits = mantissaParts.count == 2
            ? mantissaParts[1].count
            : 0
        let digits = mantissaParts.joined()
        guard var coefficient = UInt64(digits) else { return nil }
        var exponent = explicitExponent - fractionalDigits
        while coefficient > 0, coefficient.isMultiple(of: 10) {
            coefficient /= 10
            exponent += 1
        }
        return .init(coefficient: coefficient, exponent: exponent)
    }

    private static func decimalRatioIsInteger(
        _ numerator: JSONDecimalMagnitude,
        _ denominator: JSONDecimalMagnitude
    ) -> Bool {
        let common = greatestCommonDivisor(
            numerator.coefficient,
            denominator.coefficient)
        var reducedNumerator = numerator.coefficient / common
        var reducedDenominator = denominator.coefficient / common
        let exponentDifference = numerator.exponent - denominator.exponent

        if exponentDifference >= 0 {
            for _ in 0 ..< exponentDifference
            where reducedDenominator.isMultiple(of: 2) {
                reducedDenominator /= 2
            }
            for _ in 0 ..< exponentDifference
            where reducedDenominator.isMultiple(of: 5) {
                reducedDenominator /= 5
            }
            return reducedDenominator == 1
        }

        guard reducedDenominator == 1 else { return false }
        let requiredPower = -exponentDifference
        var twos = 0
        while reducedNumerator > 0, reducedNumerator.isMultiple(of: 2) {
            reducedNumerator /= 2
            twos += 1
        }
        var fives = 0
        while reducedNumerator > 0, reducedNumerator.isMultiple(of: 5) {
            reducedNumerator /= 5
            fives += 1
        }
        return twos >= requiredPower && fives >= requiredPower
    }

    private static func greatestCommonDivisor(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        var lhs = lhs
        var rhs = rhs
        while rhs != 0 {
            (lhs, rhs) = (rhs, lhs % rhs)
        }
        return lhs
    }

    private static func compareNumbers(
        _ lhs: ToolArgumentJSONValue,
        _ rhs: ToolArgumentJSONValue
    ) -> ComparisonResult? {
        switch (lhs, rhs) {
        case (.int(let lhs), .int(let rhs)):
            return compareIntegers(lhs, rhs)
        case (.double(let lhs), .double(let rhs)):
            guard lhs.isFinite, rhs.isFinite else { return nil }
            if lhs < rhs { return .orderedAscending }
            if lhs > rhs { return .orderedDescending }
            return .orderedSame
        case (.int(let lhs), .double(let rhs)):
            return compareInteger(lhs, to: rhs)
        case (.double(let lhs), .int(let rhs)):
            guard let inverse = compareInteger(rhs, to: lhs) else { return nil }
            switch inverse {
            case .orderedAscending:
                return .orderedDescending
            case .orderedDescending:
                return .orderedAscending
            case .orderedSame:
                return .orderedSame
            }
        default:
            return nil
        }
    }

    private static func compareInteger(
        _ lhs: Int,
        to rhs: Double
    ) -> ComparisonResult? {
        guard rhs.isFinite else { return nil }
        if let rhs = Int(exactly: rhs) {
            return compareIntegers(lhs, rhs)
        }
        if rhs >= Double(Int.max) {
            return .orderedAscending
        }
        if rhs < Double(Int.min) {
            return .orderedDescending
        }
        let truncated = Int(rhs)
        if lhs < truncated { return .orderedAscending }
        if lhs > truncated { return .orderedDescending }
        return Double(lhs) < rhs ? .orderedAscending : .orderedDescending
    }

    private static func compareIntegers(
        _ lhs: Int,
        _ rhs: Int
    ) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
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
