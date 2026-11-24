// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon

/// The call parser's literal reading of a parameter's text, a mirror of the
/// SDK's `ToolArgumentNormalization` for the Qwen XML dialect (`literal`,
/// `LiteralReading.preferred`): under a schema with no single non-string type
/// (`not`, `if`/`then`/`else`, a union, no `type`), a text that spells a JSON
/// literal the schema admits becomes that literal: a number, `true`, `false`
/// or `null` (in any case, and Python's `None`) written exactly so, else
/// one with surrounding whitespace when the schema rejects the text as a
/// string. Like `parserConversion`, it reads no `$ref`: a schema that holds
/// one reads as text here.
enum QwenParserLiteralReading {
    /// The literal the parser reads `text` as under `schema`, or nil when it
    /// keeps the text. Only for a parameter `parserConversion` reads as text.
    static func literal(_ text: String, schema: [String: MLXLMCommon.JSONValue]) -> MLXLMCommon.JSONValue? {
        scalar(text, schema: schema) ?? untypedContainer(text, schema: schema)
    }

    private static func scalar(_ text: String, schema: [String: MLXLMCommon.JSONValue]) -> MLXLMCommon.JSONValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let literal = jsonLiteral(trimmed) ?? spelledLiteral(trimmed), admitsLiteralType(schema),
              admission(of: .value(literal), .object(schema), depth: 0) == .yes else { return nil }
        if trimmed == text { return literal }
        return admission(of: .value(.string(text)), .object(schema), depth: 0) == .no ? literal : nil
    }

    /// Keywords that say nothing about a value: a schema of these alone (`{}`
    /// included) declares no type.
    private static let annotationKeywords: Set<String> = [
        "description", "title", "default", "examples", "$comment", "deprecated", "readOnly", "writeOnly",
    ]

    /// The JSON object or array a text writes under a parameter with no
    /// declared type: only a text that parses completely as one, and whose
    /// numbers decode exactly (the SDK's `untypedContainer`).
    static func untypedContainer(_ text: String, schema: [String: MLXLMCommon.JSONValue]) -> MLXLMCommon.JSONValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" || trimmed.first == "[", schema.keys.allSatisfy(annotationKeywords.contains),
              numbersAreExact(trimmed), let data = trimmed.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let value = carried(any: parsed)
        switch value {
        case .object, .array: return value
        default: return nil
        }
    }

    /// A decoded JSON value as the SDK reads one: a boxed Boolean is a
    /// Boolean, a boxed number an integer when it is one, else a double.
    private static func carried(any value: Any) -> MLXLMCommon.JSONValue {
        switch value {
        case is NSNull: return .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            if let int = number as? Int { return .int(int) }
            return .double(number.doubleValue)
        case let string as String: return .string(string)
        case let array as [Any]: return .array(array.map { carried(any: $0) })
        case let object as [String: Any]: return .object(object.mapValues { carried(any: $0) })
        default: return .string(String(describing: value))
        }
    }

    /// Every number outside a JSON text's strings decodes exactly: an integer
    /// of at most 18 digits, or a decimal of at most 15 significant digits.
    private static func numbersAreExact(_ text: String) -> Bool {
        var inString = false
        var escaped = false
        var token = ""
        func exact(_ token: String) -> Bool {
            guard !token.isEmpty else { return true }
            let mantissa = token.prefix { $0 != "e" && $0 != "E" }
            let digits = mantissa.filter(\.isNumber).drop { $0 == "0" }
            let integral = mantissa.count == token.count && !token.contains(".")
            return digits.count <= (integral ? 18 : 15)
        }
        for character in text {
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }
            if character.isNumber || "+-.eE".contains(character) {
                token.append(character)
                continue
            }
            guard exact(token) else { return false }
            token = ""
            if character == "\"" { inString = true }
        }
        return exact(token)
    }

    /// Whether some text may read as a literal under `schema`: a number,
    /// Boolean or null it may admit. A schema this cannot decide keeps every text.
    static func admitsLiteralType(_ schema: [String: MLXLMCommon.JSONValue]) -> Bool {
        var readings: [String: Admission] = [:]
        for type in ["integer", "number", "boolean", "null", "string"] {
            let reading = admission(of: .type(type), .object(schema), depth: 0)
            guard reading != .unknown else { return false }
            readings[type] = reading
        }
        return ["integer", "number", "boolean", "null"].contains { readings[$0] != .no }
    }

    /// The literal scalars in any case, and Python's `None`.
    static func spelledLiteral(_ text: String) -> MLXLMCommon.JSONValue? {
        switch text.lowercased() {
        case "true": .bool(true)
        case "false": .bool(false)
        case "null", "none": .null
        default: nil
        }
    }

    /// A scalar spelled exactly as JSON writes it: `true`, `false`, `null`
    /// or a JSON number (no sign but `-`, no leading zeros, no bare point).
    static func jsonLiteral(_ text: String) -> MLXLMCommon.JSONValue? {
        switch text {
        case "true": return .bool(true)
        case "false": return .bool(false)
        case "null": return .null
        default: break
        }
        var scalars = text.unicodeScalars[...]
        if scalars.first == "-" { scalars.removeFirst() }
        func digits() -> Int {
            let count = scalars.prefix(while: { ("0"..."9").contains($0) }).count
            scalars.removeFirst(count)
            return count
        }
        let leading = scalars.first
        let whole = digits()
        guard whole > 0, leading != "0" || whole == 1 else { return nil }
        if scalars.first == "." {
            scalars.removeFirst()
            guard digits() > 0 else { return nil }
        }
        if scalars.first == "e" || scalars.first == "E" {
            scalars.removeFirst()
            if scalars.first == "+" || scalars.first == "-" { scalars.removeFirst() }
            guard digits() > 0 else { return nil }
        }
        guard scalars.isEmpty else { return nil }
        let value = number(text)
        if case .double(let double)? = value, !holdsExactly(text, double) { return nil }
        return value
    }

    /// Whether `double` is the number `text` writes, digit for digit, within
    /// the 38 digits a `Decimal` keeps (the SDK's `holdsExactly`).
    private static func holdsExactly(_ text: String, _ double: Double) -> Bool {
        let mantissa = text.prefix { $0 != "e" && $0 != "E" }
        let digits = mantissa.filter(\.isNumber).drop { $0 == "0" }
        let posix = Locale(identifier: "en_US_POSIX")
        guard digits.count <= 38, let written = Decimal(string: text, locale: posix),
              let read = Decimal(string: "\(double)", locale: posix) else { return false }
        return written == read
    }

    /// The SDK's number reading: an integral spelling is an integer when it
    /// fits, else a finite double.
    private static func number(_ text: String) -> MLXLMCommon.JSONValue? {
        if let value = Int(text) { return .int(value) }
        guard let value = Double(text), value.isFinite else { return nil }
        return decimalInteger(text).map(MLXLMCommon.JSONValue.int) ?? .double(value)
    }

    /// Integral decimal or exponent spellings, without floating-point rounding.
    private static func decimalInteger(_ text: String) -> Int? {
        var body = text[...]
        let negative = body.first == "-"
        if body.first == "-" || body.first == "+" { body.removeFirst() }
        let parts = body.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "e" || $0 == "E" })
        guard parts.count <= 2 else { return nil }
        let exponent: Int
        if parts.count == 2 {
            guard let parsed = Int(parts[1]) else { return nil }
            exponent = parsed
        } else {
            exponent = 0
        }
        let mantissa = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard mantissa.count <= 2 else { return nil }
        let fractionalCount = mantissa.count == 2 ? mantissa[1].count : 0
        var digits = mantissa.joined()
        guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        digits = String(digits.drop(while: { $0 == "0" }))
        if digits.isEmpty { return 0 }
        let (scale, overflow) = exponent.subtractingReportingOverflow(fractionalCount)
        guard !overflow else { return nil }
        if scale >= 0 {
            guard scale <= 19, digits.count <= 19 - scale else { return nil }
            digits += String(repeating: "0", count: scale)
        } else {
            guard scale > -digits.count, digits.suffix(-scale).allSatisfy({ $0 == "0" }) else { return nil }
            digits.removeLast(-scale)
        }
        return Int((negative ? "-" : "") + digits)
    }

    /// Whether a node's `type` is a render hint (the SDK's
    /// `ToolArgumentNormalization.rendersSiblingType`): beside `anyOf`/`oneOf`
    /// whose branches include that type, an `enum` with a member it does not
    /// admit, a `not` of that type, or an `if`/`then`/`else` branch typed
    /// otherwise. A null still needs `nullable: true` beside a hinted type.
    static func rendersSiblingType(_ schema: [String: MLXLMCommon.JSONValue]) -> Bool {
        guard case .string(let raw)? = schema["type"], let type = canonicalType(raw) else { return false }
        func typeName(_ node: MLXLMCommon.JSONValue?) -> String? {
            guard case .object(let object)? = node, case .string(let name)? = object["type"] else { return nil }
            return canonicalType(name)
        }
        for key in ["anyOf", "oneOf"] {
            if case .array(let branches)? = schema[key], branches.contains(where: { typeName($0) == type }) {
                return true
            }
        }
        if case .array(let members)? = schema["enum"],
           members.contains(where: { !typeAdmits(type, carried($0)) }) {
            return true
        }
        if schema["not"] != nil, typeName(schema["not"]) == type { return true }
        for key in ["if", "then", "else"] {
            if let name = typeName(schema[key]), name != type { return true }
        }
        return false
    }

    static func typeAdmits(_ type: String, _ value: MLXLMCommon.JSONValue) -> Bool {
        switch value {
        case .null: type == "null"
        case .bool: type == "boolean"
        case .int: type == "integer" || type == "number"
        case .double: type == "number"
        case .string: type == "string"
        case .array: type == "array"
        case .object: type == "object"
        }
    }

    /// A type name as the SDK's parser reads it, aliases included.
    static func canonicalType(_ name: String) -> String? {
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

    enum Admission { case yes, no, maybe, unknown }

    enum Probe {
        case value(MLXLMCommon.JSONValue)
        case type(String)

        var type: String {
            switch self {
            case .type(let type): type
            case .value(.null): "null"
            case .value(.bool): "boolean"
            case .value(.int): "integer"
            case .value(.double): "number"
            case .value(.string): "string"
            case .value(.array): "array"
            case .value(.object): "object"
            }
        }
    }

    /// A JSON value as the parser's tool map carries it: an integral double
    /// reads back as an integer.
    private static func carried(_ value: MLXLMCommon.JSONValue) -> MLXLMCommon.JSONValue {
        if case .double(let double) = value, double.rounded() == double, let int = Int(exactly: double) {
            return .int(int)
        }
        return value
    }

    /// The keywords that decide a scalar, as the SDK reads them; a local or
    /// dynamic reference is undecided here.
    static func admission(of probe: Probe, _ node: MLXLMCommon.JSONValue, depth: Int) -> Admission {
        if case .bool(let flag) = node { return flag ? .yes : .no }
        guard depth < 32, case .object(let schema) = node, schema["$dynamicRef"] == nil, schema["$ref"] == nil
        else { return .unknown }
        var parts: [Admission] = []
        let hinted = rendersSiblingType(schema)
        if hinted, probe.type == "null", schema["nullable"] != .bool(true) { parts.append(.no) }
        if !hinted, let raw = schema["type"] {
            let names: [String]
            switch raw {
            case .string(let name): names = [name]
            case .array(let members):
                let strings = members.compactMap { member -> String? in
                    if case .string(let name) = member { return name }
                    return nil
                }
                names = strings.count == members.count ? strings : []
            default: names = []
            }
            let types = names.compactMap(canonicalType)
            guard !names.isEmpty, types.count == names.count else { return .unknown }
            var admitted = Set(types)
            if schema["nullable"] == .bool(true) { admitted.insert("null") }
            let type = probe.type
            parts.append(admitted.contains(type) || (type == "integer" && admitted.contains("number")) ? .yes : .no)
        }
        for key in ["enum", "const"] where schema[key] != nil {
            let options: [MLXLMCommon.JSONValue]
            if key == "enum" {
                guard case .array(let members)? = schema[key] else { return .unknown }
                options = members
            } else {
                options = [schema[key]!]
            }
            let values = options.map(carried)
            switch probe {
            case .value(let value): parts.append(values.contains(value) ? .yes : .no)
            case .type(let type):
                parts.append(values.contains {
                    Probe.value($0).type == type || (type == "number" && Probe.value($0).type == "integer")
                } ? .maybe : .no)
            }
        }
        parts.append(bounds(of: probe, schema))
        if let not = schema["not"] {
            switch admission(of: probe, not, depth: depth + 1) {
            case .yes: parts.append(.no)
            case .no: parts.append(.yes)
            case let other: parts.append(other)
            }
        }
        for key in ["allOf", "anyOf", "oneOf"] where schema[key] != nil {
            guard case .array(let branches)? = schema[key], !branches.isEmpty else { return .unknown }
            let readings = branches.map { admission(of: probe, $0, depth: depth + 1) }
            switch key {
            case "allOf": parts.append(all(readings))
            case "anyOf": parts.append(any(readings))
            default:
                let admitted = readings.filter { $0 == .yes }.count
                if readings.contains(.unknown) {
                    parts.append(.unknown)
                } else if admitted > 1 {
                    parts.append(.no)
                } else if readings.contains(.maybe) {
                    parts.append(.maybe)
                } else {
                    parts.append(admitted == 1 ? .yes : .no)
                }
            }
        }
        if let condition = schema["if"] {
            let then = schema["then"].map { admission(of: probe, $0, depth: depth + 1) }
            let otherwise = schema["else"].map { admission(of: probe, $0, depth: depth + 1) }
            switch admission(of: probe, condition, depth: depth + 1) {
            case .yes: parts.append(then ?? .yes)
            case .no: parts.append(otherwise ?? .yes)
            case .maybe:
                let both = [then ?? .yes, otherwise ?? .yes]
                parts.append(both.contains(.unknown) ? .unknown
                    : all(both) == .yes ? .yes : any(both) == .no ? .no : .maybe)
            case .unknown: parts.append(.unknown)
            }
        }
        return all(parts)
    }

    private static func all(_ readings: [Admission]) -> Admission {
        if readings.contains(.no) { return .no }
        if readings.contains(.unknown) { return .unknown }
        return readings.contains(.maybe) ? .maybe : .yes
    }

    private static func any(_ readings: [Admission]) -> Admission {
        if readings.contains(.yes) { return .yes }
        if readings.contains(.unknown) { return .unknown }
        return readings.contains(.maybe) ? .maybe : .no
    }

    /// The numeric bounds for a number, the length bounds and `pattern` for a
    /// string; a type probe only learns that some values may fail them.
    private static func bounds(of probe: Probe, _ schema: [String: MLXLMCommon.JSONValue]) -> Admission {
        let numeric = ["minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf"]
        let textual = ["minLength", "maxLength", "pattern"]
        let keys = ["integer", "number"].contains(probe.type) ? numeric : probe.type == "string" ? textual : []
        let present = keys.filter { schema[$0] != nil }
        guard !present.isEmpty else { return .yes }
        guard case .value(let value) = probe else { return .maybe }
        func bound(_ key: String) -> Double? {
            switch schema[key] {
            case .int(let int)?: Double(int)
            case .double(let double)?: double
            default: nil
            }
        }
        switch value {
        case .int, .double:
            let number: Double
            switch value {
            case .int(let int): number = Double(int)
            case .double(let double): number = double
            default: return .unknown
            }
            let exclusiveMinimum = schema["exclusiveMinimum"] == .bool(true)
            let exclusiveMaximum = schema["exclusiveMaximum"] == .bool(true)
            for key in present {
                if ["exclusiveMinimum", "exclusiveMaximum"].contains(key), case .bool? = schema[key] { continue }
                guard let limit = bound(key) else { return .unknown }
                let holds: Bool
                switch key {
                case "minimum": holds = exclusiveMinimum ? number > limit : number >= limit
                case "maximum": holds = exclusiveMaximum ? number < limit : number <= limit
                case "exclusiveMinimum": holds = number > limit
                case "exclusiveMaximum": holds = number < limit
                default:
                    guard limit > 0 else { return .unknown }
                    let quotient = number / limit
                    holds = quotient.isFinite && quotient.rounded() == quotient
                }
                if !holds { return .no }
            }
            return .yes
        case .string(let text):
            let length = text.unicodeScalars.count
            for key in present {
                if key == "pattern" {
                    guard case .string(let pattern)? = schema[key],
                          let regex = try? NSRegularExpression(pattern: pattern) else { return .unknown }
                    if regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil { return .no }
                } else {
                    guard let limit = bound(key) else { return .unknown }
                    if key == "minLength" ? Double(length) < limit : Double(length) > limit { return .no }
                }
            }
            return .yes
        default:
            return .yes
        }
    }
}
