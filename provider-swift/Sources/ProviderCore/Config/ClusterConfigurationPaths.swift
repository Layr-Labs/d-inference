import Foundation

/// One canonical device namespace for this user's clusters of this build. Neither
/// the input document nor a public caller can select a different lease directory
/// (another build's included) to evade an unresolved allocation.
///
/// Every cluster file of an install lives in that install's own folders
/// (`BuildEnvironment.installDirectory` and `configDirectory`): production's in
/// `~/.darkbloom` and `~/.config/darkbloom`, DevNet's in `~/.darkbloom-dev` and
/// `~/.config/darkbloom-dev`. Two installs on one Mac share no pairing, setup,
/// service lock or device lease, and neither writes the other's. So the device
/// lease no longer keeps the two installs' native sessions apart: each install's
/// pair can hold this Mac's GPU and cable port while the other's does. The one
/// read across installs is the cable port setup's record, which is this Mac's:
/// a port the other install set up is adopted with what that setup changed
/// (`ClusterLinkRepair.Environment.otherInstallsIsolationEntries`).
public struct ClusterUserPaths: Sendable, Equatable {
    public let homeDirectory: URL
    public let environment: BuildEnvironment
    public let configurationsDirectory: URL
    public let deviceDirectory: URL
    public var deviceLeaseFile: URL { deviceDirectory.appendingPathComponent("native-device.lease") }
    /// Owner-only record of the link-local aliases `cluster link --fix` added.
    var linkAliasRecordFile: URL { deviceDirectory.appendingPathComponent("link-alias.json") }
    /// What link setup v2 changed for each cluster port, so a removal can put it back.
    var linkIsolationRecordFile: URL { deviceDirectory.appendingPathComponent("link-isolation.json") }
    /// The install's data folder, which holds the cluster folders below.
    public var installDirectory: URL { environment.installDirectory(home: homeDirectory) }
    /// The pairing store: the pins, each pairing's edge secret, the lockout and its audit.
    public var pairingDirectory: URL { Self.pairingDirectory(home: homeDirectory, environment: environment) }
    /// What `darkbloom cluster` and the cluster service keep: the setup record, the service's lock, pid, status and
    /// logs, and the screens' transcripts.
    public var setupDirectory: URL { installDirectory.appendingPathComponent("cluster-setup", isDirectory: true) }
    /// The observability files: incidents, pair telemetry, follower status, served speeds and the planner's probes.
    public var observabilityDirectory: URL { Self.observabilityDirectory(home: homeDirectory, environment: environment) }

    /// This user's, for the running build: no public caller opens another build's folders.
    public init() throws {
        try self.init(homeDirectory: FileManager.default.homeDirectoryForCurrentUser, environment: .current)
    }

    // Internal fixture seam; public callers cannot choose another home, build or device gate.
    init(homeDirectory: URL, environment: BuildEnvironment = .current) throws {
        guard homeDirectory.isFileURL else { throw ClusterConfigurationError.invalid("Expected a local home directory") }
        try ClusterConfigurationFiles.requireAbsolute(homeDirectory.path)
        self.homeDirectory = homeDirectory
        self.environment = environment
        configurationsDirectory = environment.configDirectory(home: homeDirectory).appendingPathComponent("clusters", isDirectory: true)
        deviceDirectory = environment.installDirectory(home: homeDirectory).appendingPathComponent("cluster-device", isDirectory: true)
    }

    /// `pairingDirectory` without a checked home, for the pairing store's default.
    public static func pairingDirectory(home: URL, environment: BuildEnvironment = .current) -> URL {
        environment.installDirectory(home: home).appendingPathComponent("cluster-pairing", isDirectory: true)
    }

    /// `observabilityDirectory` without a checked home, for the observability files' defaults.
    public static func observabilityDirectory(home: URL, environment: BuildEnvironment = .current) -> URL {
        environment.installDirectory(home: home).appendingPathComponent("cluster", isDirectory: true)
    }

    /// A file in the install's folder as messages name it: `~/.darkbloom/cluster-setup/service.log` in production.
    public static func shown(_ relativePath: String, environment: BuildEnvironment = .current) -> String {
        "~/\(environment.installDirectoryName)/\(relativePath)"
    }

    /// The cluster service's log as messages name it (`ClusterService.paths().log`).
    public static var serviceLogShown: String { shown("cluster-setup/service.log") }

    public func configurationURL(sha256: String) throws -> URL {
        guard ClusterConfigurationSyntax.hash(sha256) else { throw ClusterConfigurationError.invalid("Invalid configuration digest") }
        return configurationsDirectory.appendingPathComponent(sha256 + ".cluster.json")
    }

    public func capabilityURL(sha256: String) throws -> URL {
        guard ClusterConfigurationSyntax.hash(sha256) else { throw ClusterConfigurationError.invalid("Invalid capability digest") }
        return configurationsDirectory.appendingPathComponent(sha256 + ".capability.json")
    }
}

/// Saved setup reference only. Its presence is never an enabled/readiness flag.
public struct ClusterConfigurationReference: Sendable, Equatable, Codable {
    public let configuration: String
    public let sha256: String

    public init(configuration: String, sha256: String) throws {
        try ClusterConfigurationFiles.requireAbsolute(configuration)
        guard ClusterConfigurationSyntax.hash(sha256) else { throw ClusterConfigurationError.invalid("Invalid saved cluster digest") }
        self.configuration = configuration; self.sha256 = sha256
    }

    private enum CodingKeys: String, CodingKey { case configuration, sha256 }
    public init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: AnyKey.self)
        guard Set(keys.allKeys.map(\.stringValue)) == ["configuration", "sha256"] else {
            throw ClusterConfigurationError.invalid("Unknown or missing saved cluster reference fields")
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(configuration: values.decode(String.self, forKey: .configuration),
                      sha256: values.decode(String.self, forKey: .sha256))
    }
    private struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}

enum ClusterConfigurationSyntax {
    static func hash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func label(_ value: String, maximum: Int = 128) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum && !value.hasPrefix("-") && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
        }
    }

    static func sshPath(_ value: String) -> Bool { normalizedAbsolutePath(value, allowingSpaces: false) }

    /// A file or directory of an installed build that its own Mac opens directly, never through a shell. An
    /// environment's app name can contain a space (`Darkbloom Dev.app`). Every command line the developer SSH route
    /// sends to a remote shell checks its paths again (`ClusterSSHConfiguration.safePath`).
    static func installedPath(_ value: String) -> Bool { normalizedAbsolutePath(value, allowingSpaces: true) }

    private static func normalizedAbsolutePath(_ value: String, allowingSpaces: Bool) -> Bool {
        value.hasPrefix("/") && value.utf8.count <= 1024 && !value.split(separator: "/").contains("..") &&
        !value.split(separator: "/").contains(".") && !value.contains("//") && !value.hasSuffix("/") && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 47, 95].contains($0)
                || (allowingSpaces && $0 == 32)
        }
    }

    static func host(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 253 && !value.hasPrefix("-") && !value.hasSuffix(".") &&
        value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-") && label.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
            }
        }
    }

    static func ipv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy {
            guard let number = Int($0), (0...255).contains(number) else { return false }
            return String(number) == $0
        } && parts[0] != "0" && parts[0] != "127" && (Int(parts[0]) ?? 255) < 224
    }

    static func relativePath(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 && !value.hasPrefix("/") && !value.hasSuffix("/") &&
        value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { label(String($0), maximum: 128) && $0 != "." && $0 != ".." }
    }
}
