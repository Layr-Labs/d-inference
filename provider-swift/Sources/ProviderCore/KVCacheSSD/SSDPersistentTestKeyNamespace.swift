import Darwin
import Foundation

/// An explicitly owned key hierarchy for standalone persistent-cache tests.
/// This selects names; the executable still needs real Keychain authorization.
/// It does not change ProviderLoop's separate attestation identity.
@_spi(Benchmarking)
public struct SSDPersistentTestKeyNamespace: Sendable, Equatable {
    public let identifier: UUID
    public let accessGroup: String

    public enum Failure: Error, Equatable, Sendable {
        case invalidAccessGroup
        case persistentModeRequired
        case isolatedRootRequired
        case unsafeIsolatedRoot
    }

    public init(identifier: UUID, accessGroup: String) throws {
        let components = accessGroup.split(separator: ".", omittingEmptySubsequences: false)
        guard accessGroup.utf8.count <= 255, components.count >= 2,
            components.allSatisfy({ !$0.isEmpty }),
            accessGroup.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0)
                    || (97...122).contains($0) || $0 == 45 || $0 == 46
            })
        else { throw Failure.invalidAccessGroup }
        self.identifier = identifier
        self.accessGroup = accessGroup
    }

    private var stem: String { "io.darkbloom.test.ssd.\(identifier.uuidString.lowercased())" }

    public var enclaveLabel: String { "\(stem).enclave" }
    public var wrappedKEKService: String { "\(stem).kek" }
    public var wrappedKEKAccount: String { "cache-\(identifier.uuidString.lowercased())" }

    /// Call before root creation and again immediately before key loading.
    /// The existing ALLOW_EPHEMERAL flag opts into TEST_ROOT, but this mode
    /// never permits an ephemeral fallback.
    public func validate(environment: [String: String], requirePersistentKey: Bool = true) throws {
        guard requirePersistentKey,
            environment["DARKBLOOM_PREFIX_CACHE_TEST_PERSISTENT_KEY"] == "1"
        else { throw Failure.persistentModeRequired }
        guard SSDPrefixCacheFactory.ephemeralAllowed(environment: environment),
            let rawRoot = environment[SSDPrefixCacheFactory.testRootEnvironmentKey]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawRoot.isEmpty
        else { throw Failure.isolatedRootRequired }
        let normal = SSDPrefixCacheFactory.cacheRootDirectory(environment: [:])
        let legacy = normal.deletingLastPathComponent().appendingPathComponent("kv", isDirectory: true)
        try Self.validateIsolatedRoot(rawRoot, protectedRoots: [normal, legacy])
    }

    static func validateIsolatedRoot(_ rawRoot: String, protectedRoots: [URL]) throws {
        let root = try canonicalDirectoryPath(rawRoot)
        guard root != "/", try protectedRoots.allSatisfy({ protected in
            let path = try canonicalDirectoryPath(protected.path)
            return root != path && !root.hasPrefix(path + "/") && !path.hasPrefix(root + "/")
        }) else { throw Failure.unsafeIsolatedRoot }
    }

    /// Foundation's whole-path resolver can retain aliases when a leaf is absent.
    /// Resolve the nearest existing ancestor, then append only missing components.
    /// This is read-only admission checking; cache creation retains its no-follow IO.
    private static func canonicalDirectoryPath(_ raw: String) throws -> String {
        guard raw.hasPrefix("/"), !raw.utf8.contains(0),
            !raw.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
        else { throw Failure.unsafeIsolatedRoot }
        var ancestor = URL(fileURLWithPath: raw, isDirectory: true)
        var missing = [String]()
        while true {
            var entry = stat()
            if lstat(ancestor.path, &entry) == 0 {
                // An existing symlink must resolve: never walk past a dangling link.
                guard let resolved = realpath(ancestor.path, nil) else {
                    throw Failure.unsafeIsolatedRoot
                }
                defer { free(resolved) }
                var destination = stat()
                guard stat(resolved, &destination) == 0,
                    (destination.st_mode & S_IFMT) == S_IFDIR
                else { throw Failure.unsafeIsolatedRoot }
                var path = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
                for component in missing.reversed() {
                    path.appendPathComponent(component, isDirectory: true)
                }
                // Conservatively reject spelling aliases on case-insensitive volumes.
                return path.path.lowercased()
            }
            guard errno == ENOENT, ancestor.path != "/" else {
                throw Failure.unsafeIsolatedRoot
            }
            missing.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
    }
}
