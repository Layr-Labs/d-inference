import Foundation

/// A JSONC file (JSON with `//` and `/* */` comments and trailing commas, as OpenCode reads it) as byte ranges.
///
/// The OpenCode planner splices one member's bytes and never re-serialises the file, so this keeps where each object
/// and member is, not what the values are. It still reads the whole file, so a malformed one is refused, never edited.
struct JSONCDocument {
    struct Object {
        /// Offsets of the braces.
        let open: Int
        let close: Int
        let members: [Member]

        func members(named key: String) -> [Member] { members.filter { $0.key == key } }
    }

    struct Member {
        let key: String
        /// Offset of the key's opening quote.
        let keyStart: Int
        let value: Value
        /// Offset of the comma after the value, when there is one.
        let comma: Int?
    }

    struct Value {
        /// `start..<end` are the value's bytes.
        let start: Int
        let end: Int
        /// Set when the value is an object.
        let object: Object?
    }

    /// The file isn't JSONC; `line` is where reading stopped, counting from 1.
    struct Malformed: Error, Equatable {
        let line: Int
    }

    let bytes: [UInt8]
    let root: Value
    /// Every comment's bytes, `//` and `/*` included.
    let comments: [Range<Int>]

    init(_ bytes: [UInt8]) throws(Malformed) {
        var reader = Reader(bytes: bytes)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { reader.position = 3 }
        root = try reader.value()
        try reader.skipTrivia()
        guard reader.position == bytes.count else { throw reader.malformed(at: reader.position) }
        self.bytes = bytes
        comments = reader.comments
    }
}

private struct Reader {
    /// Deeper nesting than any config needs; it bounds the recursion on hostile input.
    static let maximumDepth = 256

    let bytes: [UInt8]
    var position = 0
    var comments: [Range<Int>] = []
    var depth = 0

    func malformed(at offset: Int) -> JSONCDocument.Malformed {
        JSONCDocument.Malformed(line: 1 + bytes[..<min(offset, bytes.count)].lazy.filter { $0 == 0x0A }.count)
    }

    private func byte(at offset: Int) -> UInt8? { offset < bytes.count ? bytes[offset] : nil }

    mutating func skipTrivia() throws(JSONCDocument.Malformed) {
        while let current = byte(at: position) {
            switch current {
            case 0x20, 0x09, 0x0A, 0x0D:
                position += 1
            case 0x2F where byte(at: position + 1) == 0x2F:
                let start = position
                while let next = byte(at: position), next != 0x0A { position += 1 }
                comments.append(start..<position)
            case 0x2F where byte(at: position + 1) == 0x2A:
                let start = position
                position += 2
                while !(byte(at: position) == 0x2A && byte(at: position + 1) == 0x2F) {
                    guard position < bytes.count else { throw malformed(at: start) }
                    position += 1
                }
                position += 2
                comments.append(start..<position)
            default:
                return
            }
        }
    }

    mutating func value() throws(JSONCDocument.Malformed) -> JSONCDocument.Value {
        try skipTrivia()
        let start = position
        guard let current = byte(at: position) else { throw malformed(at: start) }
        switch current {
        case 0x7B:
            let object = try self.object()
            return JSONCDocument.Value(start: start, end: position, object: object)
        case 0x5B:
            try array()
        case 0x22:
            _ = try string()
        case 0x2D, 0x30...0x39:
            try number()
        case 0x74, 0x66, 0x6E:
            try literal()
        default:
            throw malformed(at: start)
        }
        return JSONCDocument.Value(start: start, end: position, object: nil)
    }

    private mutating func object() throws(JSONCDocument.Malformed) -> JSONCDocument.Object {
        let open = position
        position += 1
        depth += 1
        defer { depth -= 1 }
        guard depth <= Self.maximumDepth else { throw malformed(at: open) }
        var members: [JSONCDocument.Member] = []
        while true {
            try skipTrivia()
            guard let current = byte(at: position) else { throw malformed(at: open) }
            if current == 0x7D {
                position += 1
                return JSONCDocument.Object(open: open, close: position - 1, members: members)
            }
            // After a member without a comma only the closing brace may follow.
            guard members.last.map({ $0.comma != nil }) ?? true, current == 0x22 else { throw malformed(at: position) }
            let keyStart = position
            let key = try string()
            try skipTrivia()
            guard byte(at: position) == 0x3A else { throw malformed(at: position) }
            position += 1
            let value = try self.value()
            try skipTrivia()
            var comma: Int?
            if byte(at: position) == 0x2C {
                comma = position
                position += 1
            }
            members.append(JSONCDocument.Member(key: key, keyStart: keyStart, value: value, comma: comma))
        }
    }

    private mutating func array() throws(JSONCDocument.Malformed) {
        let open = position
        position += 1
        depth += 1
        defer { depth -= 1 }
        guard depth <= Self.maximumDepth else { throw malformed(at: open) }
        var expectsComma = false
        while true {
            try skipTrivia()
            guard let current = byte(at: position) else { throw malformed(at: open) }
            if current == 0x5D {
                position += 1
                return
            }
            guard !expectsComma else { throw malformed(at: position) }
            _ = try value()
            try skipTrivia()
            if byte(at: position) == 0x2C {
                position += 1
            } else {
                expectsComma = true
            }
        }
    }

    /// The decoded string; `position` is at its opening quote.
    private mutating func string() throws(JSONCDocument.Malformed) -> String {
        let start = position
        position += 1
        var decoded: [UInt8] = []
        while true {
            guard let current = byte(at: position) else { throw malformed(at: start) }
            switch current {
            case 0x22:
                position += 1
                return String(decoding: decoded, as: UTF8.self)
            case 0x5C:
                guard let escaped = byte(at: position + 1) else { throw malformed(at: start) }
                position += 2
                switch escaped {
                case 0x22, 0x5C, 0x2F: decoded.append(escaped)
                case 0x62: decoded.append(0x08)
                case 0x66: decoded.append(0x0C)
                case 0x6E: decoded.append(0x0A)
                case 0x72: decoded.append(0x0D)
                case 0x74: decoded.append(0x09)
                case 0x75: decoded.append(contentsOf: try unicodeEscape())
                default: throw malformed(at: position - 2)
                }
            case 0x00..<0x20:
                throw malformed(at: position)
            default:
                decoded.append(current)
                position += 1
            }
        }
    }

    /// The UTF-8 of a `\uXXXX` escape (a surrogate pair takes two); `position` is after the `u`.
    private mutating func unicodeEscape() throws(JSONCDocument.Malformed) -> [UInt8] {
        let high = try hexQuad()
        var scalar = UInt32(high)
        if (0xD800...0xDBFF).contains(high) {
            guard byte(at: position) == 0x5C, byte(at: position + 1) == 0x75 else { throw malformed(at: position) }
            position += 2
            let low = try hexQuad()
            guard (0xDC00...0xDFFF).contains(low) else { throw malformed(at: position) }
            scalar = 0x10000 + ((UInt32(high) - 0xD800) << 10) + (UInt32(low) - 0xDC00)
        }
        guard let character = Unicode.Scalar(scalar) else { throw malformed(at: position) }
        return Array(String(character).utf8)
    }

    private mutating func hexQuad() throws(JSONCDocument.Malformed) -> UInt16 {
        guard position + 4 <= bytes.count,
              let text = String(bytes: bytes[position..<(position + 4)], encoding: .ascii),
              let value = UInt16(text, radix: 16) else { throw malformed(at: position) }
        position += 4
        return value
    }

    private mutating func number() throws(JSONCDocument.Malformed) {
        let start = position
        while let current = byte(at: position), (0x30...0x39).contains(current) || [0x2B, 0x2D, 0x2E, 0x45, 0x65].contains(current) {
            position += 1
        }
        guard let text = String(bytes: bytes[start..<position], encoding: .ascii), Double(text) != nil else {
            throw malformed(at: start)
        }
    }

    private mutating func literal() throws(JSONCDocument.Malformed) {
        for word in ["true", "false", "null"] {
            let spelled = Array(word.utf8)
            if bytes[position...].starts(with: spelled) {
                position += spelled.count
                return
            }
        }
        throw malformed(at: position)
    }
}
