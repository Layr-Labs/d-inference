import Foundation

extension ModelScanner {
    private static let cacheConfiguration = CacheConfiguration()

    /// Saved configuration for this CLI invocation, installed before serving starts.
    /// Injected resolver overloads remain independent of this process-wide value.
    public static var configuredCacheDirectory: String? {
        cacheConfiguration.read()
    }

    public static func configureCacheDirectory(_ directory: String?) {
        cacheConfiguration.store(directory)
    }
}

private final class CacheConfiguration: @unchecked Sendable {
    private let lock = NSLock()
    private var directory: String?

    func read() -> String? {
        lock.lock(); defer { lock.unlock() }
        return directory
    }

    func store(_ directory: String?) {
        lock.lock(); defer { lock.unlock() }
        self.directory = directory
    }
}
