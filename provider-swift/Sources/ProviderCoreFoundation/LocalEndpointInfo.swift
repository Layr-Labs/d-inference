import Foundation

/// Discovery metadata written by the running local OpenAI-compatible server
/// to `~/.darkbloom/local.json` — consumers read it to find and authenticate
/// to the endpoint.
///
/// Lives in ProviderCoreFoundation (the no-MLX layer) because BOTH the
/// provider (writer) and the Darkbloom macOS app (reader) share the JSON
/// contract; mirroring it app-side would put a security-relevant wire shape
/// on a drift path. Token minting/rotation stays in ProviderCore's
/// `LocalEndpoint` — only the record and the read side are here.
public struct LocalEndpointInfo: Codable, Sendable, Equatable {
    public var baseURL: String
    public var apiKey: String
    public var host: String
    public var port: UInt16
    public var pid: Int32
    /// Exact kernel identity of the process that owns the endpoint. Optional
    /// only so legacy `local.json` records continue to decode; trust decisions
    /// must reject a missing or mismatched value.
    public var processIdentity: ProcessIdentity?
    public var version: String
    public var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case baseURL = "base_url"
        case apiKey = "api_key"
        case host
        case port
        case pid
        case processIdentity = "process_identity"
        case version
        case updatedAt = "updated_at"
    }

    private struct ProcessIdentityWire: Codable {
        let pid: Int32
        let startTimeMicros: UInt64

        enum CodingKeys: String, CodingKey {
            case pid
            case startTimeMicros = "start_time_micros"
        }

        init(_ identity: ProcessIdentity) {
            pid = identity.pid
            startTimeMicros = identity.startTimeMicros
        }

        var value: ProcessIdentity {
            ProcessIdentity(pid: pid, startTimeMicros: startTimeMicros)
        }
    }

    public init(
        host: String,
        port: UInt16,
        apiKey: String,
        version: String,
        pid: Int32,
        processIdentity: ProcessIdentity? = nil,
        updatedAt: String
    ) {
        // For a client URL, an unspecified bind (0.0.0.0) is not dialable;
        // present loopback so same-machine clients always have a usable URL.
        let dialHost = (host == "0.0.0.0" || host.isEmpty) ? "127.0.0.1" : host
        self.baseURL = "http://\(dialHost):\(port)/v1"
        self.apiKey = apiKey
        self.host = host
        self.port = port
        self.pid = pid
        self.processIdentity = processIdentity
        self.version = version
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        apiKey = try container.decode(String.self, forKey: .apiKey)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(UInt16.self, forKey: .port)
        pid = try container.decode(Int32.self, forKey: .pid)
        processIdentity = try container.decodeIfPresent(
            ProcessIdentityWire.self,
            forKey: .processIdentity
        )?.value
        version = try container.decode(String.self, forKey: .version)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(apiKey, forKey: .apiKey)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(pid, forKey: .pid)
        try container.encodeIfPresent(
            processIdentity.map(ProcessIdentityWire.init),
            forKey: .processIdentity
        )
        try container.encode(version, forKey: .version)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

/// Read-only access to the local-endpoint discovery artifact. The writer path
/// (atomic `0600` file swap, plus the paired token) stays in ProviderCore's
/// `LocalEndpoint`.
public enum LocalEndpointDiscovery {
    public static func directory() -> URL {
        if let override = ProcessInfo.processInfo.environment["DARKBLOOM_LOCAL_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".darkbloom", isDirectory: true)
    }

    public static func infoPath() -> URL { directory().appendingPathComponent("local.json") }

    /// Read the discovery file, if present. This intentionally preserves
    /// decoding compatibility with legacy PID-only records; use
    /// ``readLiveInfo(readIdentity:)`` before trusting its URL or bearer token.
    public static func readInfo() -> LocalEndpointInfo? {
        guard let data = try? Data(contentsOf: infoPath()) else { return nil }
        return try? JSONDecoder().decode(LocalEndpointInfo.self, from: data)
    }

    /// Read discovery only when its PID and kernel start identity still name
    /// the exact live process that wrote it. Legacy PID-only records fail
    /// closed even though ``readInfo()`` can decode them.
    public static func readLiveInfo(
        readIdentity: (Int32) -> ProcessIdentity? = ProcessIdentity.read
    ) -> LocalEndpointInfo? {
        guard let info = readInfo(),
              LocalEndpointRuntimeTruth.belongsToLiveProcess(
                  info,
                  readIdentity: readIdentity
              )
        else {
            return nil
        }
        return info
    }
}
