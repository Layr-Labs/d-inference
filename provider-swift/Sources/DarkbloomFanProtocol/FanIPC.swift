import Foundation

public enum FanIPC {
    public static let machServiceName = "io.darkbloom.fan"
    public static let protocolVersion = 1
    public static let helperVersion = "1"
    public static let helperIdentifier = "io.darkbloom.fan-helper"
    public static let providerIdentifier = "io.darkbloom.provider"
    public static let teamID = "SLDQ2GJ6TL"
    public static let leaseDurationSeconds: TimeInterval = 15
    public static let renewalIntervalSeconds: TimeInterval = 5
}

@objc public protocol DarkbloomFanHelperProtocol {
    func renewProviderActivity(
        protocolVersion: Int,
        providerVersion: String,
        withReply reply: @escaping @Sendable (Data) -> Void
    )

    func releaseProviderActivity(withReply reply: @escaping @Sendable (Data) -> Void)

    func status(withReply reply: @escaping @Sendable (Data) -> Void)

    /// Emergency recovery for the root CLI. The helper independently verifies
    /// that the XPC peer is both Darkbloom-signed and running as root.
    func restoreAutomatic(withReply reply: @escaping @Sendable (Data) -> Void)
}

public struct FanIPCReply: Codable, Equatable, Sendable {
    public let ok: Bool
    public let message: String?
    public let helperVersion: String
    public let protocolVersion: Int

    public init(
        ok: Bool,
        message: String? = nil,
        helperVersion: String = FanIPC.helperVersion,
        protocolVersion: Int = FanIPC.protocolVersion
    ) {
        self.ok = ok
        self.message = message
        self.helperVersion = helperVersion
        self.protocolVersion = protocolVersion
    }
}

public enum FanServiceMode: String, Codable, Equatable, Sendable {
    case disabled
    case waitingForProvider = "waiting_for_provider"
    case waitingForTemperature = "waiting_for_temperature"
    case manual
    case safetyOverride = "safety_override"
    case unsupported
    case error
}

public struct FanServiceFanStatus: Codable, Equatable, Sendable {
    public let index: Int
    public let actualRPM: Double?
    public let targetRPM: Double?
    public let minimumRPM: Double?
    public let maximumRPM: Double?
    public let mode: String?

    public init(
        index: Int,
        actualRPM: Double?,
        targetRPM: Double?,
        minimumRPM: Double?,
        maximumRPM: Double?,
        mode: String?
    ) {
        self.index = index
        self.actualRPM = actualRPM
        self.targetRPM = targetRPM
        self.minimumRPM = minimumRPM
        self.maximumRPM = maximumRPM
        self.mode = mode
    }
}

public struct FanServiceStatus: Codable, Equatable, Sendable {
    public let helperVersion: String
    public let protocolVersion: Int
    public let enabled: Bool
    public let configuredUID: UInt32
    public let providerActive: Bool
    public let mode: FanServiceMode
    public let chip: String
    public let gpuSensorKeys: [String]
    public let gpuTemperatureC: Double?
    public let triggerTemperatureC: Double
    public let releaseTemperatureC: Double
    public let speedPercent: Double
    public let fans: [FanServiceFanStatus]
    public let lastError: String?
    public let hardwareReady: Bool?
    public let recoveryPending: Bool?
    public let discoveryError: String?
    public let quarantinedSensorKeys: [String]?
    public let updatedAt: Date

    public init(
        helperVersion: String = FanIPC.helperVersion,
        protocolVersion: Int = FanIPC.protocolVersion,
        enabled: Bool,
        configuredUID: UInt32,
        providerActive: Bool,
        mode: FanServiceMode,
        chip: String,
        gpuSensorKeys: [String],
        gpuTemperatureC: Double?,
        triggerTemperatureC: Double,
        releaseTemperatureC: Double,
        speedPercent: Double,
        fans: [FanServiceFanStatus],
        lastError: String?,
        hardwareReady: Bool? = nil,
        recoveryPending: Bool? = nil,
        discoveryError: String? = nil,
        quarantinedSensorKeys: [String]? = nil,
        updatedAt: Date = Date()
    ) {
        self.helperVersion = helperVersion
        self.protocolVersion = protocolVersion
        self.enabled = enabled
        self.configuredUID = configuredUID
        self.providerActive = providerActive
        self.mode = mode
        self.chip = chip
        self.gpuSensorKeys = gpuSensorKeys
        self.gpuTemperatureC = gpuTemperatureC
        self.triggerTemperatureC = triggerTemperatureC
        self.releaseTemperatureC = releaseTemperatureC
        self.speedPercent = speedPercent
        self.fans = fans
        self.lastError = lastError
        self.hardwareReady = hardwareReady
        self.recoveryPending = recoveryPending
        self.discoveryError = discoveryError
        self.quarantinedSensorKeys = quarantinedSensorKeys
        self.updatedAt = updatedAt
    }
}

public enum FanIPCCoding {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
