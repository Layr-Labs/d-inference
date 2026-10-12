import Darwin
import Foundation

/// Descriptor-checked inputs for the explicit, single-process native diagnostic.
/// The token is a synthetic loopback credential, never the installed auth file.
final class NativeServeQualificationInputs: @unchecked Sendable {
    let directory: URL
    let coordinatorURL: String
    let token: String
    let modelID: String
    let modelCache: URL
    private let descriptor: Int32

    enum Failure: String, Error {
        case optInRequired, loopbackRequired, privateDirectoryRequired, invalidInput
        case signedReleaseRequired, modelUnavailable, shutdownIncomplete, deadlineExceeded
    }

    static func validateURL(_ value: String) throws -> String {
        guard let parts = URLComponents(string: value), parts.scheme == "ws",
              parts.host == "127.0.0.1", let port = parts.port, (1024...65535).contains(port),
              parts.path == "/ws/provider", parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              value == "ws://127.0.0.1:\(port)/ws/provider"
        else { throw Failure.loopbackRequired }
        return value
    }

    init(coordinatorURL: String, path: String) throws {
        self.coordinatorURL = try Self.validateURL(coordinatorURL)
        let directory = URL(fileURLWithPath: path)
        guard path.hasPrefix("/"), directory.resolvingSymlinksInPath().path == path else {
            throw Failure.privateDirectoryRequired
        }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.privateDirectoryRequired }
        do {
            var metadata = stat()
            guard fstat(fd, &metadata) == 0, metadata.st_uid == geteuid(),
                  metadata.st_mode & 0o777 == 0o700 else { throw Failure.privateDirectoryRequired }
            token = try Self.read("auth-token", from: fd, maximum: 64)
            guard token.utf8.count == 64, token.utf8.allSatisfy({
                (48...57).contains($0) || (97...102).contains($0)
            }) else { throw Failure.invalidInput }
            modelID = try Self.read("model-id", from: fd, maximum: 256)
            let components = modelID.split(separator: "/", omittingEmptySubsequences: false)
            guard components.count == 2, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  modelID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                      || (97...122).contains($0) || [45, 46, 47, 95].contains($0) })
            else { throw Failure.invalidInput }
            modelCache = directory.appendingPathComponent("models", isDirectory: true)
            var cache = stat()
            guard lstat(modelCache.path, &cache) == 0, cache.st_mode & S_IFMT == S_IFDIR,
                  cache.st_uid == geteuid(), cache.st_mode & 0o077 == 0,
                  modelCache.resolvingSymlinksInPath() == modelCache else { throw Failure.privateDirectoryRequired }
        } catch {
            close(fd)
            throw error
        }
        self.directory = directory
        descriptor = fd
    }

    deinit { close(descriptor) }

    /// A one-byte owner-only stop marker, not an RPC or a signing interface.
    func finished() -> Bool {
        (try? Self.read("done", from: descriptor, maximum: 1)) == "1"
    }

    /// A fixed one-shot request from this diagnostic's private owner. No
    /// endpoint, key, hash, challenge or process identifier is accepted.
    func workerFaultRequested() -> Bool {
        (try? Self.read("arm-worker-callback", from: descriptor, maximum: 1)) == "1"
    }

    private static func read(_ name: String, from directory: Int32, maximum: Int) throws -> String {
        let fd = openat(directory, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.invalidInput }
        defer { close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_uid == geteuid(),
              metadata.st_mode & S_IFMT == S_IFREG, metadata.st_mode & 0o077 == 0,
              metadata.st_nlink == 1, metadata.st_size > 0, metadata.st_size <= maximum
        else { throw Failure.invalidInput }
        var bytes = [UInt8](repeating: 0, count: maximum + 1)
        let count = Darwin.read(fd, &bytes, bytes.count)
        guard count == metadata.st_size, let value = String(bytes: bytes.prefix(count), encoding: .utf8)
        else { throw Failure.invalidInput }
        return value
    }
}
