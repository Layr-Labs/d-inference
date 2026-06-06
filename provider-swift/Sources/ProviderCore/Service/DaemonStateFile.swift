import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Snapshot of the running provider daemon's state, written periodically to a
/// small JSON file so the `status` / `doctor` CLI commands can show live state
/// and — critically — the coordinator's latest `trust_status` reason, which is
/// otherwise only logged.
///
/// The daemon and CLI run as separate processes with no IPC today (only a PID
/// file). A state file is the smallest addition that fits: the daemon already
/// assembles this exact data every heartbeat; writing it atomically lets the CLI
/// read it with zero IPC, and it survives the daemon being asleep or wedged.
public struct DaemonState: Codable, Sendable, Equatable {
    public static let currentSchema = 1

    public var schema: Int
    public var pid: Int32
    public var version: String
    public var writtenAt: Double // epoch seconds; staleness check
    public var startedAt: Double // epoch seconds; uptime
    public var trust: Trust?
    public var currentModel: String?
    public var warmModels: [String]
    public var inferenceActive: Bool
    public var stats: Stats
    public var system: SystemInfo?
    public var capacity: Capacity?
    public var lastModelLoadError: ModelLoadError?
    public var connectivity: Connectivity?

    public struct Trust: Codable, Sendable, Equatable {
        public var trustLevel: String
        public var status: String
        public var reason: String
        public var receivedAt: Double
        public init(trustLevel: String, status: String, reason: String, receivedAt: Double) {
            self.trustLevel = trustLevel
            self.status = status
            self.reason = reason
            self.receivedAt = receivedAt
        }
    }

    public struct Stats: Codable, Sendable, Equatable {
        public var requestsServed: UInt64
        public var tokensGenerated: UInt64
        public var usageGaps: UInt64
        public init(requestsServed: UInt64 = 0, tokensGenerated: UInt64 = 0, usageGaps: UInt64 = 0) {
            self.requestsServed = requestsServed
            self.tokensGenerated = tokensGenerated
            self.usageGaps = usageGaps
        }
    }

    public struct SystemInfo: Codable, Sendable, Equatable {
        public var memoryPressure: Double
        public var cpuUsage: Double
        public var thermalState: String
        public init(memoryPressure: Double, cpuUsage: Double, thermalState: String) {
            self.memoryPressure = memoryPressure
            self.cpuUsage = cpuUsage
            self.thermalState = thermalState
        }
    }

    public struct Capacity: Codable, Sendable, Equatable {
        public var totalMemoryGb: Double
        public var gpuMemoryActiveGb: Double
        /// Live MLX GPU cache (buffer pool) memory. Optional for backward
        /// compatibility with state files written before this field existed; the
        /// model-fit diagnostic subtracts it so `doctor` exactly mirrors
        /// `ProviderLoop.availableMemoryGb()` even when the OS-available reading
        /// is unavailable.
        public var gpuMemoryCacheGb: Double?
        public init(totalMemoryGb: Double, gpuMemoryActiveGb: Double, gpuMemoryCacheGb: Double? = nil) {
            self.totalMemoryGb = totalMemoryGb
            self.gpuMemoryActiveGb = gpuMemoryActiveGb
            self.gpuMemoryCacheGb = gpuMemoryCacheGb
        }
    }

    public struct ModelLoadError: Codable, Sendable, Equatable {
        public var model: String
        public var message: String
        public var at: Double
        public init(model: String, message: String, at: Double) {
            self.model = model
            self.message = message
            self.at = at
        }
    }

    public struct Connectivity: Codable, Sendable, Equatable {
        public var reconnectCount: Int
        public var lastError: String?
        public init(reconnectCount: Int, lastError: String?) {
            self.reconnectCount = reconnectCount
            self.lastError = lastError
        }
    }

    public init(
        schema: Int = DaemonState.currentSchema,
        pid: Int32,
        version: String,
        writtenAt: Double,
        startedAt: Double,
        trust: Trust? = nil,
        currentModel: String? = nil,
        warmModels: [String] = [],
        inferenceActive: Bool = false,
        stats: Stats = Stats(),
        system: SystemInfo? = nil,
        capacity: Capacity? = nil,
        lastModelLoadError: ModelLoadError? = nil,
        connectivity: Connectivity? = nil
    ) {
        self.schema = schema
        self.pid = pid
        self.version = version
        self.writtenAt = writtenAt
        self.startedAt = startedAt
        self.trust = trust
        self.currentModel = currentModel
        self.warmModels = warmModels
        self.inferenceActive = inferenceActive
        self.stats = stats
        self.system = system
        self.capacity = capacity
        self.lastModelLoadError = lastModelLoadError
        self.connectivity = connectivity
    }

    // MARK: - Reader helpers

    public func ageSeconds(now: Double) -> Double { max(0, now - writtenAt) }

    /// Live fields are stale if the snapshot is older than 90s — many write
    /// cycles (the daemon rewrites every ~half-heartbeat), so this comfortably
    /// distinguishes "running" from "wedged". A stale-but-present file still
    /// carries useful last-known trust.
    public func isStale(now: Double, maxAge: Double = 90) -> Bool {
        ageSeconds(now: now) > maxAge
    }

    public func uptimeSeconds(now: Double) -> Double { max(0, now - startedAt) }
}

/// Reports whether a process with the given PID is currently alive.
public func daemonProcessAlive(pid: Int32) -> Bool {
    pid > 0 && kill(pid, 0) == 0
}

/// Reads/writes the daemon state file at `~/.darkbloom/daemon-state.json`
/// (override with `DARKBLOOM_STATE_FILE`).
public enum DaemonStateFile {
    public static func path() -> URL {
        if let override = ProcessInfo.processInfo.environment["DARKBLOOM_STATE_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".darkbloom/daemon-state.json")
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.sortedKeys]
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    /// Atomically writes the snapshot. Best-effort: write failures are swallowed
    /// (diagnostics must never crash the serving daemon).
    public static func write(_ state: DaemonState, to url: URL = DaemonStateFile.path()) {
        do {
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try encoder().encode(state)
            // .atomic writes to a temp file then renames — a reader never sees a
            // half-written file.
            try data.write(to: url, options: .atomic)
        } catch {
            // Intentionally ignored: state file is a diagnostic aid, not critical.
        }
    }

    /// Reads the snapshot, or nil if absent / unreadable / wrong schema.
    public static func read(from url: URL = DaemonStateFile.path()) -> DaemonState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let state = try? decoder().decode(DaemonState.self, from: data) else { return nil }
        guard state.schema == DaemonState.currentSchema else { return nil }
        return state
    }
}
