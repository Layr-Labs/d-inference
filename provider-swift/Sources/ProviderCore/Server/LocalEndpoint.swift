import Crypto
import Darwin
import Foundation

/// Token + discovery-file management for **direct/local mode** — the
/// `darkbloom start --local` OpenAI-compatible server that a consumer on the
/// same machine (or LAN/tailnet) talks to directly, bypassing the coordinator.
///
/// Two artifacts live under `~/.darkbloom/` (override the directory with
/// `DARKBLOOM_LOCAL_DIR` in tests), both written `0600`:
///
///   * `local_token`  — the bearer token the local server requires. Persisted
///     so existing clients keep working across restarts. A loopback server
///     with no auth is reachable by any local process and, because the server
///     sends `Access-Control-Allow-Origin: *`, by a hostile web page too — so
///     the token is the security boundary, not the loopback bind.
///   * `local.json`   — discovery metadata (`base_url` + `api_key`) a client
///     reads to find and authenticate to the local server.
public enum LocalEndpoint {
    public static let tokenPrefix = "dk-local-"

    // MARK: - Directory

    static func directory() -> URL {
        if let override = ProcessInfo.processInfo.environment["DARKBLOOM_LOCAL_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".darkbloom", isDirectory: true)
    }

    static func tokenPath() -> URL { directory().appendingPathComponent("local_token") }
    static func infoPath() -> URL { directory().appendingPathComponent("local.json") }

    // MARK: - Token

    /// Load the persisted local token, or mint and persist a new one. The token
    /// is `dk-local-<base64url(32 random bytes)>`; restricted to `0600`.
    public static func loadOrCreateToken() throws -> String {
        if let existing = readToken() {
            return existing
        }
        let token = generateToken()
        try writeFile(token, to: tokenPath())
        return token
    }

    static func readToken() -> String? {
        guard let content = try? String(contentsOf: tokenPath(), encoding: .utf8) else { return nil }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func generateToken() -> String {
        let raw = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let b64url = raw.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return tokenPrefix + b64url
    }

    // MARK: - Discovery file

    /// Discovery metadata written by the running local server and read by
    /// clients to locate + authenticate to it.
    public struct Info: Codable, Sendable, Equatable {
        public var baseURL: String
        public var apiKey: String
        public var host: String
        public var port: UInt16
        public var pid: Int32
        public var version: String
        public var updatedAt: String

        enum CodingKeys: String, CodingKey {
            case baseURL = "base_url"
            case apiKey = "api_key"
            case host
            case port
            case pid
            case version
            case updatedAt = "updated_at"
        }

        public init(host: String, port: UInt16, apiKey: String, version: String, pid: Int32, updatedAt: String) {
            // For a client URL, an unspecified bind (0.0.0.0) is not dialable;
            // present loopback so same-machine clients always have a usable URL.
            let dialHost = (host == "0.0.0.0" || host.isEmpty) ? "127.0.0.1" : host
            self.baseURL = "http://\(dialHost):\(port)/v1"
            self.apiKey = apiKey
            self.host = host
            self.port = port
            self.pid = pid
            self.version = version
            self.updatedAt = updatedAt
        }
    }

    /// Write the discovery file (`0600`). Call after the server is listening.
    public static func writeInfo(_ info: Info) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(info)
        let json = String(decoding: data, as: UTF8.self)
        try writeFile(json, to: infoPath())
    }

    /// Read the discovery file, if present. Pure read — does not check whether
    /// the recorded server process is still alive (see ``readLiveInfo()``).
    public static func readInfo() -> Info? {
        guard let data = try? Data(contentsOf: infoPath()) else { return nil }
        return try? JSONDecoder().decode(Info.self, from: data)
    }

    /// Read the discovery file only if the server process that wrote it is still
    /// running. Cleanup is best-effort (a Ctrl-C/SIGKILL/crash skips the
    /// shutdown `defer`), so a stale `local.json` can linger pointing at a dead
    /// server; the recorded pid is the liveness backstop. Consumers (the
    /// `darkbloom local` command) use this so they never advertise a dead
    /// endpoint.
    public static func readLiveInfo() -> Info? {
        guard let info = readInfo() else { return nil }
        return isProcessAlive(info.pid) ? info : nil
    }

    /// True when a process with `pid` exists and is signalable by this user.
    static func isProcessAlive(_ pid: Int32) -> Bool {
        if pid <= 0 { return false }
        // kill(pid, 0) probes existence without delivering a signal: 0 means
        // alive; EPERM means alive-but-not-ours (still alive); ESRCH means gone.
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Best-effort removal of the discovery file (on shutdown). The token file
    /// is intentionally retained so the same token survives restarts.
    public static func removeInfo() {
        try? FileManager.default.removeItem(at: infoPath())
    }

    // MARK: - Shared file writer (atomic, 0600)

    enum WriteError: Error { case failed(String) }

    /// Write `contents` to `path` with `0600` and no umask window: create a
    /// fresh temp file via `O_CREAT|O_EXCL|0600` (perms applied at creation),
    /// write it fully, then atomically `rename` over the target. Both artifacts
    /// hold a secret (the token), so neither the file nor any reader should ever
    /// observe looser permissions or a partial write.
    private static func writeFile(_ contents: String, to path: URL) throws {
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let tmp = dir.appendingPathComponent(".\(path.lastPathComponent).tmp-\(getpid())-\(UInt32.random(in: .min ... .max))")
        let fd = open(tmp.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard fd >= 0 else { throw WriteError.failed("create \(tmp.lastPathComponent): \(String(cString: strerror(errno)))") }

        var bytes = Array(contents.utf8)
        var ok = true
        bytes.withUnsafeBytes { buf in
            var off = 0
            while off < buf.count {
                let n = write(fd, buf.baseAddress!.advanced(by: off), buf.count - off)
                if n <= 0 { ok = false; break }
                off += n
            }
        }
        close(fd)
        bytes.removeAll(keepingCapacity: false)

        guard ok else {
            unlink(tmp.path)
            throw WriteError.failed("write \(tmp.lastPathComponent)")
        }
        guard rename(tmp.path, path.path) == 0 else {
            unlink(tmp.path)
            throw WriteError.failed("rename onto \(path.lastPathComponent): \(String(cString: strerror(errno)))")
        }
    }
}
