import Foundation

/// One canonical device namespace for this user's clusters. The input document
/// cannot select a different lease directory to evade an unresolved allocation.
public struct ClusterUserPaths: Sendable, Equatable {
    public let homeDirectory: URL
    public let configurationsDirectory: URL
    public let deviceDirectory: URL
    public var deviceLeaseFile: URL { deviceDirectory.appendingPathComponent("native-device.lease") }

    public init() throws {
        try self.init(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
    }

    // Internal fixture seam; public callers cannot choose another device gate.
    init(homeDirectory: URL) throws {
        guard homeDirectory.isFileURL else { throw ClusterConfigurationError.invalid("Expected a local home directory") }
        try ClusterConfigurationFiles.requireAbsolute(homeDirectory.path)
        self.homeDirectory = homeDirectory
        configurationsDirectory = homeDirectory.appendingPathComponent(".config/darkbloom/clusters", isDirectory: true)
        deviceDirectory = homeDirectory.appendingPathComponent(".darkbloom/cluster-device", isDirectory: true)
    }

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

    static func sshPath(_ value: String) -> Bool {
        value.hasPrefix("/") && value.utf8.count <= 1024 && !value.split(separator: "/").contains("..") &&
        !value.split(separator: "/").contains(".") && !value.contains("//") && !value.hasSuffix("/") && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 47, 95].contains($0)
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
