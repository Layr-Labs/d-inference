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
    /// The provider's kernel process identity (pid + start time) at the moment
    /// this state was written. The watchdog cross-checks a live PID's start
    /// time against this before treating it as the provider — a PID the kernel
    /// has since reused (e.g. by a manual `darkbloom update`) must NOT be
    /// force-killed as a stale lock owner. Optional for backward compatibility
    /// with state files written before this field existed.
    public var processIdentity: ProcessIdentity?
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
    /// Per-slot KV-backend and MTP posture, one entry per model this daemon
    /// has an engine for, plus one synthetic entry for a model whose load
    /// FAILED (`kvBackend == nil`, `loadError != nil`) — a refused explicit
    /// paged request builds no engine at all, so absence is the only other
    /// evidence and inferring a fault from absence is guesswork.
    ///
    /// OPTIONAL, deliberately, and for the same reason as
    /// `BackendSlotCapacity.kvBackend`: nil ⇒ NOT REPORTED (a state file
    /// written by a pre-0.8.0 daemon), which a reader must render as
    /// UNKNOWN and never as "no slots". An empty array means the daemon
    /// reported and has nothing loaded.
    public var slots: [SlotPosture]?
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

    /// One loaded (or refused) slot's serving posture, as the daemon
    /// observed it at `writtenAt`. Everything here is a RESOLVED fact plus
    /// the request it was resolved from, because during a staged paged
    /// rollout "what did you ask for" and "what are you serving" are
    /// different questions and only the pair answers "is this box on
    /// paged?".
    public struct SlotPosture: Codable, Sendable, Equatable {
        public var model: String
        /// The KV backend the engine was ACTUALLY built with
        /// (`EngineV2Bridge.kvBackendKind.rawValue`: "paged" |
        /// "contiguous"). nil ⇒ no engine exists — either the load failed
        /// (see `loadError`) or the slot vanished between the capacity
        /// refresh and this write.
        public var kvBackend: String?
        /// What the daemon's OWN config asked for, after per-model
        /// override resolution: "auto" | "paged" | "contiguous"
        /// (`EngineV2KVBackendPolicy.parseSelection`). Recorded here rather
        /// than re-parsed by the CLI so a `provider.toml` edited after the
        /// daemon started cannot manufacture a phantom mismatch.
        public var kvBackendRequested: String
        /// WHY the engine degraded away from the backend it was asked for —
        /// `EngineV2Bridge.kvBackendFallbackReason` verbatim ("kill_switch",
        /// "crash_loop_guard", "kernel_preflight: …", "physical_capacity: …",
        /// "ineligible: …", "pool_construction_capacity: …",
        /// "invalid_dtype: …"). nil ⇒ no degrade. The same pair the
        /// heartbeat reports fleet-side (`kv_backend` +
        /// `kv_backend_fallback_reason`), mirrored here so the box-side
        /// `status`/`doctor` can answer "why contiguous?" without the
        /// coordinator. Optional and absent in pre-guard state files.
        public var kvBackendFallbackReason: String?
        /// MTP was configured for this slot (a drafter was requested).
        public var mtpEnabled: Bool
        /// MTP is actually producing drafts. `mtpEnabled && !mtpActive`, or
        /// `mtpActive` with a reason present, is the INERT state: the slot
        /// looks healthy, charges full drafter residency and emits zero
        /// drafts.
        public var mtpActive: Bool
        /// `MTPFallbackReason.rawValue` whenever MTP is not productively
        /// running — including `inert_kv_unsupported`, which is the
        /// enabled-but-inert case and is NOT a load failure.
        public var mtpInactiveReason: String?
        /// Verbatim `DaemonState.ModelLoadError.message` when this entry
        /// exists BECAUSE a load failed. Non-nil ⇒ the slot is not serving.
        public var loadError: String?

        public init(
            model: String,
            kvBackend: String? = nil,
            kvBackendRequested: String = "auto",
            kvBackendFallbackReason: String? = nil,
            mtpEnabled: Bool = false,
            mtpActive: Bool = false,
            mtpInactiveReason: String? = nil,
            loadError: String? = nil
        ) {
            self.model = model
            self.kvBackend = kvBackend
            self.kvBackendRequested = kvBackendRequested
            self.kvBackendFallbackReason = kvBackendFallbackReason
            self.mtpEnabled = mtpEnabled
            self.mtpActive = mtpActive
            self.mtpInactiveReason = mtpInactiveReason
            self.loadError = loadError
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
        processIdentity: ProcessIdentity? = nil,
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
        slots: [SlotPosture]? = nil,
        connectivity: Connectivity? = nil
    ) {
        self.schema = schema
        self.pid = pid
        self.processIdentity = processIdentity
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
        self.slots = slots
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

/// Joins the daemon's LIVE per-slot observations with its own KV-backend
/// config and its last model-load failure into the `DaemonState.slots`
/// inventory the `status`/`doctor` CLI renders.
///
/// The join exists because an explicitly requested paged backend that
/// cannot be built now REFUSES (`EngineV2ProductionError.pagedUnavailable`)
/// instead of degrading, so the failure builds no engine and leaves no live
/// slot behind. Without the synthetic error entry the only remaining
/// evidence would be the model's ABSENCE, and a diagnostic that infers a
/// fault from absence cannot distinguish "paged was refused" from "nobody
/// asked for that model".
///
/// Pure and static so the join rule is testable without a daemon.
public enum DaemonSlotPostureBuilder {
    /// One slot the daemon currently holds an engine for.
    public struct LiveSlot: Sendable, Equatable {
        public let model: String
        /// `EngineV2Bridge.kvBackendKind.rawValue` — the RESOLVED kind.
        public let kvBackend: String
        /// `EngineV2Bridge.kvBackendFallbackReason` — WHY the resolved kind
        /// differs from the request, nil when it does not (see
        /// `SlotPosture.kvBackendFallbackReason`).
        public let kvBackendFallbackReason: String?
        public let mtpEnabled: Bool
        public let mtpActive: Bool
        public let mtpInactiveReason: String?

        public init(
            model: String,
            kvBackend: String,
            kvBackendFallbackReason: String? = nil,
            mtpEnabled: Bool,
            mtpActive: Bool,
            mtpInactiveReason: String?
        ) {
            self.model = model
            self.kvBackend = kvBackend
            self.kvBackendFallbackReason = kvBackendFallbackReason
            self.mtpEnabled = mtpEnabled
            self.mtpActive = mtpActive
            self.mtpInactiveReason = mtpInactiveReason
        }
    }

    /// `live` slots first (sorted by model id), then at most one synthetic
    /// entry for `lastModelLoadError` — and only when that model has no live
    /// slot, because a model that failed once and then loaded is serving.
    public static func build(
        live: [LiveSlot],
        requestedGlobal: String,
        requestedByModel: [String: String],
        lastModelLoadError: DaemonState.ModelLoadError?
    ) -> [DaemonState.SlotPosture] {
        func requested(_ modelID: String) -> String {
            EngineV2KVBackendPolicy.parseSelection(
                global: requestedGlobal, byModel: requestedByModel, modelID: modelID
            ).selection.rawValue
        }
        var out = live.sorted { $0.model < $1.model }.map {
            DaemonState.SlotPosture(
                model: $0.model,
                kvBackend: $0.kvBackend,
                kvBackendRequested: requested($0.model),
                kvBackendFallbackReason: $0.kvBackendFallbackReason,
                mtpEnabled: $0.mtpEnabled,
                mtpActive: $0.mtpActive,
                mtpInactiveReason: $0.mtpInactiveReason)
        }
        if let failure = lastModelLoadError,
            !live.contains(where: { $0.model == failure.model })
        {
            out.append(
                DaemonState.SlotPosture(
                    model: failure.model,
                    kvBackend: nil,
                    kvBackendRequested: requested(failure.model),
                    loadError: failure.message))
        }
        return out
    }
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

    /// Built once. `write` runs on a ~2 s tick for the life of the daemon, and
    /// a fresh `JSONEncoder` per call is pure allocation for a configuration
    /// that never changes. `.sortedKeys` is deliberately NOT set: nothing
    /// diffs this file, no signature covers it, and stable key order costs a
    /// sort of every key on every tick.
    private static let sharedEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    private static let sharedDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    /// Atomically writes the snapshot. Best-effort: write failures are swallowed
    /// (diagnostics must never crash the serving daemon).
    ///
    /// `createDirectory(withIntermediateDirectories: true)` stays on the write
    /// path deliberately. Memoizing it would save one mkdir that returns
    /// EEXIST — nothing, next to the atomic write beside it — in exchange for
    /// a lock, a mutable global, and a daemon that stops persisting state for
    /// the rest of its life if anything ever removes the directory underneath
    /// it. Keep the syscall.
    ///
    /// Moving the write off the caller's actor is the change with real value
    /// here and is deliberately NOT attempted: it is a concurrency change to
    /// the path `status`, `doctor` and the watchdog all read.
    public static func write(_ state: DaemonState, to url: URL = DaemonStateFile.path()) {
        do {
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try sharedEncoder.encode(state)
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
        guard let state = try? sharedDecoder.decode(DaemonState.self, from: data) else { return nil }
        guard state.schema == DaemonState.currentSchema else { return nil }
        return state
    }
}
