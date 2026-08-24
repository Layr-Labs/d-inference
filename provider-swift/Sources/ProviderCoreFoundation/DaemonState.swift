import Foundation

/// Snapshot of the running provider daemon's state, written periodically to a
/// small JSON file so the `status` / `doctor` CLI commands — and the Darkbloom
/// macOS app — can show live state and, critically, the coordinator's latest
/// `trust_status` reason, which is otherwise only logged.
///
/// The daemon, CLI, and app run as separate processes with no IPC today (only
/// a PID file). A state file is the smallest addition that fits: the daemon
/// already assembles this exact data every heartbeat; writing it atomically
/// lets any consumer read it with zero IPC, and it survives the daemon being
/// asleep or wedged.
///
/// Lives in ProviderCoreFoundation (the no-MLX, Linux-buildable layer) so the
/// app can link the schema without dragging in the inference runtime. The
/// writer is the daemon; the CLI and the app are read-only consumers.
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
    /// The daemon's availability-schedule posture, evaluated by
    /// `ProviderLoop.currentDaemonState()` from the SAME
    /// `Schedule.from(config:)` evaluation the serving loop uses. nil ⇒ NOT
    /// REPORTED (a state file written by a pre-schedule-reporting daemon) —
    /// readers must render UNKNOWN, falling back to the historical
    /// "always available while running" assumption rather than inventing a
    /// schedule.
    public var schedule: SchedulePosture?
    /// Who this daemon is: the operator-facing provider name plus the
    /// earning identity. nil ⇒ NOT REPORTED (older writer). Never secrets —
    /// this file is read by `status`/`doctor` and the macOS app.
    public var identity: Identity?

    /// Availability posture derived from `[schedule]` in provider.toml.
    ///
    /// Mode semantics (stringly stable, decoded by the app):
    ///   - "always": no effective schedule (absent, disabled, or unparsable),
    ///     matching `Schedule.from(config:)` returning nil.
    ///   - "scheduled-active": a window matched at `writtenAt`.
    ///   - "scheduled-off": no window matched at `writtenAt`.
    ///
    /// Note the scheduled-off caveat: the supervised serving loop only exists
    /// INSIDE a window, so a `scheduled-off` file ages out of freshness fast —
    /// the mode records the posture at `writtenAt`, and `nextChangeAtEpoch`
    /// (the same wall-clock horizon `durationUntilNextActive`/`durationUntilInactive`
    /// computed for the supervisor) tells the reader when it flips.
    public struct SchedulePosture: Codable, Sendable, Equatable {
        /// "always" | "scheduled-active" | "scheduled-off" (see type docs).
        public var mode: String
        /// `Schedule.describe()` (e.g. "Mon,Tue,Wed,Thu,Fri 20:00-07:00 |
        /// Sat,Sun 09:00-18:00"), or "always available" when mode == "always".
        public var summary: String
        /// Epoch seconds of the next schedule boundary as computed by the
        /// daemon-side `Schedule` evaluator at `writtenAt`: window end while
        /// active, next window open while off. nil when mode == "always"
        /// (no boundary exists).
        public var nextChangeAtEpoch: Double?

        public init(mode: String, summary: String, nextChangeAtEpoch: Double? = nil) {
            self.mode = mode
            self.summary = summary
            self.nextChangeAtEpoch = nextChangeAtEpoch
        }
    }

    /// Provider identity as the daemon knows it, for read-only consumers that
    /// must name or address this machine without re-reading provider.toml.
    public struct Identity: Codable, Sendable, Equatable {
        /// `[provider] name` from provider.toml (e.g. "darkbloom-mac16-1").
        public var providerName: String
        /// Account id returned by device login. It is an identifier, not a
        /// credential; authenticated earnings requests still require the
        /// provider token.
        public var operatorAddress: String?
        /// X25519 key advertised for this daemon session. The key is ephemeral
        /// across daemon restarts, so account history also carries a
        /// key-to-machine mapping for stable "This Mac" grouping.
        public var providerKey: String?

        public init(
            providerName: String,
            operatorAddress: String? = nil,
            providerKey: String? = nil
        ) {
            self.providerName = providerName
            self.operatorAddress = operatorAddress
            self.providerKey = providerKey
        }
    }

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
        connectivity: Connectivity? = nil,
        schedule: SchedulePosture? = nil,
        identity: Identity? = nil
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
        self.schedule = schedule
        self.identity = identity
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
