// Copyright © 2026 Eigen Labs.

import Foundation
import Jinja

/// Transformers' `tojson` and `string` filters, for requests that ask for the
/// tool JSON their model was trained on (`TemplateJSONOrder` in ProviderCore).
///
/// Transformers overrides Jinja's `tojson` with `json.dumps(value,
/// ensure_ascii=False, indent=None, separators=None, sort_keys=False)`: keys
/// in the value's own order, `", "` and `": "` separators, non-ASCII text as
/// is. A template may pass any of those arguments. `string` is Python `str`.
/// swift-jinja's `tojson` sorts keys, writes compact JSON, escapes `/` and
/// (by default) non-ASCII text, and its `string` prints `true`/`none` where
/// Python prints `True`/`None`, so tool declarations and earlier calls read
/// differently from what the model was trained on.
///
/// The filters only render; key order comes from the values the request
/// supplies. Gemma's template sorts with `dictsort` and Nemotron carries its
/// own filters, so neither is listed. A request renders these filters only
/// when it asks for them (`requestContext`); every other render keeps
/// swift-jinja's, so its prompt bytes are unchanged. The `string` filter of a
/// listed family's template is renamed at load (`bindingFilters`) so a
/// request can choose it; `bindingContext` binds the new name to swift-jinja's
/// own filter. `DARKBLOOM_TEMPLATE_JSON_LEGACY=1` turns all of this off.
public enum HFTemplateFilters {
    public static let legacyEnvironmentKey = "DARKBLOOM_TEMPLATE_JSON_LEGACY"
    static let stringFilterName = "__darkbloom_hf_string"
    static let outputLimit = 16 << 20
    static let maximumDepth = 128

    /// Served `model_type`s rendered with Transformers' filters: Qwen 3.5,
    /// 3.6 and 3.8, Bonsai (Qwen 3.5 templates), MiMo, GLM-5.3 and GPT-OSS.
    static let modelTypes: Set<String> = [
        "qwen3_5", "qwen3_5_moe", "prism_hadamard_qwen35", "mimo_v2",
        "glm5_next", "glm5_next_text", "glm5_next_mtp", "gpt_oss",
    ]

    /// The family can render Transformers' filters and the kill switch is off.
    public static func applies(
        modelType: String?, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let modelType = modelType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            modelTypes.contains(modelType)
        else { return false }
        return !legacyRequested(environment: environment)
    }

    /// The kill switch: `1`, `true`, `yes` or `on`.
    public static func legacyRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let raw = environment[legacyEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return false }
        return ["1", "true", "yes", "on"].contains(raw)
    }

    /// Load-time context of a listed family: its renamed `string` filter
    /// bound to swift-jinja's, so a render that asks for nothing is unchanged.
    public static func bindingContext(
        modelType: String?, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: any Sendable]? {
        guard applies(modelType: modelType, environment: environment) else { return nil }
        return [stringFilterName: swiftJinjaString]
    }

    /// The context one request adds to render Transformers' filters. It
    /// overrides `bindingContext` and swift-jinja's `tojson`.
    public static func requestContext() -> [String: any Sendable] {
        [stringFilterName: stringFilter, "tojson": toJSONFilter]
    }

    /// `bindingContext` installed in a render environment (the scan-time
    /// render check renders as a request that asks for nothing).
    public static func install(
        in environment: Environment, modelType: String?,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        guard applies(modelType: modelType, environment: processEnvironment) else { return }
        environment[stringFilterName] = swiftJinjaString
    }

    /// Renames the `string` filter (never the `is string` test, literals or
    /// comments) of a listed family's template to the name the contexts bind.
    public static func bindingFilters(
        in template: String, modelType: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        guard applies(modelType: modelType, environment: environment) else { return template }
        return NemotronTemplateFilters.rebindingStringFilter(in: template, to: stringFilterName)
    }

    private static let swiftJinjaString = Value.function { args, kwargs, environment in
        guard let filter = Filters.builtIn["string"] else {
            throw JinjaError.runtime("swift-jinja has no string filter")
        }
        return try filter(args, kwargs, environment)
    }

    private static let stringFilter = Value.function { args, kwargs, _ in
        guard args.count == 1, kwargs.isEmpty else {
            throw JinjaError.runtime("string accepts only the value")
        }
        return .string(try pythonString(args[0]))
    }

    /// `json.dumps(value, ensure_ascii=False, indent=None, separators=None,
    /// sort_keys=False)`, the arguments by position or name as Transformers
    /// declares them.
    private static let toJSONFilter = Value.function { args, kwargs, _ in
        guard let value = args.first else { return .string("null") }
        let names = ["ensure_ascii", "indent", "separators", "sort_keys"]
        guard args.count - 1 <= names.count, kwargs.keys.allSatisfy(names.contains) else {
            throw JinjaError.runtime("tojson accepts ensure_ascii, indent, separators and sort_keys")
        }
        var options: [String: Value] = [:]
        for (index, argument) in args.dropFirst().enumerated() { options[names[index]] = argument }
        for (name, argument) in kwargs {
            guard options[name] == nil else { throw JinjaError.runtime("tojson got \(name) twice") }
            options[name] = argument
        }
        var writer = try PythonJSONWriter(options: options)
        try writer.write(value, depth: 0)
        return .string(writer.output)
    }

    /// Python `json.dumps` over Jinja values.
    struct PythonJSONWriter {
        private(set) var output = ""
        private let ensureASCII: Bool
        private let indent: String?
        private let itemSeparator: String
        private let keySeparator: String
        private let sortKeys: Bool

        init(options: [String: Value] = [:]) throws {
            func flag(_ name: String, _ fallback: Bool) -> Bool {
                guard let value = options[name], !value.isNull, !value.isUndefined else { return fallback }
                return value.isTruthy
            }
            ensureASCII = flag("ensure_ascii", false)
            sortKeys = flag("sort_keys", false)
            switch options["indent"] {
            case nil, .null?, .undefined?: indent = nil
            case .int(let count)?: indent = String(repeating: " ", count: max(0, count))
            case .string(let text)?: indent = text
            default: throw JinjaError.runtime("tojson indent must be an integer or a string")
            }
            switch options["separators"] {
            case nil, .null?, .undefined?:
                itemSeparator = indent == nil ? ", " : ","
                keySeparator = ": "
            case .array(let pair)?:
                guard pair.count == 2, case .string(let item) = pair[0], case .string(let key) = pair[1] else {
                    throw JinjaError.runtime("tojson separators must be two strings")
                }
                itemSeparator = item
                keySeparator = key
            default: throw JinjaError.runtime("tojson separators must be two strings")
            }
        }

        mutating func write(_ value: Value, depth: Int) throws {
            guard depth <= HFTemplateFilters.maximumDepth, output.utf8.count <= HFTemplateFilters.outputLimit else {
                throw JinjaError.runtime("prompt JSON exceeds its bound")
            }
            switch value {
            // jinja2 refuses Undefined; swift-jinja wrote null, which is kept
            // so a render that worked before cannot start failing.
            case .null, .undefined: output += "null"
            case .boolean(let flag): output += flag ? "true" : "false"
            case .int(let number): output += String(number)
            case .double(let number): output += HFTemplateFilters.pythonFloat(number, json: true)
            case .string(let text): output += HFTemplateFilters.jsonString(text, ensureASCII: ensureASCII)
            case .array(let items):
                guard !items.isEmpty else { output += "[]"; return }
                output += "["
                for (index, item) in items.enumerated() {
                    separate(index, depth: depth + 1)
                    try write(item, depth: depth + 1)
                }
                close("]", depth: depth)
            case .object(let members):
                guard !members.isEmpty else { output += "{}"; return }
                output += "{"
                let pairs = sortKeys
                    ? members.elements.sorted { $0.key.unicodeScalars.lexicographicallyPrecedes($1.key.unicodeScalars) }
                    : Array(members.elements)
                for (index, pair) in pairs.enumerated() {
                    separate(index, depth: depth + 1)
                    output += HFTemplateFilters.jsonString(pair.key, ensureASCII: ensureASCII) + keySeparator
                    try write(pair.value, depth: depth + 1)
                }
                close("}", depth: depth)
            case .function, .macro:
                throw JinjaError.runtime("prompt value is not JSON serializable")
            }
        }

        private mutating func separate(_ index: Int, depth: Int) {
            if index > 0 { output += itemSeparator }
            if let indent { output += "\n" + String(repeating: indent, count: depth) }
        }

        private mutating func close(_ bracket: String, depth: Int) {
            if let indent { output += "\n" + String(repeating: indent, count: depth) }
            output += bracket
        }
    }

    /// CPython `encode_basestring` / `encode_basestring_ascii`.
    static func jsonString(_ text: String, ensureASCII: Bool) -> String {
        var output = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            default:
                if scalar.value < 0x20 || (ensureASCII && scalar.value > 0x7E) {
                    if scalar.value > 0xFFFF {
                        let offset = scalar.value - 0x10000
                        output += "\\u" + hex(0xD800 + (offset >> 10), width: 4)
                        output += "\\u" + hex(0xDC00 + (offset & 0x3FF), width: 4)
                    } else {
                        output += "\\u" + hex(scalar.value, width: 4)
                    }
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        return output + "\""
    }

    /// Python `str(value)`; jinja2 renders `Undefined` as the empty string.
    static func pythonString(_ value: Value) throws -> String {
        switch value {
        case .string(let text): return text
        case .undefined: return ""
        default:
            var output = ""
            try writeRepr(value, to: &output, depth: 0)
            return output
        }
    }

    private static func writeRepr(_ value: Value, to output: inout String, depth: Int) throws {
        guard depth <= maximumDepth, output.utf8.count <= outputLimit else {
            throw JinjaError.runtime("prompt value exceeds its bound")
        }
        switch value {
        case .null, .undefined: output += "None"
        case .boolean(let flag): output += flag ? "True" : "False"
        case .int(let number): output += String(number)
        case .double(let number): output += pythonFloat(number, json: false)
        case .string(let text): output += pythonRepr(text)
        case .array(let items):
            output += "["
            for (index, item) in items.enumerated() {
                if index > 0 { output += ", " }
                try writeRepr(item, to: &output, depth: depth + 1)
            }
            output += "]"
        case .object(let members):
            output += "{"
            for (index, member) in members.enumerated() {
                if index > 0 { output += ", " }
                output += pythonRepr(member.key) + ": "
                try writeRepr(member.value, to: &output, depth: depth + 1)
            }
            output += "}"
        case .function, .macro:
            throw JinjaError.runtime("prompt value is not printable data")
        }
    }

    /// CPython `unicode_repr`, including its quote choice.
    static func pythonRepr(_ text: String) -> String {
        let quote: Unicode.Scalar = text.contains("'") && !text.contains("\"") ? "\"" : "'"
        var output = String(quote)
        for scalar in text.unicodeScalars {
            switch scalar {
            case quote, "\\": output += "\\"; output.unicodeScalars.append(scalar)
            case "\t": output += "\\t"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    output += "\\x" + hex(scalar.value, width: 2)
                } else if scalar.value < 0x7F || isPythonPrintable(scalar) {
                    output.unicodeScalars.append(scalar)
                } else if scalar.value <= 0xFF {
                    output += "\\x" + hex(scalar.value, width: 2)
                } else if scalar.value <= 0xFFFF {
                    output += "\\u" + hex(scalar.value, width: 4)
                } else {
                    output += "\\U" + hex(scalar.value, width: 8)
                }
            }
        }
        output.unicodeScalars.append(quote)
        return output
    }

    private static func isPythonPrintable(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned,
            .lineSeparator, .paragraphSeparator, .spaceSeparator:
            return false
        default:
            return true
        }
    }

    /// CPython `float_repr` (shortest round trip, `repr` exponent rules);
    /// `json.dumps` spells non-finite values as JavaScript literals.
    static func pythonFloat(_ number: Double, json: Bool) -> String {
        if number.isNaN { return json ? "NaN" : "nan" }
        if number.isInfinite {
            return number < 0 ? (json ? "-Infinity" : "-inf") : (json ? "Infinity" : "inf")
        }
        let sign = number.sign == .minus ? "-" : ""
        if number == 0 { return sign + "0.0" }
        let (digits, point) = shortestDigits(abs(number))
        if point <= -4 || point > 16 {
            let exponent = point - 1
            let mantissa = digits.count == 1
                ? digits : String(digits.prefix(1)) + "." + String(digits.dropFirst())
            let magnitude = abs(exponent)
            return sign + mantissa + (exponent < 0 ? "e-" : "e+")
                + (magnitude < 10 ? "0" : "") + String(magnitude)
        }
        if point <= 0 { return sign + "0." + String(repeating: "0", count: -point) + digits }
        if point >= digits.count {
            return sign + digits + String(repeating: "0", count: point - digits.count) + ".0"
        }
        return sign + String(digits.prefix(point)) + "." + String(digits.dropFirst(point))
    }

    /// Swift and CPython both print the shortest round-trip digit string.
    /// Returns those digits and the decimal point position (0.d1d2… × 10^point).
    private static func shortestDigits(_ magnitude: Double) -> (String, Int) {
        let text = magnitude.description.lowercased()
        let parts = text.split(separator: "e", maxSplits: 1)
        let exponent = parts.count == 2 ? Int(parts[1]) ?? 0 : 0
        let mantissa = parts[0].split(separator: ".", maxSplits: 1)
        let integral = String(mantissa[0])
        let fraction = mantissa.count == 2 ? String(mantissa[1]) : ""
        var digits = Substring(integral + fraction)
        var point = integral.count + exponent
        while digits.first == "0" { digits.removeFirst(); point -= 1 }
        while digits.last == "0" { digits.removeLast() }
        return (String(digits), point)
    }

    private static func hex(_ value: UInt32, width: Int) -> String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }
}
