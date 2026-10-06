import Foundation

/// Explicit ownership of the supervised fixture's isolated cache plumbing.
/// This is not inferred from environment variables by ordinary serving callers.
struct DeadlineQualificationCacheIsolation: Sendable {
    private let cacheRoot: URL

    enum Failure: Error { case mismatchedEnvironment }

    init(cacheRoot: URL) throws {
        self.cacheRoot = cacheRoot
        try validateRoot()
    }

    func validate(environment: [String: String]) throws {
        guard environment[SSDPrefixCacheFactory.testRootEnvironmentKey] == cacheRoot.path,
            environment["DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL"] == "1"
        else { throw Failure.mismatchedEnvironment }
        try validateRoot()
    }

    private func validateRoot() throws {
        guard cacheRoot.isFileURL else { throw Failure.mismatchedEnvironment }
        let normal = SSDPrefixCacheFactory.cacheRootDirectory(environment: [:])
        let legacy = normal.deletingLastPathComponent().appendingPathComponent("kv", isDirectory: true)
        try SSDPersistentTestKeyNamespace.validateIsolatedRoot(cacheRoot.path, protectedRoots: [normal, legacy])
    }

    static func isPlumbingKey(_ key: String) -> Bool {
        key == SSDPrefixCacheFactory.testRootEnvironmentKey || key == "DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL"
    }
}
