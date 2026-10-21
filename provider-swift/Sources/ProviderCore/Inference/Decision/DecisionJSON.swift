// Copyright © 2026 Eigen Labs.
//
// Order-preserving JSON for pplx-decider requests.
//
// The decision prompt embeds caller JSON verbatim through the reference's
// `describe(v)` = `v if str else json.dumps(v, ensure_ascii=False)`. The model
// was trained on those exact bytes, so object member order, integer versus
// float spelling and Python's escaping all matter. Foundation's
// `JSONSerialization` loses member order and the int/float distinction, so
// decision bodies are parsed here (strict RFC 8259) and re-serialized with
// Python's default `json.dumps` rules.

import Foundation

/// One JSON value. Objects keep member order; numbers keep Python's
/// `int`/`float` split from the literal spelling.
enum DecisionJSON: Sendable, Equatable {
    struct Member: Sendable, Equatable {
        let key: String
        let value: DecisionJSON
    }

    case null
    case bool(Bool)
    /// A literal without fraction or exponent, as canonical decimal digits
    /// (Python reads it as an arbitrary-precision `int`).
    case integer(String)
    /// A literal with a fraction or exponent (Python `float`). Always finite.
    case float(Double)
    case string(String)
    case array([DecisionJSON])
    case object([Member])

    /// The member named `key`. Parsed objects never repeat a key.
    subscript(key: String) -> DecisionJSON? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.key.utf8.elementsEqual(key.utf8) }?.value
    }

    /// Python truthiness, which the reference applies through `x or default`.
    var isPythonTruthy: Bool {
        switch self {
        case .null: false
        case .bool(let value): value
        case .integer(let digits): digits != "0"
        case .float(let value): value != 0
        case .string(let text): !text.isEmpty
        case .array(let items): !items.isEmpty
        case .object(let members): !members.isEmpty
        }
    }
}

// MARK: - Parsing

/// A content-free syntax failure; the body is never echoed.
struct DecisionJSONSyntaxError: Error, Equatable {}

extension DecisionJSON {
    /// Nesting bound for caller JSON; deeper input is refused, not recursed.
    static let maximumDepth = 128

    /// Strict RFC 8259 parse of one complete document. Rejects duplicate
    /// object keys, lone surrogates, invalid UTF-8 and non-finite numbers.
    static func parse(_ data: Data) throws -> DecisionJSON {
        var parser = Parser(bytes: [UInt8](data))
        return try parser.parseDocument()
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        mutating func parseDocument() throws -> DecisionJSON {
            skipWhitespace()
            let value = try parseValue(depth: 0)
            skipWhitespace()
            guard index == bytes.count else { throw DecisionJSONSyntaxError() }
            return value
        }

        private var current: UInt8? { index < bytes.count ? bytes[index] : nil }

        private mutating func skipWhitespace() {
            while let byte = current, byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                index += 1
            }
        }

        private mutating func expect(_ byte: UInt8) throws {
            guard current == byte else { throw DecisionJSONSyntaxError() }
            index += 1
        }

        private mutating func parseValue(depth: Int) throws -> DecisionJSON {
            guard let byte = current else { throw DecisionJSONSyntaxError() }
            switch byte {
            case UInt8(ascii: "{"): return try parseObject(depth: depth + 1)
            case UInt8(ascii: "["): return try parseArray(depth: depth + 1)
            case UInt8(ascii: "\""): return .string(try parseString())
            case UInt8(ascii: "t"): try parseLiteral("true"); return .bool(true)
            case UInt8(ascii: "f"): try parseLiteral("false"); return .bool(false)
            case UInt8(ascii: "n"): try parseLiteral("null"); return .null
            case UInt8(ascii: "-"), UInt8(ascii: "0") ... UInt8(ascii: "9"): return try parseNumber()
            default: throw DecisionJSONSyntaxError()
            }
        }

        private mutating func parseLiteral(_ literal: String) throws {
            let expected = literal.utf8
            guard bytes.count - index >= expected.count,
                bytes[index ..< index + expected.count].elementsEqual(expected)
            else { throw DecisionJSONSyntaxError() }
            index += expected.count
        }

        private mutating func parseObject(depth: Int) throws -> DecisionJSON {
            guard depth <= DecisionJSON.maximumDepth else { throw DecisionJSONSyntaxError() }
            try expect(UInt8(ascii: "{"))
            skipWhitespace()
            var members: [Member] = []
            if current == UInt8(ascii: "}") {
                index += 1
                return .object(members)
            }
            // Python keeps distinct code-point sequences distinct; Swift
            // String equality would merge canonically equivalent keys.
            var seen = Set<[UInt8]>()
            while true {
                skipWhitespace()
                guard current == UInt8(ascii: "\"") else { throw DecisionJSONSyntaxError() }
                let key = try parseString()
                guard seen.insert(Array(key.utf8)).inserted else { throw DecisionJSONSyntaxError() }
                skipWhitespace()
                try expect(UInt8(ascii: ":"))
                skipWhitespace()
                members.append(Member(key: key, value: try parseValue(depth: depth)))
                skipWhitespace()
                if current == UInt8(ascii: ",") {
                    index += 1
                    continue
                }
                try expect(UInt8(ascii: "}"))
                return .object(members)
            }
        }

        private mutating func parseArray(depth: Int) throws -> DecisionJSON {
            guard depth <= DecisionJSON.maximumDepth else { throw DecisionJSONSyntaxError() }
            try expect(UInt8(ascii: "["))
            skipWhitespace()
            var items: [DecisionJSON] = []
            if current == UInt8(ascii: "]") {
                index += 1
                return .array(items)
            }
            while true {
                skipWhitespace()
                items.append(try parseValue(depth: depth))
                skipWhitespace()
                if current == UInt8(ascii: ",") {
                    index += 1
                    continue
                }
                try expect(UInt8(ascii: "]"))
                return .array(items)
            }
        }

        private mutating func parseString() throws -> String {
            try expect(UInt8(ascii: "\""))
            var buffer: [UInt8] = []
            while true {
                let runStart = index
                while let byte = current, byte != UInt8(ascii: "\""), byte != UInt8(ascii: "\\") {
                    guard byte >= 0x20 else { throw DecisionJSONSyntaxError() }
                    index += 1
                }
                buffer.append(contentsOf: bytes[runStart ..< index])
                guard let byte = current else { throw DecisionJSONSyntaxError() }
                index += 1
                if byte == UInt8(ascii: "\"") { break }
                try appendEscape(to: &buffer)
            }
            let text = String(decoding: buffer, as: UTF8.self)
            // Decoding repairs invalid UTF-8; a changed byte count proves it.
            guard text.utf8.elementsEqual(buffer) else { throw DecisionJSONSyntaxError() }
            return text
        }

        private mutating func appendEscape(to buffer: inout [UInt8]) throws {
            guard let byte = current else { throw DecisionJSONSyntaxError() }
            index += 1
            let simple: UInt8? = switch byte {
            case UInt8(ascii: "\""): 0x22
            case UInt8(ascii: "\\"): 0x5C
            case UInt8(ascii: "/"): 0x2F
            case UInt8(ascii: "b"): 0x08
            case UInt8(ascii: "f"): 0x0C
            case UInt8(ascii: "n"): 0x0A
            case UInt8(ascii: "r"): 0x0D
            case UInt8(ascii: "t"): 0x09
            default: nil
            }
            if let simple {
                buffer.append(simple)
                return
            }
            guard byte == UInt8(ascii: "u") else { throw DecisionJSONSyntaxError() }
            var scalarValue = try parseHexQuad()
            if (0xD800 ... 0xDBFF).contains(scalarValue) {
                try expect(UInt8(ascii: "\\"))
                try expect(UInt8(ascii: "u"))
                let low = try parseHexQuad()
                guard (0xDC00 ... 0xDFFF).contains(low) else { throw DecisionJSONSyntaxError() }
                scalarValue = 0x10000 + ((scalarValue - 0xD800) << 10) + (low - 0xDC00)
            }
            guard let scalar = Unicode.Scalar(scalarValue) else { throw DecisionJSONSyntaxError() }
            buffer.append(contentsOf: scalar.utf8)
        }

        private mutating func parseHexQuad() throws -> UInt32 {
            guard bytes.count - index >= 4 else { throw DecisionJSONSyntaxError() }
            var value: UInt32 = 0
            for _ in 0 ..< 4 {
                guard let byte = current, let digit = hexValue(byte) else { throw DecisionJSONSyntaxError() }
                value = value << 4 | digit
                index += 1
            }
            return value
        }

        private func hexValue(_ byte: UInt8) -> UInt32? {
            switch byte {
            case UInt8(ascii: "0") ... UInt8(ascii: "9"): UInt32(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a") ... UInt8(ascii: "f"): UInt32(byte - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A") ... UInt8(ascii: "F"): UInt32(byte - UInt8(ascii: "A") + 10)
            default: nil
            }
        }

        private mutating func parseNumber() throws -> DecisionJSON {
            let start = index
            if current == UInt8(ascii: "-") { index += 1 }
            guard let first = current, isDigit(first) else { throw DecisionJSONSyntaxError() }
            index += 1
            if first != UInt8(ascii: "0") { skipDigits() }
            var isInteger = true
            if current == UInt8(ascii: ".") {
                isInteger = false
                index += 1
                guard let byte = current, isDigit(byte) else { throw DecisionJSONSyntaxError() }
                skipDigits()
            }
            if current == UInt8(ascii: "e") || current == UInt8(ascii: "E") {
                isInteger = false
                index += 1
                if current == UInt8(ascii: "+") || current == UInt8(ascii: "-") { index += 1 }
                guard let byte = current, isDigit(byte) else { throw DecisionJSONSyntaxError() }
                skipDigits()
            }
            let literal = String(decoding: bytes[start ..< index], as: UTF8.self)
            if isInteger {
                return .integer(literal == "-0" ? "0" : literal)
            }
            guard let value = Double(literal), value.isFinite else { throw DecisionJSONSyntaxError() }
            return .float(value)
        }

        private func isDigit(_ byte: UInt8) -> Bool {
            (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte)
        }

        private mutating func skipDigits() {
            while let byte = current, isDigit(byte) { index += 1 }
        }
    }
}

// MARK: - Serialization

extension DecisionJSON {
    /// Python `json.dumps(value, ensure_ascii=False)` with default separators.
    var pythonDumps: String {
        var out = ""
        Self.write(self, to: &out, itemSeparator: ", ", keySeparator: ": ")
        return out
    }

    /// The same encoding without separator spaces, for response bodies.
    var compactJSON: String {
        var out = ""
        Self.write(self, to: &out, itemSeparator: ",", keySeparator: ":")
        return out
    }

    /// The reference's `describe(v)`: strings verbatim, everything else dumped.
    var described: String {
        if case .string(let text) = self { return text }
        return pythonDumps
    }

    private static func write(
        _ value: DecisionJSON, to out: inout String, itemSeparator: String, keySeparator: String
    ) {
        switch value {
        case .null: out += "null"
        case .bool(let flag): out += flag ? "true" : "false"
        case .integer(let digits): out += digits
        case .float(let number): out += pythonFloatRepr(number)
        case .string(let text): writeString(text, to: &out)
        case .array(let items):
            out += "["
            for (offset, item) in items.enumerated() {
                if offset > 0 { out += itemSeparator }
                write(item, to: &out, itemSeparator: itemSeparator, keySeparator: keySeparator)
            }
            out += "]"
        case .object(let members):
            out += "{"
            for (offset, member) in members.enumerated() {
                if offset > 0 { out += itemSeparator }
                writeString(member.key, to: &out)
                out += keySeparator
                write(member.value, to: &out, itemSeparator: itemSeparator, keySeparator: keySeparator)
            }
            out += "}"
        }
    }

    /// Python's `ensure_ascii=False` string encoder: escape `"`, `\` and the
    /// C0 controls; everything else (including `/` and non-ASCII) verbatim.
    private static func writeString(_ text: String, to out: inout String) {
        out += "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case _ where scalar.value < 0x20:
                let hex = String(scalar.value, radix: 16)
                out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }

    /// Python `repr(float)` for a finite value: the shortest round-trip
    /// digits (Swift's `description` yields the same digits), laid out with
    /// Python's rule: scientific when the decimal exponent is below -4 or at
    /// least 16, otherwise positional with a trailing `.0` for integers.
    static func pythonFloatRepr(_ value: Double) -> String {
        let sign = value.sign == .minus ? "-" : ""
        if value == 0 { return sign + "0.0" }
        let (digits, decimalPoint) = shortestDigits(value.magnitude)
        // `decimalPoint` places the point: value = 0.d1d2... × 10^decimalPoint.
        if decimalPoint <= -4 || decimalPoint > 16 {
            let exponent = decimalPoint - 1
            var mantissa = String(digits.prefix(1))
            if digits.count > 1 { mantissa += "." + String(digits.dropFirst()) }
            let exponentDigits = String(abs(exponent))
            let paddedExponent = exponentDigits.count < 2 ? "0" + exponentDigits : exponentDigits
            return sign + mantissa + "e" + (exponent < 0 ? "-" : "+") + paddedExponent
        }
        if decimalPoint <= 0 {
            return sign + "0." + String(repeating: "0", count: -decimalPoint) + digits
        }
        if decimalPoint >= digits.count {
            return sign + digits + String(repeating: "0", count: decimalPoint - digits.count) + ".0"
        }
        let split = digits.index(digits.startIndex, offsetBy: decimalPoint)
        return sign + String(digits[..<split]) + "." + String(digits[split...])
    }

    /// Significant digits (no leading/trailing zeros) and decimal-point
    /// position of Swift's shortest round-trip rendering of a positive value.
    private static func shortestDigits(_ magnitude: Double) -> (String, Int) {
        let parts = magnitude.description.split(separator: "e", maxSplits: 1)
        let exponent = parts.count == 2 ? Int(parts[1]) ?? 0 : 0
        let mantissa = String(parts[0])
        let integerCount = mantissa.firstIndex(of: ".")
            .map { mantissa.distance(from: mantissa.startIndex, to: $0) } ?? mantissa.count
        var digits = Substring(mantissa.replacingOccurrences(of: ".", with: ""))
        var decimalPoint = integerCount + exponent
        while digits.first == "0" {
            digits = digits.dropFirst()
            decimalPoint -= 1
        }
        while digits.last == "0" { digits = digits.dropLast() }
        return (String(digits), decimalPoint)
    }
}
