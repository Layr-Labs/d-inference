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
        return BuildEnvironment.current.installDirectory()
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

    // MARK: - The cluster's local API key

    /// The pair's one key, the same on every Mac of it: a pair's API (`darkbloom cluster local`, or Both, me first) takes
    /// it beside that Mac's own `local_token` (`LocalInferenceHTTPConfig.pairToken`), and every other Mac's relay passes
    /// requests on with it in place of its own Mac's key (`ClusterLocalRelay.Keys`), whichever Mac the plan made rank 0.
    /// The control leader sends it to the member with each start (inside the keyed link control session).
    static func clusterTokenPath() -> URL { directory().appendingPathComponent("cluster_local_token") }

    public static func loadOrCreateClusterToken() throws -> String {
        if let content = try? String(contentsOf: clusterTokenPath(), encoding: .utf8) {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if isToken(trimmed) { return trimmed }
        }
        let token = generateToken()
        try writeFile(token, to: clusterTokenPath())
        return token
    }

    /// The key of the server listening on `port` on this Mac: its discovery file's when that names the port (this Mac's
    /// own, whatever serves: a pair's API and a relay take it too; a pair API an older build started names the pair's),
    /// else the pair's, else this Mac's own.
    public static func token(forPort port: Int) -> String? {
        if let info = readLiveInfo(), Int(info.port) == port, !info.apiKey.isEmpty { return info.apiKey }
        return existingClusterToken() ?? readToken()
    }

    /// The file holding exactly `token(forPort:)`, for tools that read the key from a file (OpenCode's `{file:}`,
    /// Hermes' `key_cmd`) instead of keeping a copy in their own config. Nil when no key file holds that key.
    public static func keyFile(forPort port: Int) -> URL? {
        guard let key = token(forPort: port) else { return nil }
        return [clusterTokenPath(), tokenPath()].first { path in
            (try? String(contentsOf: path, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == key
        }
    }

    /// The pair's key when this Mac has one; nil otherwise (nothing is created).
    public static func existingClusterToken() -> String? {
        guard let content = try? String(contentsOf: clusterTokenPath(), encoding: .utf8) else { return nil }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return isToken(trimmed) ? trimmed : nil
    }

    /// Keeps the key the control leader sent; false (nothing written) for anything that is not a key.
    @discardableResult
    public static func saveClusterToken(_ token: String) -> Bool {
        guard isToken(token) else { return false }
        if (try? String(contentsOf: clusterTokenPath(), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == token { return true }
        return (try? writeFile(token, to: clusterTokenPath())) != nil
    }

    /// `dk-local-` and 43 base64url characters (32 random bytes), as `generateToken` makes it.
    public static func isToken(_ value: String) -> Bool {
        guard value.hasPrefix(tokenPrefix) else { return false }
        let body = value.dropFirst(tokenPrefix.count)
        return body.count == 43 && body.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_").contains($0)
        }
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
            self.baseURL = LocalEndpoint.baseURL(host: host, port: port)
            self.apiKey = apiKey
            self.host = host
            self.port = port
            self.pid = pid
            self.version = version
            self.updatedAt = updatedAt
        }
    }

    /// The address a client on this Mac dials for a server bound to `host` on `port`, the one `start` prints and tools
    /// are given. An unspecified bind (0.0.0.0) is not dialable: loopback stands for it.
    public static func baseURL(host: String, port: UInt16) -> String {
        let dialHost = (host == "0.0.0.0" || host.isEmpty) ? "127.0.0.1" : host
        return "http://\(dialHost):\(port)/v1"
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

    /// The same, only when the discovery file is `pid`'s (a cluster service's relay never removes a server's file).
    public static func removeInfo(ifPID pid: Int32) {
        guard readInfo()?.pid == pid else { return }
        removeInfo()
    }

    // MARK: - Shared file writer (atomic, 0600)

    /// Both artifacts hold a secret (the token), so neither the file nor any reader may ever observe looser
    /// permissions or a partial write: `AtomicFile` creates its sibling `0600` and renames it over the target.
    private static func writeFile(_ contents: String, to path: URL) throws {
        try AtomicFile.write(Data(contents.utf8), to: path, mode: 0o600)
    }
}
