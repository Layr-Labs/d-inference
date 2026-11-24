import Foundation
import MLXLMCommon

/// History tool-call `arguments` in the shapes vLLM's GLM-5.3 serving accepts:
/// one RFC 8259 JSON object, where a repeated key keeps its last value and a
/// number that no JSON value holds exactly is read as `JSONValue` reads it (an
/// integer outside the signed 64-bit range as its nearest double, where vLLM keeps it exact).
///
/// `GLM5NextPromptPolicy` reads arguments with the native GLM codec first. That
/// codec is built for the model's own calls, whose text it must keep exactly,
/// so it refuses both shapes; this reader runs only on what it refuses. It
/// otherwise reads JSON the same way (strings through the same strict decoder,
/// numbers through `JSONValue`'s decoder, the same depth and number-length
/// bounds), so it gives the native codec's values wherever both accept the
/// text. Still refused: anything that is not one JSON object, a number beyond a
/// double, two keys that differ only in Unicode normalization (one rendered
/// object cannot hold them apart), and nesting past the codec's 64 levels.
enum GLM5NextHistoryArguments {
    typealias Value = MLXLMCommon.JSONValue

    static func object(_ raw: String) -> [String: Value]? {
        var reader = Reader(bytes: Array(raw.utf8))
        guard case .object(let values)? = reader.value(depth: 0) else { return nil }
        reader.skipWhitespace()
        return reader.index == reader.bytes.count ? values : nil
    }

    private struct Reader {
        let bytes: [UInt8]
        var index = 0

        mutating func value(depth: Int) -> Value? {
            guard depth <= 64 else { return nil }
            skipWhitespace()
            guard index < bytes.count else { return nil }
            switch bytes[index] {
            case UInt8(ascii: "\""): return string().map(Value.string)
            case UInt8(ascii: "{"):
                index += 1
                skipWhitespace()
                var values: [String: Value] = [:]
                var keyBytes: [String: [UInt8]] = [:]
                if consume("}") { return .object(values) }
                while true {
                    skipWhitespace()
                    guard let key = string() else { return nil }
                    let bytes = Array(key.utf8)
                    if let earlier = keyBytes[key], earlier != bytes { return nil }
                    keyBytes[key] = bytes
                    skipWhitespace()
                    guard consume(":"), let value = value(depth: depth + 1) else { return nil }
                    values[key] = value
                    skipWhitespace()
                    if consume("}") { return .object(values) }
                    guard consume(",") else { return nil }
                }
            case UInt8(ascii: "["):
                index += 1
                skipWhitespace()
                var values: [Value] = []
                if consume("]") { return .array(values) }
                while true {
                    guard let value = value(depth: depth + 1) else { return nil }
                    values.append(value)
                    skipWhitespace()
                    if consume("]") { return .array(values) }
                    guard consume(",") else { return nil }
                }
            case UInt8(ascii: "t"): return consume("true") ? .bool(true) : nil
            case UInt8(ascii: "f"): return consume("false") ? .bool(false) : nil
            case UInt8(ascii: "n"): return consume("null") ? .null : nil
            default: return number()
            }
        }

        private mutating func string() -> String? {
            let start = index
            guard consume("\"") else { return nil }
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if byte < 32 { return nil }
                if byte == UInt8(ascii: "\"") {
                    return try? JSONDecoder().decode(String.self, from: Data(bytes[start ..< index]))
                }
                if byte == UInt8(ascii: "\\") {
                    guard index < bytes.count else { return nil }
                    index += 1
                }
            }
            return nil
        }

        /// RFC 8259 number syntax, then `JSONValue`'s decoder for the value.
        private mutating func number() -> Value? {
            let start = index
            _ = consume("-")
            if !consume("0") {
                guard index < bytes.count, (UInt8(ascii: "1") ... UInt8(ascii: "9")).contains(bytes[index])
                else { return nil }
                skipDigits()
            }
            if consume(".") {
                guard skipDigits() else { return nil }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                index += 1
                if !consume("+") { _ = consume("-") }
                guard skipDigits() else { return nil }
            }
            guard index - start <= 1024,
                var value = try? JSONDecoder().decode(Value.self, from: Data(bytes[start ..< index]))
            else { return nil }
            switch value {
            case .int(0) where bytes[start] == UInt8(ascii: "-"): value = .double(-0.0)
            case .int: break
            case .double(let number): guard number.isFinite else { return nil }
            default: return nil
            }
            return value
        }

        @discardableResult
        private mutating func skipDigits() -> Bool {
            let start = index
            while index < bytes.count, (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
            return index > start
        }

        mutating func skipWhitespace() {
            while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
        }

        private mutating func consume(_ literal: String) -> Bool {
            let marker = Array(literal.utf8)
            guard bytes[index...].starts(with: marker) else { return false }
            index += marker.count
            return true
        }
    }
}
