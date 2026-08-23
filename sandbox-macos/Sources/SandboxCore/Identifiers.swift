import Foundation

public struct SandboxID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        self.init(rawValue: UUID())
    }

    public init?(_ value: String) {
        guard let uuid = UUID(uuidString: value) else {
            return nil
        }
        self.init(rawValue: uuid)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let parsed = SandboxID(value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "sandbox ID must be a UUID"
            )
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    public var description: String {
        rawValue.uuidString.lowercased()
    }
}

public struct SandboxGeneration: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: UInt64

    public init?(rawValue: UInt64) {
        guard rawValue > 0 else {
            return nil
        }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(UInt64.self)
        guard let parsed = SandboxGeneration(rawValue: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "sandbox generation must be greater than zero"
            )
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct SandboxFencingToken: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: UInt64

    public init?(rawValue: UInt64) {
        guard rawValue > 0 else {
            return nil
        }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(UInt64.self)
        guard let parsed = SandboxFencingToken(rawValue: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "sandbox fencing token must be greater than zero"
            )
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum SandboxDiskRole: String, Codable, CaseIterable, Hashable, Sendable {
    case bootDelta = "boot_delta"
    case workspace
    case auxiliaryStorage = "auxiliary_storage"
    case vmConfiguration = "vm_configuration"
}

public struct SandboxOperationScope: Codable, Hashable, Sendable {
    public let sandboxID: SandboxID
    public let generation: SandboxGeneration
    public let fencingToken: SandboxFencingToken

    public init(
        sandboxID: SandboxID,
        generation: SandboxGeneration,
        fencingToken: SandboxFencingToken
    ) {
        self.sandboxID = sandboxID
        self.generation = generation
        self.fencingToken = fencingToken
    }
}
