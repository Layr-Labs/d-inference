import Foundation

enum SandboxJSONIntegrityError: Error, Equatable {
    case malformed
    case duplicateKey(String)
}

enum SandboxJSONIntegrity {
    static func requireNoDuplicateKeys(_ data: Data) throws {
        var parser = Parser(bytes: Array(data))
        try parser.parseDocument()
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func parseDocument() throws {
            skipWhitespace()
            try parseValue()
            skipWhitespace()
            guard index == bytes.count else {
                throw SandboxJSONIntegrityError.malformed
            }
        }

        private mutating func parseValue() throws {
            guard index < bytes.count else {
                throw SandboxJSONIntegrityError.malformed
            }
            switch bytes[index] {
            case CharacterByte.leftBrace:
                try parseObject()
            case CharacterByte.leftBracket:
                try parseArray()
            case CharacterByte.quote:
                _ = try parseString()
            default:
                try parsePrimitive()
            }
        }

        private mutating func parseObject() throws {
            try consume(CharacterByte.leftBrace)
            skipWhitespace()
            if consumeIfPresent(CharacterByte.rightBrace) {
                return
            }
            var keys = Set<String>()
            while true {
                skipWhitespace()
                let key = try parseString()
                guard keys.insert(key).inserted else {
                    throw SandboxJSONIntegrityError.duplicateKey(key)
                }
                skipWhitespace()
                try consume(CharacterByte.colon)
                skipWhitespace()
                try parseValue()
                skipWhitespace()
                if consumeIfPresent(CharacterByte.rightBrace) {
                    return
                }
                try consume(CharacterByte.comma)
            }
        }

        private mutating func parseArray() throws {
            try consume(CharacterByte.leftBracket)
            skipWhitespace()
            if consumeIfPresent(CharacterByte.rightBracket) {
                return
            }
            while true {
                try parseValue()
                skipWhitespace()
                if consumeIfPresent(CharacterByte.rightBracket) {
                    return
                }
                try consume(CharacterByte.comma)
                skipWhitespace()
            }
        }

        private mutating func parseString() throws -> String {
            let start = index
            try consume(CharacterByte.quote)
            while index < bytes.count {
                switch bytes[index] {
                case CharacterByte.quote:
                    index += 1
                    let encoded = Data(bytes[start..<index])
                    guard let decoded = try? JSONDecoder().decode(
                        String.self,
                        from: encoded
                    ) else {
                        throw SandboxJSONIntegrityError.malformed
                    }
                    return decoded
                case CharacterByte.backslash:
                    index += 1
                    guard index < bytes.count else {
                        throw SandboxJSONIntegrityError.malformed
                    }
                    if bytes[index] == CharacterByte.unicodeEscape {
                        guard index + 4 < bytes.count,
                              bytes[(index + 1)...(index + 4)].allSatisfy(
                                  CharacterByte.isHexDigit
                              )
                        else {
                            throw SandboxJSONIntegrityError.malformed
                        }
                        index += 5
                    } else {
                        index += 1
                    }
                case 0x00...0x1f:
                    throw SandboxJSONIntegrityError.malformed
                default:
                    index += 1
                }
            }
            throw SandboxJSONIntegrityError.malformed
        }

        private mutating func parsePrimitive() throws {
            let start = index
            while index < bytes.count {
                switch bytes[index] {
                case CharacterByte.comma,
                     CharacterByte.rightBrace,
                     CharacterByte.rightBracket,
                     CharacterByte.space,
                     CharacterByte.tab,
                     CharacterByte.lineFeed,
                     CharacterByte.carriageReturn:
                    guard index > start else {
                        throw SandboxJSONIntegrityError.malformed
                    }
                    return
                default:
                    index += 1
                }
            }
            guard index > start else {
                throw SandboxJSONIntegrityError.malformed
            }
        }

        private mutating func skipWhitespace() {
            while index < bytes.count {
                switch bytes[index] {
                case CharacterByte.space,
                     CharacterByte.tab,
                     CharacterByte.lineFeed,
                     CharacterByte.carriageReturn:
                    index += 1
                default:
                    return
                }
            }
        }

        private mutating func consume(_ expected: UInt8) throws {
            guard consumeIfPresent(expected) else {
                throw SandboxJSONIntegrityError.malformed
            }
        }

        private mutating func consumeIfPresent(_ expected: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == expected else {
                return false
            }
            index += 1
            return true
        }
    }

    private enum CharacterByte {
        static let quote: UInt8 = 0x22
        static let comma: UInt8 = 0x2c
        static let colon: UInt8 = 0x3a
        static let leftBracket: UInt8 = 0x5b
        static let backslash: UInt8 = 0x5c
        static let rightBracket: UInt8 = 0x5d
        static let leftBrace: UInt8 = 0x7b
        static let rightBrace: UInt8 = 0x7d
        static let unicodeEscape: UInt8 = 0x75
        static let tab: UInt8 = 0x09
        static let lineFeed: UInt8 = 0x0a
        static let carriageReturn: UInt8 = 0x0d
        static let space: UInt8 = 0x20

        static func isHexDigit(_ value: UInt8) -> Bool {
            (0x30...0x39).contains(value)
                || (0x41...0x46).contains(value)
                || (0x61...0x66).contains(value)
        }
    }
}
