import DarkbloomFanCore
import Foundation

public struct FanServiceConfiguration: Equatable, Codable, Sendable {
    public static let schemaVersion = 1

    public let schema: Int
    public let enabled: Bool
    public let configuredUID: UInt32
    public let configuredUserUUID: String
    public let policy: FanPolicyConfiguration

    public init(
        enabled: Bool,
        configuredUID: UInt32,
        configuredUserUUID: String,
        policy: FanPolicyConfiguration = .defaults
    ) {
        self.schema = Self.schemaVersion
        self.enabled = enabled
        self.configuredUID = configuredUID
        self.configuredUserUUID = configuredUserUUID
        self.policy = policy
    }

    private enum CodingKeys: String, CodingKey {
        case schema
        case enabled
        case configuredUID = "configured_uid"
        case configuredUserUUID = "configured_user_uuid"
        case policy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schema = try container.decode(Int.self, forKey: .schema)
        guard schema == Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schema,
                in: container,
                debugDescription: "unsupported fan configuration schema \(schema)"
            )
        }
        let enabled = try container.decode(Bool.self, forKey: .enabled)
        let configuredUID = try container.decode(UInt32.self, forKey: .configuredUID)
        let configuredUserUUID = try container.decode(
            String.self,
            forKey: .configuredUserUUID
        )
        guard UUID(uuidString: configuredUserUUID) != nil else {
            throw DecodingError.dataCorruptedError(
                forKey: .configuredUserUUID,
                in: container,
                debugDescription: "configured user UUID is invalid"
            )
        }
        let decodedPolicy = try container.decode(
            FanPolicyConfiguration.self,
            forKey: .policy
        )
        let policy = try FanPolicyConfiguration(
            triggerCelsius: decodedPolicy.triggerCelsius,
            releaseCelsius: decodedPolicy.releaseCelsius,
            speedPercent: decodedPolicy.speedPercent,
            engageSampleCount: decodedPolicy.engageSampleCount,
            releaseSampleCount: decodedPolicy.releaseSampleCount
        )

        self.schema = schema
        self.enabled = enabled
        self.configuredUID = configuredUID
        self.configuredUserUUID = configuredUserUUID
        self.policy = policy
    }
}

public struct FanServicePaths: Equatable, Sendable {
    public let helper: URL
    public let launchDaemonPlist: URL
    public let configuration: URL
    public let sessionJournal: URL
    public let lastFailure: URL
    public let sensorBaseline: URL

    public init(
        helper: URL,
        launchDaemonPlist: URL,
        configuration: URL,
        sessionJournal: URL,
        lastFailure: URL? = nil,
        sensorBaseline: URL? = nil
    ) {
        self.helper = helper
        self.launchDaemonPlist = launchDaemonPlist
        self.configuration = configuration
        self.sessionJournal = sessionJournal
        self.lastFailure = lastFailure
            ?? sessionJournal.deletingLastPathComponent()
            .appendingPathComponent("fan-last-failure.json")
        self.sensorBaseline = sensorBaseline
            ?? sessionJournal.deletingLastPathComponent()
            .appendingPathComponent("fan-sensor-baseline.json")
    }

    public static let production = FanServicePaths(
        helper: URL(fileURLWithPath: "/Library/PrivilegedHelperTools/io.darkbloom.fan-helper"),
        launchDaemonPlist: URL(fileURLWithPath: "/Library/LaunchDaemons/io.darkbloom.fan.plist"),
        configuration: URL(fileURLWithPath: "/Library/Application Support/Darkbloom/fan-policy.json"),
        sessionJournal: URL(fileURLWithPath: "/Library/Application Support/Darkbloom/fan-session.json"),
        lastFailure: URL(fileURLWithPath: "/Library/Application Support/Darkbloom/fan-last-failure.json"),
        sensorBaseline: URL(fileURLWithPath: "/Library/Application Support/Darkbloom/fan-sensor-baseline.json")
    )
}

public struct FanSessionJournal: Equatable, Codable, Sendable {
    public let fanIndices: [Int]
    public let ownsFtst: Bool
    public let verifyAllFans: Bool
    public let verificationFanIndices: [Int]
    public let minimumVerificationFanCount: Int

    public init(
        fanIndices: [Int],
        ownsFtst: Bool,
        verifyAllFans: Bool = false,
        verificationFanIndices: [Int] = [],
        minimumVerificationFanCount: Int = 0
    ) {
        self.fanIndices = Array(Set(fanIndices)).sorted()
        self.ownsFtst = ownsFtst
        self.verifyAllFans = verifyAllFans
        self.verificationFanIndices = Array(Set(
            verificationFanIndices
        )).sorted()
        self.minimumVerificationFanCount = max(
            0,
            minimumVerificationFanCount
        )
    }

    private enum CodingKeys: String, CodingKey {
        case fanIndices
        case ownsFtst
        case verifyAllFans
        case verificationFanIndices
        case minimumVerificationFanCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fanIndices = try container.decode([Int].self, forKey: .fanIndices)
        let verificationFanIndices = try container.decodeIfPresent(
            [Int].self,
            forKey: .verificationFanIndices
        ) ?? []
        let minimumVerificationFanCount = try container.decodeIfPresent(
            Int.self,
            forKey: .minimumVerificationFanCount
        ) ?? 0
        guard fanIndices.allSatisfy({
            (0..<FanHardwareReader.maximumSupportedFans).contains($0)
        }),
        verificationFanIndices.allSatisfy({
            (0..<FanHardwareReader.maximumSupportedFans).contains($0)
        }),
        (0...FanHardwareReader.maximumSupportedFans).contains(
            minimumVerificationFanCount
        )
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .fanIndices,
                in: container,
                debugDescription: "fan ownership journal bounds are invalid"
            )
        }
        self.init(
            fanIndices: fanIndices,
            ownsFtst: try container.decode(Bool.self, forKey: .ownsFtst),
            verifyAllFans: try container.decodeIfPresent(
                Bool.self,
                forKey: .verifyAllFans
            ) ?? false,
            verificationFanIndices: verificationFanIndices,
            minimumVerificationFanCount: minimumVerificationFanCount
        )
    }
}

public struct FanLastFailure: Equatable, Codable, Sendable {
    public static let schemaVersion = 1
    private static let maximumMessageCharacters = 4_096

    public let schema: Int
    public let message: String
    public let occurredAt: Date

    public init(message: String, occurredAt: Date = Date()) {
        self.schema = Self.schemaVersion
        self.message = String(message.prefix(Self.maximumMessageCharacters))
        self.occurredAt = occurredAt
    }

    private enum CodingKeys: String, CodingKey {
        case schema
        case message
        case occurredAt = "occurred_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schema = try container.decode(Int.self, forKey: .schema)
        guard schema == Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schema,
                in: container,
                debugDescription: "unsupported fan failure schema \(schema)"
            )
        }
        let message = try container.decode(String.self, forKey: .message)
        guard !message.isEmpty, message.count <= Self.maximumMessageCharacters else {
            throw DecodingError.dataCorruptedError(
                forKey: .message,
                in: container,
                debugDescription: "fan failure message is invalid"
            )
        }
        self.schema = schema
        self.message = message
        self.occurredAt = try container.decode(Date.self, forKey: .occurredAt)
    }
}

public struct FanSensorBaseline: Equatable, Codable, Sendable {
    public static let schemaVersion = 1

    public let schema: Int
    public let chipFamily: FanChipFamily
    public let sensorKeys: [SMCKey]

    public init(chipFamily: FanChipFamily, sensorKeys: [SMCKey]) {
        self.schema = Self.schemaVersion
        self.chipFamily = chipFamily
        self.sensorKeys = Array(Set(sensorKeys)).sorted {
            $0.rawValue < $1.rawValue
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schema
        case chipFamily = "chip_family"
        case sensorKeys = "sensor_keys"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schema = try container.decode(Int.self, forKey: .schema)
        guard schema == Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schema,
                in: container,
                debugDescription: "unsupported fan sensor baseline schema \(schema)"
            )
        }
        let chipFamily = try container.decode(
            FanChipFamily.self,
            forKey: .chipFamily
        )
        let sensorKeys = try container.decode(
            [SMCKey].self,
            forKey: .sensorKeys
        )
        let unique = Set(sensorKeys)
        let catalog = Set(GPUTemperatureCatalog.keys(for: chipFamily))
        guard !unique.isEmpty,
              unique.count == sensorKeys.count,
              unique.isSubset(of: catalog)
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .sensorKeys,
                in: container,
                debugDescription: "fan sensor baseline is invalid"
            )
        }
        self.schema = schema
        self.chipFamily = chipFamily
        self.sensorKeys = sensorKeys.sorted { $0.rawValue < $1.rawValue }
    }
}
