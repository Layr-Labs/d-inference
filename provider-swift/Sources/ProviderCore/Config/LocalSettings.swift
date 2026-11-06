import Foundation

/// The `[local]` section of `provider.toml`: how this Mac serves its owner beside, or instead of, Darkbloom.
public struct LocalSettings: Sendable, Equatable, Codable {
    public enum Mode: String, Sendable, Equatable, CaseIterable {
        case local
        case network
        case both
    }

    public enum Route: String, Sendable, Equatable, CaseIterable {
        case thisMac = "this-mac"
        case myMacs = "my-macs"
        case myMacsFirst = "my-macs-first"
    }

    public var mode: Mode?
    public var meFirst: Bool?
    public var meFirstIdleMinutes: UInt64?
    public var route: Route?
    public var port: UInt16?
    public var bind: String?

    public static let defaultMeFirstIdleMinutes: UInt64 = 10
    public static let meFirstIdleMinutesRange: ClosedRange<UInt64> = 1...120
    public static let defaultBind = "127.0.0.1"

    public init(mode: Mode? = nil, meFirst: Bool? = nil, meFirstIdleMinutes: UInt64? = nil, route: Route? = nil,
                port: UInt16? = nil, bind: String? = nil) {
        self.mode = mode
        self.meFirst = meFirst
        self.meFirstIdleMinutes = meFirstIdleMinutes
        self.route = route
        self.port = port
        self.bind = bind
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case mode
        case meFirst = "me_first"
        case meFirstIdleMinutes = "me_first_idle_minutes"
        case route
        case port
        case bind
    }

    public init(from decoder: Decoder) throws {
        self.init()
    }

    public func encode(to encoder: Encoder) throws {}

    public func validate() throws {}

    public static func launchMode(local: Bool, localEndpoint: Bool) -> Mode {
        if local { return .local }
        return localEndpoint ? .both : .network
    }

    public func resolvedMode(local: Bool, localEndpoint: Bool) -> Mode {
        mode ?? Self.launchMode(local: local, localEndpoint: localEndpoint)
    }

    public func meFirstEnabled(in mode: Mode) -> Bool {
        mode == .both && meFirst != false
    }

    public var resolvedMeFirstIdleMinutes: UInt64 { meFirstIdleMinutes ?? Self.defaultMeFirstIdleMinutes }

    public func resolvedRoute(accountKeySaved: Bool) -> Route {
        route ?? (accountKeySaved ? .myMacs : .thisMac)
    }

    public var resolvedPort: UInt16 { port ?? BuildEnvironment.current.defaultLocalPort }

    public var resolvedBind: String { bind ?? Self.defaultBind }
}

public struct LocalSettingsError: Error, Equatable, CustomStringConvertible {
    public let key: String?
    public let description: String
}

extension ConfigManager {
    @discardableResult
    public static func updateLocal(at path: URL, fallbackConfig: ProviderConfig,
                                   _ change: (inout LocalSettings) throws -> Void) throws -> Bool {
        false
    }

    static func updatingLocal(_ original: String?, fallbackConfig: ProviderConfig,
                              _ change: (inout LocalSettings) throws -> Void) throws -> String? {
        nil
    }
}
