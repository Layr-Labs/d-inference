import Foundation
import Jinja

/// Python-compatible `string`, `trim`, `tojson` and `str.endswith` for the
/// pinned Super template. Transformers renders it with Python `str`,
/// `str.strip`, `json.dumps(ensure_ascii=False)` and code-point suffixes;
/// swift-jinja's defaults print booleans, `None`, floats and nested values
/// differently and compare suffixes by Character. Scoped to Super so other
/// families keep their existing prompt bytes.
enum NemotronSuperTemplateFilters {
    /// swift-jinja resolves `string` the filter and `string` the test through
    /// one name. Rebinding only the filter keeps `is string` intact. The plain
    /// pattern is exact only for the hash-pinned template, which has no
    /// `| string` inside literals or comments; golden tests prove its output.
    static let stringFilterName = "__nemotron_super_string"
    /// The template's one `endswith` call decides the separator before a media
    /// part. swift-jinja's would not see "\n" ending text that ends in "\r\n"
    /// (one Character), so the exact call is rewritten to this filter.
    static let endsWithFilterName = "__nemotron_super_endswith"
    static let outputLimit = 16 << 20

    static func bind(template: String) -> String {
        template
            .replacingOccurrences(of: #"\|(\s*)string(?![A-Za-z0-9_])"#, with: "|$1\(stringFilterName)",
                                  options: .regularExpression)
            .replacingOccurrences(of: #"content_ns.val.endswith('\n')"#,
                                  with: #"(content_ns.val | \#(endsWithFilterName)('\n'))"#)
    }

    static var context: [String: any Sendable] {
        [stringFilterName: stringFilter, endsWithFilterName: endsWithFilter, "trim": trimFilter,
         "tojson": toJSONFilter]
    }

    private static let stringFilter = Value.function { args, kwargs, _ in
        .string(try pythonString(soleArgument(args, kwargs)))
    }

    private static let trimFilter = Value.function { args, kwargs, _ in
        .string(pythonStrip(try pythonString(soleArgument(args, kwargs))))
    }

    private static let toJSONFilter = Value.function { args, kwargs, _ in
        var output = ""
        try writeJSON(soleArgument(args, kwargs), to: &output, depth: 0)
        return .string(output)
    }

    /// Python `str.endswith(suffix)`, comparing Unicode scalars.
    private static let endsWithFilter = Value.function { args, kwargs, _ in
        guard args.count == 2, kwargs.isEmpty, case .string(let text) = args[0], case .string(let suffix) = args[1]
        else { throw JinjaError.runtime("Super endswith accepts only a string and a string suffix") }
        return .boolean(text.unicodeScalars.reversed().starts(with: suffix.unicodeScalars.reversed()))
    }

    private static func soleArgument(_ args: [Value], _ kwargs: [String: Value]) throws -> Value {
        guard args.count == 1, kwargs.isEmpty else {
            throw JinjaError.runtime("Super reference filters accept only their pinned default arguments")
        }
        return args[0]
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

    /// Python `str.strip()`: every character for which `str.isspace()` holds.
    static func pythonStrip(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        guard let first = scalars.firstIndex(where: { !isPythonSpace($0) }),
            let last = scalars.lastIndex(where: { !isPythonSpace($0) })
        else { return "" }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[first...last])
        return String(view)
    }

    private static func isPythonSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029,
            0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }

    private static func writeRepr(_ value: Value, to output: inout String, depth: Int) throws {
        guard depth <= NemotronSuperOrderedJSON.maximumDepth, output.utf8.count <= outputLimit else {
            throw JinjaError.runtime("Super prompt value exceeds its bound")
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
            throw JinjaError.runtime("Super prompt value is not printable data")
        }
    }

    /// `json.dumps(value, ensure_ascii=False)` with default separators.
    static func writeJSON(_ value: Value, to output: inout String, depth: Int) throws {
        guard depth <= NemotronSuperOrderedJSON.maximumDepth, output.utf8.count <= outputLimit else {
            throw JinjaError.runtime("Super prompt JSON exceeds its bound")
        }
        switch value {
        case .null: output += "null"
        case .boolean(let flag): output += flag ? "true" : "false"
        case .int(let number): output += String(number)
        case .double(let number): output += pythonFloat(number, json: true)
        case .string(let text): output += jsonString(text)
        case .array(let items):
            output += "["
            for (index, item) in items.enumerated() {
                if index > 0 { output += ", " }
                try writeJSON(item, to: &output, depth: depth + 1)
            }
            output += "]"
        case .object(let members):
            output += "{"
            for (index, member) in members.enumerated() {
                if index > 0 { output += ", " }
                output += jsonString(member.key) + ": "
                try writeJSON(member.value, to: &output, depth: depth + 1)
            }
            output += "}"
        case .undefined, .function, .macro:
            throw JinjaError.runtime("Super prompt value is not JSON serializable")
        }
    }

    private static func jsonString(_ text: String) -> String {
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
                if scalar.value < 0x20 {
                    output += "\\u" + hex(scalar.value, width: 4)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        return output + "\""
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
