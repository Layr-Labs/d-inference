import Foundation
import TOMLKit

/// The `[local]` section of `provider.toml`: how this Mac serves its owner beside, or instead of, Darkbloom.
///
/// Every key is optional. An absent key keeps today's behaviour, and a written default never shadows a later
/// built-in change (`TOMLEncoder` writes every non-optional key). The `resolved…` members give the effective values.
/// `ConfigManager.updateLocal` writes the section without touching anything else in the file.
public struct LocalSettings: Sendable, Equatable, Codable {
    /// How this Mac serves (`mode`).
    public enum Mode: String, Sendable, Equatable, CaseIterable {
        /// Only me, on this Mac: the local API only; Darkbloom never contacts this Mac.
        case local
        /// Darkbloom network: coordinator serving only, no local API.
        case network
        /// Both, me first: the local API beside Darkbloom.
        case both
    }

    /// Where the owner's requests go when this Mac can't take them (`route`).
    public enum Route: String, Sendable, Equatable, CaseIterable {
        /// Only this Mac.
        case thisMac = "this-mac"
        /// Only my Macs: the coordinator with `X-Darkbloom-Route: self`, free.
        case myMacs = "my-macs"
        /// My Macs first, then the Darkbloom network: the coordinator with `X-Darkbloom-Route: prefer`, billed when the
        /// network answers; at a zero balance, `self` once.
        case myMacsFirst = "my-macs-first"
    }

    public var mode: Mode?
    /// With `mode = both`: pause Darkbloom traffic while the owner uses this Mac.
    public var meFirst: Bool?
    /// Minutes with no owner request before Darkbloom traffic resumes (`meFirstIdleMinutesRange`).
    public var meFirstIdleMinutes: UInt64?
    public var route: Route?
    /// The local API's port; nil is the build's `defaultLocalPort`.
    public var port: UInt16?
    /// The local API's address: `localhost` or a numeric IPv4 or IPv6 address.
    public var bind: String?

    /// The owner's default: Darkbloom traffic resumes two minutes after the owner's last request.
    public static let defaultMeFirstIdleMinutes: UInt64 = 2
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

    enum CodingKeys: String, CodingKey {
        case mode
        case meFirst = "me_first"
        case meFirstIdleMinutes = "me_first_idle_minutes"
        case route
        case port
        case bind
    }
}

// MARK: - Effective values

extension LocalSettings {
    /// The mode today's launch flags select, used while `mode` is absent: plain `start` serves Darkbloom, `--local`
    /// only this Mac's API, and `--local-endpoint` both.
    public static func launchMode(local: Bool, localEndpoint: Bool) -> Mode {
        if local { return .local }
        return localEndpoint ? .both : .network
    }

    /// The saved mode, else the one the launch flags select.
    public func resolvedMode(local: Bool, localEndpoint: Bool) -> Mode {
        mode ?? Self.launchMode(local: local, localEndpoint: localEndpoint)
    }

    /// Whether Darkbloom traffic pauses while the owner uses this Mac. Only `both` serves Darkbloom and the owner
    /// from one Mac; there it is on unless `me_first = false`, which keeps today's shared serving.
    public func meFirstEnabled(in mode: Mode) -> Bool {
        mode == .both && meFirst != false
    }

    public var resolvedMeFirstIdleMinutes: UInt64 { meFirstIdleMinutes ?? Self.defaultMeFirstIdleMinutes }

    /// How long the owner stays idle before Darkbloom traffic resumes, for a provider started with these launch flags
    /// (as `launchMode` reads them); nil where me first does not apply. It applies only where Darkbloom and the owner
    /// share this Mac: a coordinator connection, which `--local` never has, with the local API beside it, in a mode
    /// where `meFirstEnabled` holds.
    public func meFirstIdle(local: Bool, localEndpoint: Bool) -> Duration? {
        guard !local, localEndpoint, meFirstEnabled(in: resolvedMode(local: local, localEndpoint: localEndpoint))
        else { return nil }
        // Validation keeps the minutes in range; the bound only keeps the arithmetic total.
        return .seconds(60 * Int64(Swift.min(resolvedMeFirstIdleMinutes, Self.meFirstIdleMinutesRange.upperBound)))
    }

    /// The saved route, else this Mac only (today's behaviour) or, once an account key is saved, only my Macs.
    public func resolvedRoute(accountKeySaved: Bool) -> Route {
        route ?? (accountKeySaved ? .myMacs : .thisMac)
    }

    public var resolvedPort: UInt16 { port ?? BuildEnvironment.current.defaultLocalPort }

    public var resolvedBind: String { bind ?? Self.defaultBind }
}

// MARK: - Coding and validation

extension LocalSettings {
    public init(from decoder: Decoder) throws {
        let container: Container
        do {
            container = try decoder.container(keyedBy: CodingKeys.self)
        } catch {
            throw LocalSettingsError.notASection
        }
        self.init(
            mode: try Self.choice(Mode.self, .mode, in: container),
            meFirst: try Self.value(Bool.self, .meFirst, in: container),
            meFirstIdleMinutes: try Self.wholeNumber(UInt64.self, .meFirstIdleMinutes, in: container),
            route: try Self.choice(Route.self, .route, in: container),
            port: try Self.wholeNumber(UInt16.self, .port, in: container),
            bind: try Self.value(String.self, .bind, in: container))
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(mode?.rawValue, forKey: .mode)
        try container.encodeIfPresent(meFirst, forKey: .meFirst)
        try container.encodeIfPresent(meFirstIdleMinutes, forKey: .meFirstIdleMinutes)
        try container.encodeIfPresent(route?.rawValue, forKey: .route)
        try container.encodeIfPresent(port, forKey: .port)
        try container.encodeIfPresent(bind, forKey: .bind)
    }

    /// Refuses a value this build does not take, with the words decoding uses.
    public func validate() throws {
        if let minutes = meFirstIdleMinutes, !Self.meFirstIdleMinutesRange.contains(minutes) {
            throw LocalSettingsError(.meFirstIdleMinutes, found: "\(minutes)")
        }
        if port == 0 {
            throw LocalSettingsError(.port, found: "0")
        }
        if let bind, !ClusterServingScope.isValidBind(bind) {
            throw LocalSettingsError(.bind, found: LocalSettingsError.quoted(bind))
        }
    }

    private typealias Container = KeyedDecodingContainer<CodingKeys>

    private static func value<T: Decodable>(_ type: T.Type, _ key: CodingKeys, in container: Container) throws -> T? {
        guard container.contains(key) else { return nil }
        do {
            return try container.decode(T.self, forKey: key)
        } catch {
            throw LocalSettingsError(key, found: written(key, in: container))
        }
    }

    private static func choice<T: RawRepresentable>(
        _ type: T.Type, _ key: CodingKeys, in container: Container
    ) throws -> T? where T.RawValue == String {
        guard let text = try value(String.self, key, in: container) else { return nil }
        guard let choice = T(rawValue: text) else {
            throw LocalSettingsError(key, found: LocalSettingsError.quoted(text))
        }
        return choice
    }

    /// Read as `Int` and narrowed here: TOMLKit traps narrowing an out-of-range integer itself.
    private static func wholeNumber<T: FixedWidthInteger>(
        _ type: T.Type, _ key: CodingKeys, in container: Container
    ) throws -> T? {
        guard let number = try value(Int.self, key, in: container) else { return nil }
        guard let narrowed = T(exactly: number) else {
            throw LocalSettingsError(key, found: "\(number)")
        }
        return narrowed
    }

    /// The value as the file has it, for a refusal; nil for an array or a table.
    private static func written(_ key: CodingKeys, in container: Container) -> String? {
        if let text = try? container.decode(String.self, forKey: key) { return LocalSettingsError.quoted(text) }
        if let number = try? container.decode(Int.self, forKey: key) { return "\(number)" }
        if let number = try? container.decode(Double.self, forKey: key) { return "\(number)" }
        if let flag = try? container.decode(Bool.self, forKey: key) { return "\(flag)" }
        return nil
    }
}

/// A `[local]` value this build refuses, said plainly: the key, what it takes, and what the file has.
public struct LocalSettingsError: Error, Equatable, CustomStringConvertible {
    /// The refused key (`me_first_idle_minutes`); nil when `local` is not a section at all.
    public let key: String?
    public let description: String

    init(_ key: LocalSettings.CodingKeys, found: String?) {
        self.key = key.rawValue
        let rule = "[local] \(key.rawValue) must be \(key.takes)"
        description = found.map { "\(rule), not \($0)." } ?? "\(rule)."
    }

    private init(key: String?, description: String) {
        self.key = key
        self.description = description
    }

    static let notASection = LocalSettingsError(key: nil, description:
        #"[local] must be a section (a [local] line followed by settings such as mode = "both"), not a single value."#)

    /// `text` in double quotes, with quotes, backslashes and control characters escaped so a refusal stays one line.
    /// (TOMLKit replaces `String.debugDescription` with the bare string.)
    static func quoted(_ text: String) -> String {
        var escaped = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case _ where scalar.properties.generalCategory == .control: escaped += scalar.escaped(asASCII: true)
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return "\"\(escaped)\""
    }
}

extension LocalSettings.CodingKeys {
    /// What the key takes, in the words a refusal uses.
    var takes: String {
        switch self {
        case .mode:
            return #""local" (only you, on this Mac), "network" (the Darkbloom network only) or "both" (both, you first)"#
        case .meFirst:
            return "true or false"
        case .meFirstIdleMinutes:
            let range = LocalSettings.meFirstIdleMinutesRange
            return "a whole number of minutes from \(range.lowerBound) to \(range.upperBound)"
        case .route:
            return #""this-mac" (only this Mac), "my-macs" (only your Macs) or "my-macs-first" (your Macs first, then the Darkbloom network)"#
        case .port:
            return "a whole number from 1 to 65535"
        case .bind:
            return "localhost or a numeric IPv4 or IPv6 address, such as 127.0.0.1"
        }
    }
}

// MARK: - Write-preserving edit

extension ConfigManager {
    /// Changes the values of `[local]` in the provider config at `path` and no other value: unknown keys, in `[local]`
    /// or anywhere else, keep their values, so a newer build's settings survive an older build's edit. Comments are
    /// dropped and keys re-sorted, as with every config writer. A refused value throws
    /// `LocalSettingsError` before anything is written, a change the file already holds writes nothing, and an explicit
    /// value is written even when it equals the default. Without a file, `fallbackConfig` (the caller's resolved
    /// configuration) is written with the new `[local]`. Returns whether the file changed.
    @discardableResult
    public static func updateLocal(at path: URL, fallbackConfig: ProviderConfig,
                                   _ change: (inout LocalSettings) throws -> Void) throws -> Bool {
        try withExclusiveConfigLock(at: path) {
            let original: String?
            do {
                original = FileManager.default.fileExists(atPath: path.path)
                    ? try String(contentsOf: path, encoding: .utf8) : nil
            } catch {
                throw ConfigError.readFailed(path: path.path, underlying: error)
            }
            guard let updated = try updatingLocal(original, fallbackConfig: fallbackConfig, change) else { return false }
            do {
                try ProviderConfigFile.replace(path, with: Data(updated.utf8))
            } catch {
                throw ConfigError.writeFailed(path: path.path, underlying: error)
            }
            return true
        }
    }

    /// The edit itself: the new file text, or nil when `[local]` already holds the result.
    static func updatingLocal(_ original: String?, fallbackConfig: ProviderConfig,
                              _ change: (inout LocalSettings) throws -> Void) throws -> String? {
        let before = try (original.map(parseValidating) ?? fallbackConfig).local ?? LocalSettings()
        var after = before
        try change(&after)
        try after.validate()
        guard after != before else { return nil }

        // The raw table, not a re-encoded ProviderConfig, so keys this build does not know keep their values.
        // Serializing it drops comments and re-sorts keys, as every config writer does.
        let table: TOMLTable = try original.map { try TOMLTable(string: $0) } ?? TOMLEncoder().encode(fallbackConfig)
        // `local` is a section here or absent: `parseValidating` refused anything else, and the encoder writes one. An
        // existing section is edited in place, since TOMLKit hands out the table's own node. A new one always gets a
        // key: `after` differs from `before`, which is empty without a section.
        if let section = table["local"]?.table {
            after.write(over: before, into: section)
            if section.isEmpty { table.remove(at: "local") }
        } else {
            let section = TOMLTable()
            after.write(over: before, into: section)
            table["local"] = section
        }
        // Clearing the last key of a file that held only `[local]` leaves an empty table, and so an empty text.
        let text = table.convert()
        guard text.isEmpty == table.isEmpty, try TOMLTable(string: text) == table,
              try (parseValidating(text).local ?? LocalSettings()) == after
        else {
            throw ConfigError.parseFailed(detail: "[local] did not serialize to the values it was given")
        }
        return text
    }
}

extension LocalSettings {
    /// Sets the keys whose value differs from `previous` and removes the ones now absent. Every other key of
    /// `section`, known or not, keeps its value.
    fileprivate func write(over previous: LocalSettings, into section: TOMLTable) {
        func put<Value: TOMLValueConvertible & Equatable>(_ key: CodingKeys, _ value: Value?, was old: Value?) {
            guard value != old else { return }
            if let value {
                section[key.rawValue] = value
            } else {
                section.remove(at: key.rawValue)
            }
        }
        put(.mode, mode?.rawValue, was: previous.mode?.rawValue)
        put(.meFirst, meFirst, was: previous.meFirst)
        put(.meFirstIdleMinutes, meFirstIdleMinutes.map { Int($0) }, was: previous.meFirstIdleMinutes.map { Int($0) })
        put(.route, route?.rawValue, was: previous.route?.rawValue)
        put(.port, port.map { Int($0) }, was: previous.port.map { Int($0) })
        put(.bind, bind, was: previous.bind)
    }
}
