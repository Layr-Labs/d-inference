/// TelemetryReporter — Ships local errors and crash reports from the macOS app
/// to the coordinator's /v1/telemetry/events endpoint.
///
/// The reporter is intentionally small and self-contained:
///   - Single global instance (`TelemetryReporter.shared`).
///   - Bounded in-memory buffer (500 events).
///   - Debounced network flush (3s idle or on buffer-full).
///   - No third-party dependency.
///
/// Identity: for now we ship unauthenticated. When the provider is linked via
/// `darkbloom login`, the app can pull the auth token from the provider
/// config and attach it as a Bearer header in a follow-up change.

import Foundation

/// Matches `coordinator/internal/protocol/telemetry.go` enum cases.
enum TelemetrySeverity: String {
    case debug, info, warn, error, fatal
}

/// Matches `TelemetryKind`.
enum TelemetryKind: String {
    case panic
    case httpError = "http_error"
    case protocolError = "protocol_error"
    case backendCrash = "backend_crash"
    case attestationFailure = "attestation_failure"
    case inferenceError = "inference_error"
    case runtimeMismatch = "runtime_mismatch"
    case connectivity
    case log
    case custom
}

/// Wire-shape matching `protocol.TelemetryEvent` in Go.
struct TelemetryEventPayload: Codable {
    let id: String
    let timestamp: String
    let source: String
    let severity: String
    let kind: String
    let version: String?
    let machine_id: String?
    let account_id: String?
    let request_id: String?
    let session_id: String?
    let message: String
    let fields: [String: AnyCodable]?
    let stack: String?
}

final class TelemetryReporter {
    static let shared = TelemetryReporter()

    /// Coordinator base URL. Set at app launch from ConfigManager.
    /// When nil, events are buffered but never flushed.
    var coordinatorBaseURL: URL?

    /// Optional device-linked auth token. When set, attached as Bearer on
    /// every ingest request.
    var authToken: String?

    /// Stable per-install identifier. Derived from hardware UUID or a
    /// one-time-generated UUID stored in UserDefaults.
    let machineID: String

    /// Per-launch session UUID so admin UI can group a run's events.
    let sessionID: String = UUID().uuidString

    /// App bundle version.
    let version: String

    private let queue = DispatchQueue(label: "dev.darkbloom.telemetry", qos: .utility)
    private var buffer: [TelemetryEventPayload] = []
    private let maxBuffer = 500
    private var flushWorkItem: DispatchWorkItem?
    private let flushDelay: TimeInterval = 3.0
    private let urlSession: URLSession

    private init() {
        self.urlSession = URLSession(configuration: .ephemeral)
        self.version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        self.machineID = Self.loadOrCreateMachineID()
    }

    // MARK: - Public API

    /// Emit a single event. Non-blocking; thread-safe.
    func emit(
        kind: TelemetryKind,
        severity: TelemetrySeverity,
        message: String,
        fields: [String: Any] = [:],
        stack: String? = nil,
        requestID: String? = nil
    ) {
        let ev = TelemetryEventPayload(
            id: UUID().uuidString,
            timestamp: Self.isoNow(),
            source: "app",
            severity: severity.rawValue,
            kind: kind.rawValue,
            version: version,
            machine_id: machineID,
            account_id: nil,
            request_id: requestID,
            session_id: sessionID,
            message: message,
            fields: Self.filter(fields),
            stack: stack
        )
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.buffer.count >= self.maxBuffer {
                // Drop the oldest rather than the newest — a live panic right
                // now is much more valuable than whatever old log line we'd
                // be preserving.
                self.buffer.removeFirst()
            }
            self.buffer.append(ev)
            self.scheduleFlush()
        }
    }

    /// Force-flush immediately. Safe to call from shutdown paths.
    func flushNow() {
        queue.async { [weak self] in self?.flush() }
    }

    // MARK: - Internals

    private func scheduleFlush() {
        flushWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        flushWorkItem = work
        queue.asyncAfter(deadline: .now() + flushDelay, execute: work)
    }

    private func flush() {
        guard !buffer.isEmpty, let base = coordinatorBaseURL else { return }
        let batch = Array(buffer.prefix(100))
        buffer.removeFirst(batch.count)

        guard let url = URL(string: "/v1/telemetry/events", relativeTo: base) else { return }
        var req = URLRequest(url: url.absoluteURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let tok = authToken {
            req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = 10

        let body: [String: Any] = [
            "events": batch.map { ev -> [String: Any] in
                var dict: [String: Any] = [
                    "id": ev.id,
                    "timestamp": ev.timestamp,
                    "source": ev.source,
                    "severity": ev.severity,
                    "kind": ev.kind,
                    "message": ev.message,
                ]
                if let v = ev.version { dict["version"] = v }
                if let m = ev.machine_id { dict["machine_id"] = m }
                if let s = ev.session_id { dict["session_id"] = s }
                if let r = ev.request_id { dict["request_id"] = r }
                if let f = ev.fields?.mapValues({ $0.value }) { dict["fields"] = f }
                if let s = ev.stack { dict["stack"] = s }
                return dict
            }
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let task = urlSession.dataTask(with: req) { [weak self] _, resp, err in
            if err != nil || (resp as? HTTPURLResponse)?.statusCode.rangeContains(200) != true {
                // Requeue the batch for a later retry. Stay bounded.
                self?.queue.async {
                    guard let self = self else { return }
                    let merged = batch + self.buffer
                    self.buffer = Array(merged.suffix(self.maxBuffer))
                    self.scheduleFlush()
                }
            }
        }
        task.resume()
    }

    private static func isoNow() -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt.string(from: Date())
    }

    /// Only pass fields allowed by the server-side allowlist. Values are
    /// coerced into JSON-safe primitives.
    private static let allowlist: Set<String> = [
        "component", "operation", "duration_ms", "attempt", "endpoint",
        "status_code", "error_class", "error", "model", "backend",
        "exit_code", "signal", "hardware_chip", "memory_gb", "macos_version",
        "handler", "provider_id", "trust_level", "queue_depth", "reason",
        "runtime_component", "reconnect_count", "last_error", "ws_state",
        "billing_method", "payment_failed", "target", "url", "user_agent",
        "route",
    ]

    private static func filter(_ input: [String: Any]) -> [String: AnyCodable]? {
        var out: [String: AnyCodable] = [:]
        for (k, v) in input where allowlist.contains(k) {
            out[k] = AnyCodable(v)
        }
        return out.isEmpty ? nil : out
    }

    private static func loadOrCreateMachineID() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: "darkbloom.machine_id"), !existing.isEmpty {
            return existing
        }
        let new = UUID().uuidString
        defaults.set(new, forKey: "darkbloom.machine_id")
        return new
    }
}

// MARK: - AnyCodable helper

/// Light-weight Codable wrapper that preserves basic JSON-compatible values.
struct AnyCodable: Codable {
    let value: Any
    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { value = v; return }
        if let v = try? c.decode(Int64.self) { value = v; return }
        if let v = try? c.decode(Double.self) { value = v; return }
        if let v = try? c.decode(String.self) { value = v; return }
        if let v = try? c.decode([String: AnyCodable].self) { value = v.mapValues { $0.value }; return }
        if let v = try? c.decode([AnyCodable].self) { value = v.map { $0.value }; return }
        value = NSNull()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let b as Bool: try c.encode(b)
        case let i as Int: try c.encode(i)
        case let i as Int64: try c.encode(i)
        case let d as Double: try c.encode(d)
        case let s as String: try c.encode(s)
        case let d as [String: Any]: try c.encode(d.mapValues { AnyCodable($0) })
        case let a as [Any]: try c.encode(a.map { AnyCodable($0) })
        default: try c.encodeNil()
        }
    }
}

private extension Range where Bound == Int {
    func contains(_ value: Int) -> Bool { self ~= value }
}

private extension Int {
    /// Convenience: `200..<300.rangeContains(x)` style check.
    func rangeContains(_ lower: Int) -> Bool {
        return self >= lower && self < lower + 100
    }
}
