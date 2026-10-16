import Foundation
import Jinja

/// Strict, bounded RFC 8259 parser that keeps object member order.
///
/// The pinned Super template iterates tool schemas and tool-call arguments in
/// request order (Python dictionaries preserve it); Foundation and
/// `Jinja.Value(any:)` do not. Duplicate keys keep their first position and
/// the last value, as Python's `json.loads` does. Integers outside `Int`,
/// lone surrogates and non-standard literals are refused rather than altered.
enum NemotronSuperOrderedJSON {
    enum Failure: Error, Equatable { case invalid, limit }

    static let maximumDepth = 64

    static func parse(_ text: String) throws -> Value {
        try parse(Data(text.utf8))
    }

    static func parse(_ data: Data) throws -> Value {
        var parser = Parser(bytes: [UInt8](data))
        parser.skipWhitespace()
        let value = try parser.value(depth: 0)
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw Failure.invalid }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func value(depth: Int) throws -> Value {
            guard depth <= NemotronSuperOrderedJSON.maximumDepth else { throw Failure.limit }
            guard index < bytes.count else { throw Failure.invalid }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try object(depth: depth)
            case UInt8(ascii: "["): return try array(depth: depth)
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try literal("true"); return .boolean(true)
            case UInt8(ascii: "f"): try literal("false"); return .boolean(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            default: return try number()
            }
        }

        private mutating func object(depth: Int) throws -> Value {
            index += 1
            var members = OrderedDictionary<String, Value>()
            skipWhitespace()
            if consume(UInt8(ascii: "}")) { return .object(members) }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw Failure.invalid }
                let key = try string()
                skipWhitespace()
                guard consume(UInt8(ascii: ":")) else { throw Failure.invalid }
                skipWhitespace()
                members[key] = try value(depth: depth + 1)
                skipWhitespace()
                if consume(UInt8(ascii: ",")) { continue }
                guard consume(UInt8(ascii: "}")) else { throw Failure.invalid }
                return .object(members)
            }
        }

        private mutating func array(depth: Int) throws -> Value {
            index += 1
            var items: [Value] = []
            skipWhitespace()
            if consume(UInt8(ascii: "]")) { return .array(items) }
            while true {
                skipWhitespace()
                items.append(try value(depth: depth + 1))
                skipWhitespace()
                if consume(UInt8(ascii: ",")) { continue }
                guard consume(UInt8(ascii: "]")) else { throw Failure.invalid }
                return .array(items)
            }
        }

        private mutating func string() throws -> String {
            index += 1
            var scalars = String.UnicodeScalarView()
            var start = index
            func flush(_ end: Int) throws {
                guard start < end else { return }
                guard let text = String(bytes: bytes[start..<end], encoding: .utf8) else {
                    throw Failure.invalid
                }
                scalars.append(contentsOf: text.unicodeScalars)
            }
            while index < bytes.count {
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") {
                    try flush(index)
                    index += 1
                    return String(scalars)
                }
                guard byte >= 0x20 else { throw Failure.invalid }
                guard byte == UInt8(ascii: "\\") else { index += 1; continue }
                try flush(index)
                index += 1
                guard index < bytes.count else { throw Failure.invalid }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "\""): scalars.append("\"")
                case UInt8(ascii: "\\"): scalars.append("\\")
                case UInt8(ascii: "/"): scalars.append("/")
                case UInt8(ascii: "b"): scalars.append("\u{08}")
                case UInt8(ascii: "f"): scalars.append("\u{0C}")
                case UInt8(ascii: "n"): scalars.append("\n")
                case UInt8(ascii: "r"): scalars.append("\r")
                case UInt8(ascii: "t"): scalars.append("\t")
                case UInt8(ascii: "u"): scalars.append(try unicodeEscape())
                default: throw Failure.invalid
                }
                start = index
            }
            throw Failure.invalid
        }

        private mutating func unicodeEscape() throws -> Unicode.Scalar {
            let high = try hexQuad()
            if (0xD800...0xDBFF).contains(high) {
                guard consume(UInt8(ascii: "\\")), consume(UInt8(ascii: "u")) else { throw Failure.invalid }
                let low = try hexQuad()
                guard (0xDC00...0xDFFF).contains(low),
                    let scalar = Unicode.Scalar(0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00))
                else { throw Failure.invalid }
                return scalar
            }
            guard let scalar = Unicode.Scalar(high) else { throw Failure.invalid }
            return scalar
        }

        private mutating func hexQuad() throws -> UInt32 {
            guard index + 4 <= bytes.count,
                let text = String(bytes: bytes[index..<index + 4], encoding: .ascii),
                text.allSatisfy(\.isHexDigit), let value = UInt32(text, radix: 16)
            else { throw Failure.invalid }
            index += 4
            return value
        }

        private mutating func number() throws -> Value {
            let start = index
            _ = consume(UInt8(ascii: "-"))
            guard index < bytes.count else { throw Failure.invalid }
            if bytes[index] == UInt8(ascii: "0") {
                index += 1
            } else {
                guard digits() > 0 else { throw Failure.invalid }
            }
            var integral = true
            if consume(UInt8(ascii: ".")) {
                integral = false
                guard digits() > 0 else { throw Failure.invalid }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                integral = false
                index += 1
                if !consume(UInt8(ascii: "+")) { _ = consume(UInt8(ascii: "-")) }
                guard digits() > 0 else { throw Failure.invalid }
            }
            let text = String(decoding: bytes[start..<index], as: UTF8.self)
            if integral {
                guard let value = Int(text) else { throw Failure.limit }
                return .int(value)
            }
            guard let value = Double(text) else { throw Failure.invalid }
            return .double(value)
        }

        private mutating func digits() -> Int {
            let start = index
            while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) {
                index += 1
            }
            return index - start
        }

        private mutating func literal(_ word: String) throws {
            let expected = Array(word.utf8)
            guard index + expected.count <= bytes.count,
                Array(bytes[index..<index + expected.count]) == expected
            else { throw Failure.invalid }
            index += expected.count
        }

        private mutating func consume(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }
    }
}
