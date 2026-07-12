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

    public init(
        helper: URL,
        launchDaemonPlist: URL,
        configuration: URL,
        sessionJournal: URL
    ) {
        self.helper = helper
        self.launchDaemonPlist = launchDaemonPlist
        self.configuration = configuration
        self.sessionJournal = sessionJournal
    }

    public static let production = FanServicePaths(
        helper: URL(fileURLWithPath: "/Library/PrivilegedHelperTools/io.darkbloom.fan-helper"),
        launchDaemonPlist: URL(fileURLWithPath: "/Library/LaunchDaemons/io.darkbloom.fan.plist"),
        configuration: URL(fileURLWithPath: "/Library/Application Support/Darkbloom/fan-policy.json"),
        sessionJournal: URL(fileURLWithPath: "/Library/Application Support/Darkbloom/fan-session.json")
    )
}

public struct FanSessionJournal: Equatable, Codable, Sendable {
    public let fanIndices: [Int]
    public let ownsFtst: Bool

    public init(fanIndices: [Int], ownsFtst: Bool) {
        self.fanIndices = Array(Set(fanIndices)).sorted()
        self.ownsFtst = ownsFtst
    }
}
