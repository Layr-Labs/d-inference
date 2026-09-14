import Foundation

public enum SandboxResourceError: Error, Equatable, Sendable, CustomStringConvertible {
    case cpuOutsideRange(requested: UInt16, allowed: ClosedRange<UInt16>)
    case memoryOutsideRange(requested: UInt64, allowed: ClosedRange<UInt64>)
    case workspaceOutsideRange(requested: UInt64, allowed: ClosedRange<UInt64>)
    case commandTimeoutOutsideRange(requested: UInt32, allowed: ClosedRange<UInt32>)

    public var description: String {
        switch self {
        case .cpuOutsideRange(let requested, let allowed):
            return "requested \(requested) vCPU; allowed range is \(allowed.lowerBound)...\(allowed.upperBound)"
        case .memoryOutsideRange(let requested, let allowed):
            return "requested \(requested) memory bytes; allowed range is \(allowed.lowerBound)...\(allowed.upperBound)"
        case .workspaceOutsideRange(let requested, let allowed):
            return "requested \(requested) workspace bytes; allowed range is \(allowed.lowerBound)...\(allowed.upperBound)"
        case .commandTimeoutOutsideRange(let requested, let allowed):
            return "requested \(requested)s command timeout; allowed range is \(allowed.lowerBound)...\(allowed.upperBound)s"
        }
    }
}

public struct SandboxResourcePolicy: Equatable, Sendable {
    public static let gibibyte: UInt64 = 1_073_741_824

    public let cpuCount: ClosedRange<UInt16>
    public let memoryBytes: ClosedRange<UInt64>
    public let workspaceBytes: ClosedRange<UInt64>
    public let commandTimeoutSeconds: ClosedRange<UInt32>

    public init(
        cpuCount: ClosedRange<UInt16>,
        memoryBytes: ClosedRange<UInt64>,
        workspaceBytes: ClosedRange<UInt64>,
        commandTimeoutSeconds: ClosedRange<UInt32>
    ) {
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
        self.workspaceBytes = workspaceBytes
        self.commandTimeoutSeconds = commandTimeoutSeconds
    }

    public static let alpha = SandboxResourcePolicy(
        cpuCount: 1...64,
        memoryBytes: (2 * gibibyte)...(512 * gibibyte),
        workspaceBytes: (25 * gibibyte)...(50 * gibibyte),
        commandTimeoutSeconds: 1...900
    )

    public func validate(_ specification: SandboxResourceSpecification) throws {
        guard cpuCount.contains(specification.cpuCount) else {
            throw SandboxResourceError.cpuOutsideRange(
                requested: specification.cpuCount,
                allowed: cpuCount
            )
        }
        guard memoryBytes.contains(specification.memoryBytes) else {
            throw SandboxResourceError.memoryOutsideRange(
                requested: specification.memoryBytes,
                allowed: memoryBytes
            )
        }
        guard workspaceBytes.contains(specification.workspaceBytes) else {
            throw SandboxResourceError.workspaceOutsideRange(
                requested: specification.workspaceBytes,
                allowed: workspaceBytes
            )
        }
        guard commandTimeoutSeconds.contains(specification.commandTimeoutSeconds) else {
            throw SandboxResourceError.commandTimeoutOutsideRange(
                requested: specification.commandTimeoutSeconds,
                allowed: commandTimeoutSeconds
            )
        }
    }
}

public struct SandboxResourceSpecification: Codable, Equatable, Sendable {
    public let cpuCount: UInt16
    public let memoryBytes: UInt64
    public let workspaceBytes: UInt64
    public let commandTimeoutSeconds: UInt32

    public init(
        cpuCount: UInt16,
        memoryBytes: UInt64,
        workspaceBytes: UInt64,
        commandTimeoutSeconds: UInt32,
        policy: SandboxResourcePolicy = .alpha
    ) throws {
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
        self.workspaceBytes = workspaceBytes
        self.commandTimeoutSeconds = commandTimeoutSeconds
        try policy.validate(self)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                cpuCount: container.decode(UInt16.self, forKey: .cpuCount),
                memoryBytes: container.decode(UInt64.self, forKey: .memoryBytes),
                workspaceBytes: container.decode(UInt64.self, forKey: .workspaceBytes),
                commandTimeoutSeconds: container.decode(
                    UInt32.self,
                    forKey: .commandTimeoutSeconds
                )
            )
        } catch let error as SandboxResourceError {
            throw DecodingError.dataCorruptedError(
                forKey: .cpuCount,
                in: container,
                debugDescription: error.description
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cpuCount, forKey: .cpuCount)
        try container.encode(memoryBytes, forKey: .memoryBytes)
        try container.encode(workspaceBytes, forKey: .workspaceBytes)
        try container.encode(commandTimeoutSeconds, forKey: .commandTimeoutSeconds)
    }

    public static func macOSSmall(
        commandTimeoutSeconds: UInt32 = 900
    ) throws -> SandboxResourceSpecification {
        try SandboxResourceSpecification(
            cpuCount: 4,
            memoryBytes: 8 * SandboxResourcePolicy.gibibyte,
            workspaceBytes: 25 * SandboxResourcePolicy.gibibyte,
            commandTimeoutSeconds: commandTimeoutSeconds
        )
    }

    private enum CodingKeys: String, CodingKey {
        case cpuCount
        case memoryBytes
        case workspaceBytes
        case commandTimeoutSeconds
    }
}
