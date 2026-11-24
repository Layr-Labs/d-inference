// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon

/// The call parser's literal reading of a parameter's text, a mirror of the
/// SDK's `ToolArgumentNormalization` for the Qwen XML dialect (`literal`,
/// `LiteralReading.preferred`): under a schema with no single non-string type
/// (`not`, `if`/`then`/`else`, a union, no `type`), a text that spells a JSON
/// literal the schema admits becomes that literal. A number does whenever it
/// is written exactly as JSON writes it; `true`, `false` and `null` only when
/// the schema rejects the text as a string. Like `parserConversion`, it reads
/// no `$ref`: a schema that holds one reads as text here.
enum QwenParserLiteralReading {
    /// The literal the parser reads `text` as under `schema`, or nil when it
    /// keeps the text. Only for a parameter `parserConversion` reads as text.
    static func literal(_ text: String, schema: [String: JSONValue]) -> JSONValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let literal = jsonLiteral(trimmed), admitsLiteralType(schema),
              admission(of: .value(literal), .object(schema), depth: 0) == .yes else { return nil }
        switch literal {
        case .int, .double:
            if trimmed == text { return literal }
        default:
            break
        }
        return admission(of: .value(.string(text)), .object(schema), depth: 0) == .no ? literal : nil
    }

    /// Whether some text may read as a literal under `schema`: a number it may
    /// admit, or a Boolean or null it may admit while it does not admit every
    /// string. A schema this cannot decide keeps every text.
    static func admitsLiteralType(_ schema: [String: JSONValue]) -> Bool {
        var readings: [String: Admission] = [:]
        for type in ["integer", "number", "boolean", "null", "string"] {
            let reading = admission(of: .type(type), .object(schema), depth: 0)
            guard reading != .unknown else { return false }
            readings[type] = reading
        }
        func admitted(_ type: String) -> Bool { readings[type] != .no }
        return admitted("integer") || admitted("number")
            || ((admitted("boolean") || admitted("null")) && readings["string"] != .yes)
    }

    /// A scalar spelled exactly as JSON writes it: `true`, `false`, `null`
    /// or a JSON number (no sign but `-`, no leading zeros, no bare point).
    static func jsonLiteral(_ text: String) -> JSONValue? {
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
        return number(text)
    }

    /// The SDK's number reading: an integral spelling is an integer when it
    /// fits, else a finite double.
    private static func number(_ text: String) -> JSONValue? {
        if let value = Int(text) { return .int(value) }
        guard let value = Double(text), value.isFinite else { return nil }
        return decimalInteger(text).map(JSONValue.int) ?? .double(value)
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
        case value(JSONValue)
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
    private static func carried(_ value: JSONValue) -> JSONValue {
        if case .double(let double) = value, double.rounded() == double, let int = Int(exactly: double) {
            return .int(int)
        }
        return value
    }

    /// The keywords that decide a scalar, as the SDK reads them; a local or
    /// dynamic reference is undecided here.
    static func admission(of probe: Probe, _ node: JSONValue, depth: Int) -> Admission {
        if case .bool(let flag) = node { return flag ? .yes : .no }
        guard depth < 32, case .object(let schema) = node, schema["$dynamicRef"] == nil, schema["$ref"] == nil
        else { return .unknown }
        var parts: [Admission] = []
        if let raw = schema["type"] {
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
            let options: [JSONValue]
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
    private static func bounds(of probe: Probe, _ schema: [String: JSONValue]) -> Admission {
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
