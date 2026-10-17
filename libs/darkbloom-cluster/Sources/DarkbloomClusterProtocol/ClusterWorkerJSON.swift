import Foundation

/// Foundation JSON decoding discards duplicate keys and accepts 1.0 as Int.
/// Scan bounded protocol JSON first so neither ambiguity reaches agreement.
func validateClusterWorkerJSON(_ data: Data) throws {
    var scanner = ClusterWorkerJSONScanner(bytes: Array(data))
    try scanner.value(depth: 0)
    scanner.whitespace()
    guard scanner.offset == scanner.bytes.count else { throw ClusterWorkerProtocolError.invalid("Trailing worker JSON content") }
}

private struct ClusterWorkerJSONScanner {
    let bytes: [UInt8]
    var offset = 0

    mutating func whitespace() {
        while offset < bytes.count, [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 }
    }

    mutating func value(depth: Int) throws {
        guard depth <= 16 else { throw ClusterWorkerProtocolError.invalid("Worker JSON exceeds nesting limit") }
        whitespace()
        guard offset < bytes.count else { throw ClusterWorkerProtocolError.invalid("Truncated worker JSON value") }
        switch bytes[offset] {
        case 123: try object(depth: depth)
        case 91: try array(depth: depth)
        case 34: _ = try string()
        case 116: try literal("true")
        case 102: try literal("false")
        case 110: try literal("null")
        case 45, 48...57: try integer()
        default: throw ClusterWorkerProtocolError.invalid("Invalid worker JSON value")
        }
    }

    mutating func object(depth: Int) throws {
        offset += 1
        whitespace()
        if consume(125) { return }
        var keys = Set<String>()
        while true {
            whitespace()
            let key = try string()
            guard keys.insert(key).inserted else { throw ClusterWorkerProtocolError.invalid("Duplicate worker JSON key: \(key)") }
            whitespace()
            guard consume(58) else { throw ClusterWorkerProtocolError.invalid("Missing worker JSON colon") }
            try value(depth: depth + 1)
            whitespace()
            if consume(125) { return }
            guard consume(44) else { throw ClusterWorkerProtocolError.invalid("Missing worker JSON object delimiter") }
        }
    }

    mutating func array(depth: Int) throws {
        offset += 1
        whitespace()
        if consume(93) { return }
        while true {
            try value(depth: depth + 1)
            whitespace()
            if consume(93) { return }
            guard consume(44) else { throw ClusterWorkerProtocolError.invalid("Missing worker JSON array delimiter") }
        }
    }

    mutating func string() throws -> String {
        let start = offset
        guard consume(34) else { throw ClusterWorkerProtocolError.invalid("Worker JSON object keys must be strings") }
        while offset < bytes.count {
            let byte = bytes[offset]
            offset += 1
            if byte == 34 {
                // Decode escapes/UTF-8 before comparing keys, including \uXXXX aliases.
                return try JSONDecoder().decode(String.self, from: Data(bytes[start..<offset]))
            }
            guard byte >= 32 else { throw ClusterWorkerProtocolError.invalid("Unescaped worker JSON control byte") }
            if byte == 92 {
                guard offset < bytes.count else { throw ClusterWorkerProtocolError.invalid("Truncated worker JSON escape") }
                let escaped = bytes[offset]
                offset += 1
                if escaped == 117 {
                    guard offset + 4 <= bytes.count,
                        bytes[offset..<(offset + 4)].allSatisfy({
                            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
                        }) else { throw ClusterWorkerProtocolError.invalid("Invalid worker JSON Unicode escape") }
                    offset += 4
                } else if ![34, 92, 47, 98, 102, 110, 114, 116].contains(escaped) {
                    throw ClusterWorkerProtocolError.invalid("Invalid worker JSON string escape")
                }
            }
        }
        throw ClusterWorkerProtocolError.invalid("Unterminated worker JSON string")
    }

    mutating func integer() throws {
        let start = offset
        _ = consume(45)
        guard offset < bytes.count else { throw ClusterWorkerProtocolError.invalid("Truncated worker JSON integer") }
        if !consume(48) {
            guard (49...57).contains(bytes[offset]) else { throw ClusterWorkerProtocolError.invalid("Invalid worker JSON integer") }
            repeat { offset += 1 } while offset < bytes.count && (48...57).contains(bytes[offset])
        }
        guard offset - start <= 20 else { throw ClusterWorkerProtocolError.invalid("Worker JSON integer exceeds supported range") }
        if offset < bytes.count, [46, 69, 101].contains(bytes[offset]) {
            throw ClusterWorkerProtocolError.invalid("Worker protocol requires integer JSON syntax, not fractions or exponents")
        }
    }

    mutating func literal(_ text: String) throws {
        let expected = Array(text.utf8)
        guard offset + expected.count <= bytes.count,
            Array(bytes[offset..<(offset + expected.count)]) == expected else {
            throw ClusterWorkerProtocolError.invalid("Invalid worker JSON literal")
        }
        offset += expected.count
    }

    mutating func consume(_ byte: UInt8) -> Bool {
        guard offset < bytes.count, bytes[offset] == byte else { return false }
        offset += 1
        return true
    }
}
