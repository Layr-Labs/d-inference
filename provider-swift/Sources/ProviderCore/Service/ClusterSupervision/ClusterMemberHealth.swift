import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The supervised member's own heartbeat, written by the member process every
/// few seconds FROM its provider loop actor (so a wedged loop stops the
/// heartbeat) and read by its supervisor's liveness guard. It replaces the
/// owner's `/health` probe: a control-only member has no HTTP API.
public struct ClusterMemberHealth: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        /// Preparing the saved setup, hashing weights, connecting.
        case starting
        /// Connected and registered with the coordinator; no pair formed.
        case registered
        /// A pair this member belongs to is serving.
        case serving
        /// Leaving: drain or shutdown in progress.
        case stopping
    }

    /// The request the pair is working on, when this member leads it.
    public struct ActiveRequest: Codable, Equatable, Sendable {
        public var id: String
        public var secondsSinceProgress: Double
        public var tokensEmitted: Int
        public var prefillProcessedTokens: Int
        public var promptTokens: Int

        public init(id: String, secondsSinceProgress: Double, tokensEmitted: Int,
                    prefillProcessedTokens: Int, promptTokens: Int) {
            self.id = id
            self.secondsSinceProgress = secondsSinceProgress
            self.tokensEmitted = tokensEmitted
            self.prefillProcessedTokens = prefillProcessedTokens
            self.promptTokens = promptTokens
        }
    }

    public var pid: Int32
    public var version: String
    public var phase: Phase
    /// Epoch seconds of this write.
    public var writtenAt: Double
    /// Epoch seconds the member registered with the coordinator, if it has.
    public var registeredAt: Double?
    /// Epoch seconds a pair first served in this run, if one has.
    public var servingSince: Double?
    public var activeRequest: ActiveRequest?
    /// Seconds the pair's engine has been wedged (its own watchdog's verdict:
    /// a stall with no engine steps), nil when it is not.
    public var engineWedgedSeconds: Double?
    /// The warmup canary's result for the current pair, when one ran.
    public var warmup: String?
    /// The pair has a request in flight (the coordinated update waits for idle).
    public var busy: Bool?

    public init(pid: Int32, version: String, phase: Phase, writtenAt: Double, registeredAt: Double? = nil,
                servingSince: Double? = nil, activeRequest: ActiveRequest? = nil, engineWedgedSeconds: Double? = nil,
                warmup: String? = nil, busy: Bool? = nil) {
        self.pid = pid
        self.version = version
        self.phase = phase
        self.writtenAt = writtenAt
        self.registeredAt = registeredAt
        self.servingSince = servingSince
        self.activeRequest = activeRequest
        self.engineWedgedSeconds = engineWedgedSeconds
        self.warmup = warmup
        self.busy = busy
    }
}

/// Small owner-only JSON files under `~/.darkbloom` shared by the supervisor
/// and its member. Atomic replace; a read of a missing or corrupt file is nil.
public enum ClusterSupervisionFiles {
    /// Where the supervisor tells its member to write the heartbeat.
    public static let healthPathEnvironmentKey = "DARKBLOOM_CLUSTER_MEMBER_HEALTH_FILE"
    /// Override for the supervisor's own state file (tests, a second label).
    public static let statePathEnvironmentKey = "DARKBLOOM_CLUSTER_SUPERVISOR_STATE"

    public static func darkbloomDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".darkbloom", isDirectory: true)
    }

    public static func defaultHealthPath(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        darkbloomDirectory(home: home).appendingPathComponent("cluster-member-health.json")
    }

    public static func statePath(environment: [String: String] = ProcessInfo.processInfo.environment,
                                 home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let value = environment[statePathEnvironmentKey], !value.isEmpty {
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
        }
        return darkbloomDirectory(home: home).appendingPathComponent("cluster-supervisor.json")
    }

    public static func lockPath(forState state: URL) -> URL {
        state.deletingPathExtension().appendingPathExtension("lock")
    }

    public static func read<Value: Decodable>(_ type: Value.Type, from url: URL) -> Value? {
        guard let data = try? Data(contentsOf: url), data.count <= 1 << 20 else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    @discardableResult
    public static func write<Value: Encodable>(_ value: Value, to url: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(value) else { return false }
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(getpid()).tmp")
            try data.write(to: temporary, options: .atomic)
            _ = chmod(temporary.path, 0o600)
            if rename(temporary.path, url.path) != 0 {
                try? FileManager.default.removeItem(at: temporary)
                return false
            }
            return true
        } catch {
            return false
        }
    }
}
