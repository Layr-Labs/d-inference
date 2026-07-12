import Foundation

public struct SMCKey: Hashable, Codable, Sendable, CustomStringConvertible,
    ExpressibleByStringLiteral
{
    public let rawValue: String

    public init(_ rawValue: String) throws {
        let bytes = Array(rawValue.utf8)
        guard bytes.count == 4, bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7e }) else {
            throw SMCError.invalidKey(rawValue)
        }
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        guard let key = try? SMCKey(value) else {
            preconditionFailure("SMC keys must contain exactly four printable ASCII bytes")
        }
        self = key
    }

    private enum CodingKeys: String, CodingKey {
        case rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(container.decode(String.self, forKey: .rawValue))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rawValue, forKey: .rawValue)
    }

    init(code: UInt32) {
        let bytes = [
            UInt8((code >> 24) & 0xff),
            UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff),
            UInt8(code & 0xff),
        ]
        self.rawValue = String(bytes: bytes, encoding: .ascii) ?? "????"
    }

    var code: UInt32 {
        rawValue.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    public var description: String { rawValue }
}

public struct SMCDataType: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard rawValue.utf8.count == 4 else {
            throw SMCError.invalidDataType(rawValue)
        }
        self.rawValue = rawValue
    }

    private enum CodingKeys: String, CodingKey {
        case rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(container.decode(String.self, forKey: .rawValue))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rawValue, forKey: .rawValue)
    }

    init(code: UInt32) {
        let bytes = [
            UInt8((code >> 24) & 0xff),
            UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff),
            UInt8(code & 0xff),
        ]
        self.rawValue = String(bytes: bytes, encoding: .ascii) ?? "????"
    }

    var code: UInt32 {
        rawValue.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    public var description: String { rawValue }
}

public struct SMCKeyInfo: Hashable, Codable, Sendable {
    public let dataSize: Int
    public let dataType: SMCDataType
    public let attributes: UInt8

    public init(dataSize: Int, dataType: SMCDataType, attributes: UInt8 = 0) {
        self.dataSize = dataSize
        self.dataType = dataType
        self.attributes = attributes
    }
}

public struct SMCValue: Hashable, Codable, Sendable {
    public let key: SMCKey
    public let info: SMCKeyInfo
    public let bytes: [UInt8]

    public init(key: SMCKey, info: SMCKeyInfo, bytes: [UInt8]) throws {
        guard info.dataSize >= 0, info.dataSize <= 32 else {
            throw SMCError.invalidDataSize(key: key, size: info.dataSize)
        }
        guard bytes.count == info.dataSize else {
            throw SMCError.dataLengthMismatch(
                key: key,
                expected: info.dataSize,
                actual: bytes.count
            )
        }
        self.key = key
        self.info = info
        self.bytes = bytes
    }

    public func float32() throws -> Double {
        try require(type: "flt ", size: 4)
        let bits = UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
        let value = Double(Float(bitPattern: bits))
        guard value.isFinite else {
            throw SMCError.nonFiniteValue(key: key)
        }
        return value
    }

    public func uint8() throws -> UInt8 {
        try require(type: "ui8 ", size: 1)
        return bytes[0]
    }

    public func number() throws -> Double {
        switch info.dataType.rawValue {
        case "flt ":
            return try float32()
        case "ui8 ":
            return Double(try uint8())
        case "ui16":
            try require(type: "ui16", size: 2)
            return Double(bigEndianUInt16())
        case "ui32":
            try require(type: "ui32", size: 4)
            return Double(bigEndianUInt32())
        case "fpe2":
            try require(type: "fpe2", size: 2)
            return Double(bigEndianUInt16()) / 4.0
        case "sp78":
            try require(type: "sp78", size: 2)
            return Double(Int16(bitPattern: bigEndianUInt16())) / 256.0
        case "sp1e":
            try require(type: "sp1e", size: 2)
            return Double(Int16(bitPattern: bigEndianUInt16())) / 16_384.0
        default:
            throw SMCError.unsupportedDataType(key: key, type: info.dataType)
        }
    }

    public static func float32Bytes(_ value: Double, key: SMCKey) throws -> [UInt8] {
        guard value.isFinite, value >= -Double(Float.greatestFiniteMagnitude),
              value <= Double(Float.greatestFiniteMagnitude)
        else {
            throw SMCError.nonFiniteValue(key: key)
        }
        let bits = Float(value).bitPattern
        return [
            UInt8(bits & 0xff),
            UInt8((bits >> 8) & 0xff),
            UInt8((bits >> 16) & 0xff),
            UInt8((bits >> 24) & 0xff),
        ]
    }

    private func require(type: String, size: Int) throws {
        guard info.dataType.rawValue == type else {
            throw SMCError.typeMismatch(
                key: key,
                expected: type,
                actual: info.dataType.rawValue
            )
        }
        guard info.dataSize == size else {
            throw SMCError.invalidDataSize(key: key, size: info.dataSize)
        }
    }

    private func bigEndianUInt16() -> UInt16 {
        (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
    }

    private func bigEndianUInt32() -> UInt32 {
        (UInt32(bytes[0]) << 24)
            | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8)
            | UInt32(bytes[3])
    }
}

public enum SMCOperation: String, Codable, Sendable {
    case open
    case readKeyInfo
    case readBytes
    case writeBytes
}

public enum SMCError: Error, Equatable, Sendable, CustomStringConvertible {
    case unsupportedPlatform
    case invalidKey(String)
    case invalidDataType(String)
    case invalidStructLayout(expected: Int, actual: Int)
    case serviceNotFound
    case openFailed(code: Int32)
    case callFailed(operation: SMCOperation, key: SMCKey?, code: Int32)
    case notPrivileged(operation: SMCOperation, key: SMCKey?)
    case keyNotFound(SMCKey)
    case firmwareRejected(operation: SMCOperation, key: SMCKey, result: UInt8)
    case invalidDataSize(key: SMCKey, size: Int)
    case dataLengthMismatch(key: SMCKey, expected: Int, actual: Int)
    case typeMismatch(key: SMCKey, expected: String, actual: String)
    case unsupportedDataType(key: SMCKey, type: SMCDataType)
    case nonFiniteValue(key: SMCKey)
    case systemQueryFailed(String)
    case injectedFailure(String)

    public var isNotPrivileged: Bool {
        if case .notPrivileged = self { return true }
        return false
    }

    public var isKeyNotFound: Bool {
        if case .keyNotFound = self { return true }
        return false
    }

    public var description: String {
        switch self {
        case .unsupportedPlatform:
            return "AppleSMC is available only on macOS"
        case .invalidKey(let key):
            return "invalid four-byte SMC key: \(key)"
        case .invalidDataType(let type):
            return "invalid four-byte SMC data type: \(type)"
        case .invalidStructLayout(let expected, let actual):
            return "AppleSMC ABI layout mismatch: expected \(expected) bytes, got \(actual)"
        case .serviceNotFound:
            return "AppleSMC service was not found"
        case .openFailed(let code):
            return "could not open AppleSMC (IOReturn \(code))"
        case .callFailed(let operation, let key, let code):
            return "AppleSMC \(operation.rawValue) failed for \(key?.rawValue ?? "<none>") (IOReturn \(code))"
        case .notPrivileged(let operation, let key):
            return "AppleSMC \(operation.rawValue) is not privileged for \(key?.rawValue ?? "<none>")"
        case .keyNotFound(let key):
            return "SMC key \(key) was not found"
        case .firmwareRejected(let operation, let key, let result):
            return String(
                format: "SMC firmware rejected %@ for %@ (0x%02x)",
                operation.rawValue,
                key.rawValue,
                result
            )
        case .invalidDataSize(let key, let size):
            return "SMC key \(key) reported invalid data size \(size)"
        case .dataLengthMismatch(let key, let expected, let actual):
            return "SMC key \(key) expected \(expected) bytes, got \(actual)"
        case .typeMismatch(let key, let expected, let actual):
            return "SMC key \(key) expected type \(expected), got \(actual)"
        case .unsupportedDataType(let key, let type):
            return "SMC key \(key) uses unsupported type \(type)"
        case .nonFiniteValue(let key):
            return "SMC key \(key) produced a non-finite value"
        case .systemQueryFailed(let query):
            return "system query failed: \(query)"
        case .injectedFailure(let message):
            return message
        }
    }
}
