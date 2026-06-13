/// Telemetry wire types -- mirror of
/// `coordinator/internal/protocol/telemetry.go`.
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
public enum TelemetryKind: String, Codable, Sendable {
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
    /// compared to the network flush path.
    static func isoNow() -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt.string(from: Date())
    }
}

// MARK: - Batch

/// Wire shape for batch ingestion: `POST /v1/telemetry/events`.
public struct TelemetryBatch: Codable, Sendable {
    public var events: [TelemetryEvent]

    public init(events: [TelemetryEvent]) {
        self.events = events
    }
}

// MARK: - Session ID

/// Per-process UUID. Events from the same boot share this ID so the admin UI
/// can group a crash report with the log lines leading up to it.
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
/// `coordinator/internal/api/telemetry_handlers.go`.
public enum TelemetryFieldFilter {
    private static let allowed: Set<String> = [
        "component", "operation", "duration_ms", "attempt", "endpoint",
        "status_code", "error_class", "error", "model", "backend",
        "exit_code", "signal", "hardware_chip", "memory_gb", "macos_version",
        "handler", "provider_id", "trust_level", "queue_depth", "reason",
        "runtime_component", "reconnect_count", "last_error", "ws_state",
        "billing_method", "payment_failed", "target",
        // OOM / memory-pressure fields (non-sensitive). Mirror in Go allowlist.
        "detect_source", "peak_memory_bytes", "report", "pressure",
        "available_bytes", "mlx_active_bytes", "memory_pressure", "in_flight",
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
