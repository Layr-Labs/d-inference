/// Telemetry wire types -- mirror of
/// `coordinator/protocol/telemetry.go`.
///
/// JSON shapes MUST match the Go definitions. Source, Severity, and Kind raw
/// values are the exact strings the coordinator expects. Any mismatch silently
/// coerces to "custom" server-side, which breaks filtering.

import Foundation

// MARK: - Enums

/// Source of a telemetry event (which component produced it).
/// Raw values match `TelemetrySource` constants in Go.
public enum TelemetrySource: String, Codable, Sendable {
    case coordinator
    case provider
    case app
    case console
    case bridge
}

/// Severity level, narrowed subset of syslog/RFC 5424.
/// Raw values match `TelemetrySeverity` constants in Go.
public enum TelemetrySeverity: String, Codable, Sendable {
    case debug
    case info
    case warn
    case error
    case fatal
}

/// Coarse categorization for filtering in the admin UI.
/// Raw values match `TelemetryKind` constants in Go.
/// `CaseIterable` mirrors the Go `KnownKinds()` set so the symmetry test can
/// pin the kind list + count across layers.
public enum TelemetryKind: String, Codable, Sendable, CaseIterable {
    case panic
    case httpError = "http_error"
    case protocolError = "protocol_error"
    case backendCrash = "backend_crash"
    case attestationFailure = "attestation_failure"
    case inferenceError = "inference_error"
    case runtimeMismatch = "runtime_mismatch"
    case connectivity
    /// Out-of-memory: a jetsam/crash-log OOM detected on the next launch, or a
    /// critical memory-pressure event observed before death.
    case oom
    /// Engine-health diagnostics for the first-token wedge (model-load
    /// milestones, periodic engine snapshots, wedge-suspected transitions). All
    /// fields are NON-PRIVATE operational counters — see `WedgeMonitor`.
    case engineHealth = "engine_health"
    case log
    case custom
}

// MARK: - Event

/// Single telemetry record. Serialization matches the canonical Go
/// `TelemetryEvent` wire shape exactly: snake_case keys, omitting empty
/// optional fields.
public struct TelemetryEvent: Codable, Sendable {
    public var id: String
    /// ISO 8601 with fractional seconds, matching Go `time.Time`
    /// (RFC 3339 with nanosecond precision).
    public var timestamp: String
    public var source: TelemetrySource
    public var severity: TelemetrySeverity
    public var kind: TelemetryKind
    public var version: String?
    public var machineId: String?
    public var accountId: String?
    public var requestId: String?
    public var sessionId: String?
    public var message: String
    public var fields: [String: AnyCodableValue]?
    public var stack: String?

    enum CodingKeys: String, CodingKey {
        case id, timestamp, source, severity, kind, message
        case version
        case machineId = "machine_id"
        case accountId = "account_id"
        case requestId = "request_id"
        case sessionId = "session_id"
        case fields, stack
    }

    /// Build a new event with sensible defaults (id, timestamp, session_id).
    public init(
        source: TelemetrySource,
        severity: TelemetrySeverity,
        kind: TelemetryKind,
        message: String
    ) {
        self.id = UUID().uuidString.lowercased()
        self.timestamp = Self.isoNow()
        self.source = source
        self.severity = severity
        self.kind = kind
        self.message = message
        self.sessionId = TelemetrySession.id
    }

    // MARK: - Builder methods

    /// Attach structured fields.
    public func withFields(_ fields: [String: AnyCodableValue]) -> TelemetryEvent {
        var copy = self
        copy.fields = fields
        return copy
    }

    /// Attach a single field, merging into existing fields.
    public func withField(_ key: String, _ value: AnyCodableValue) -> TelemetryEvent {
        var copy = self
        var merged = copy.fields ?? [:]
        merged[key] = value
        copy.fields = merged
        return copy
    }

    /// Attach a stack trace.
    public func withStack(_ stack: String) -> TelemetryEvent {
        var copy = self
        copy.stack = stack
        return copy
    }

    /// Attach a request ID for correlation.
    public func withRequestId(_ requestId: String) -> TelemetryEvent {
        var copy = self
        copy.requestId = requestId
        return copy
    }

    // MARK: - Timestamp

    /// ISO 8601 formatter is not Sendable, but we only access it through this
    /// function which creates a fresh instance each call. The cost is negligible
    /// for the retained compatibility event construction path.
    static func isoNow() -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt.string(from: Date())
    }
}

// MARK: - Batch

/// Retained historical batch wire shape; client ingestion is disabled.
public struct TelemetryBatch: Codable, Sendable {
    public var events: [TelemetryEvent]

    public init(events: [TelemetryEvent]) {
        self.events = events
    }
}

// MARK: - Session ID

/// Retained per-process compatibility identifier. Client events are not
/// transmitted to or grouped by an admin UI.
public enum TelemetrySession {
    public static let id: String = UUID().uuidString.lowercased()
}

// MARK: - AnyCodableValue

/// Lightweight Codable wrapper for JSON-compatible primitive values.
/// Used for the `fields` dictionary on telemetry events.
public struct AnyCodableValue: Codable, Sendable, CustomStringConvertible {
    public let value: any Sendable

    public init(_ value: any Sendable) {
        self.value = value
    }

    // Convenience initializers for common types
    public static func string(_ s: String) -> AnyCodableValue { AnyCodableValue(s) }
    public static func int(_ i: Int) -> AnyCodableValue { AnyCodableValue(i) }
    public static func int64(_ i: Int64) -> AnyCodableValue { AnyCodableValue(i) }
    public static func double(_ d: Double) -> AnyCodableValue { AnyCodableValue(d) }
    public static func bool(_ b: Bool) -> AnyCodableValue { AnyCodableValue(b) }

    public var description: String {
        switch value {
        case let s as String: return s
        case let i as Int: return String(i)
        case let i as Int64: return String(i)
        case let d as Double: return String(d)
        case let b as Bool: return String(b)
        default: return "null"
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let b = try? container.decode(Bool.self) {
            value = b
        } else if let i = try? container.decode(Int64.self) {
            value = i
        } else if let d = try? container.decode(Double.self) {
            value = d
        } else if let s = try? container.decode(String.self) {
            value = s
        } else {
            value = "null" as String
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let b as Bool:
            try container.encode(b)
        case let i as Int:
            try container.encode(i)
        case let i as Int64:
            try container.encode(i)
        case let i as UInt64:
            try container.encode(i)
        case let d as Double:
            try container.encode(d)
        case let s as String:
            try container.encode(s)
        default:
            try container.encodeNil()
        }
    }
}

// MARK: - Field allowlist

/// Client-side allowlist. The coordinator enforces its own, but we preempt
/// bandwidth waste. Keys must match the server list in
/// `coordinator/api/telemetry_handlers.go`.
public enum TelemetryFieldFilter {
    private static let allowed: Set<String> = [
        "component", "operation", "duration_ms", "attempt", "endpoint",
        "status_code", "error_class", "error", "model", "backend",
        "exit_code", "signal", "hardware_chip", "memory_gb", "macos_version",
        "boot_macos_major", "boot_sip_status",
        "handler", "provider_id", "trust_level", "queue_depth", "reason",
        "runtime_component", "reconnect_count", "last_error", "ws_state",
        "billing_method", "payment_failed", "target",
        // OOM / memory-pressure fields (non-sensitive). Mirror in Go allowlist.
        "detect_source", "peak_memory_bytes", "report", "pressure",
        "available_bytes", "mlx_active_bytes", "memory_pressure", "in_flight",
        // Engine-health / first-token-wedge diagnostics (non-sensitive
        // operational counters). Mirror in Go + TS allowlists.
        "steps_executed", "admits", "first_tokens_emitted",
        "consecutive_admits_without_first_token", "seconds_since_last_step",
        "seconds_since_last_first_token", "num_running", "wedge_suspected",
        // Eval-in-flight + idle-clear + prefill-sampling-health diagnostics.
        "eval_in_flight_ms", "longest_eval_ms", "evals_completed",
        "idle_clear_in_flight_ms", "idle_clears_completed",
        "prefill_samples_accepted", "prefill_samples_dropped_floor",
        "prefill_samples_dropped_ceiling", "last_prefill_sample_tps",
        "observed_prefill_tps_ewma",
        // KV-budget sustained-rejection audit (v0.7.3 black-hole hardening):
        // reservation ids/byte counts/ages + memory snapshot terms — pure
        // operational bookkeeping, no prompt/response data. Mirror in Go + TS.
        "streak_seconds", "reservation_count", "reserved_bytes",
        "mlx_cache_bytes", "system_available_bytes", "reservations",
        "request_id", "age_seconds",
        // Media-through-engine_v2 tags (v0.7.5: bool + image/video/mixed kind) — a bare
        // boolean and a coarse image/video/mixed label; media/prompt content
        // NEVER rides telemetry. Mirror in Go + TS allowlists.
        "multimodal", "media_kind",
        // Exact-prefix replay telemetry. Counts and bounded enums only; never
        // token ids, prompt text, hashes, cache keys, or account scope.
        "prefix_reuse_strategy", "prefix_matched_tokens", "prefix_replay_tokens",
        "prefix_saved_tokens", "prefix_boundary_splits",
        "prefix_construction_failure", "prefix_capacity_refusal",
        "prefix_cold_fallback",
        // KV-backend discriminator (v0.8.0 paged rollout). `backend` stays the
        // ENGINE/runtime name ("engine_v2", "mlx-swift"); `kv_backend` is the
        // KV storage kind ("paged" | "contiguous"), the same key and vocabulary
        // as BackendSlotCapacity.kv_backend on the heartbeat wire.
        // `prefix_reuse_backend` carries the finer CBv2PrefixReuseBackend row
        // identity that "contiguous" alone cannot express.
        "kv_backend", "prefix_reuse_backend",
        // Paged KV pool metrics. Aggregate pool counters only — never page
        // contents or block hashes. Mirror in Go + TS allowlists.
        // pages_pinned / cow_events deliberately absent: no mechanism exists,
        // and a producerless key reads as a legitimate zero. See the Go mirror.
        "pool_utilization",
        // Paged pool re-slice residue. RAW BYTES, not a second ratio:
        // pool_utilization above is OCCUPANCY, and a grant-vs-pool ratio under
        // a near-identical name collides with it wherever a dashboard groups
        // by kv_backend. A clamped ratio also discards the overflow magnitude
        // at exactly the point co-residency diagnosis needs it. pool_bytes is
        // the denominator, shipped alongside the deltas so share-of-pool stays
        // derivable from raw terms. Mirror in Go + TS allowlists.
        "pool_bytes", "pool_deferred_growth_bytes", "pool_stranded_bytes",
        // MTP (speculative decode) posture. MTP inflates observed_decode_tps
        // with no discriminator, so a partially-MTP fleet biases coordinator
        // routing on a metric it believes is homogeneous. mtp_inactive_reason
        // carries MTPFallbackReason.rawValue plus "inert_kv_unsupported" —
        // enabled, drafter resident, zero rounds, rows skipped kv_unsupported.
        // Bounded enums and counters only; never draft tokens or prompt text.
        // mtp_proposed_tokens / mtp_accepted_tokens are the cumulative
        // counters behind mtp_acceptance_rate — the weights a roll-up needs.
        // Token COUNTS, never token contents.
        "mtp_enabled", "mtp_active", "mtp_inactive_reason",
        "mtp_acceptance_rate", "mtp_proposed_tokens", "mtp_accepted_tokens",
    ]

    /// Filter a dictionary to only the keys the coordinator accepts.
    public static func filter(_ input: [String: AnyCodableValue]) -> [String: AnyCodableValue]? {
        var out: [String: AnyCodableValue] = [:]
        for (k, v) in input where allowed.contains(k) {
            out[k] = v
        }
        return out.isEmpty ? nil : out
    }
}
