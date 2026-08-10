import Foundation

enum MLXMetallibEnvironment {
    private static let key = "MLX_METALLIB_PATH"
    private static let lock = NSRecursiveLock()

    static func withExclusiveAccess<Result>(
        _ operation: () throws -> Result
    ) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    static func setPath(_ path: String?) {
        withExclusiveAccess {
            updatePath(path)
        }
    }

    static func withPath<Result>(
        _ path: String?,
        operation: () throws -> Result
    ) rethrows -> Result {
        try withExclusiveAccess {
            let previousPath = currentPath()
            updatePath(path)
            defer { updatePath(previousPath) }
            return try operation()
        }
    }

    private static func currentPath() -> String? {
        guard let value = getenv(key) else { return nil }
        return String(cString: value)
    }

    private static func updatePath(_ path: String?) {
        if let path {
            setenv(key, path, 1)
        } else {
            unsetenv(key)
        }
    }
}
