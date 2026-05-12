/// Async telemetry client. Owns a background batcher task that collects
/// events and POSTs them to the coordinator in batches.
///
/// The client is a global singleton (`TelemetryClient.shared`). Call-sites
/// never block on the network; overflow spills to disk via
/// `TelemetryOverflowQueue`.
///
/// Identity fields (version, machine_id, source) are stamped automatically
/// on every event so call-sites don't need to provide them.

import Foundation
#if canImport(os)
import os
#endif

// MARK: - Configuration

/// Configuration for the telemetry client.
public struct TelemetryClientConfig: Sendable {
    /// Coordinator base URL. WebSocket URLs (wss://, ws://) are normalized
    /// to their HTTP(S) base for the telemetry ingest endpoint.
    public var coordinatorURL: String

    /// Device-linked auth token for `Authorization: Bearer ...`. When nil,
    /// events are sent anonymously (stricter server-side rate limits).
    public var authToken: String?

    /// This component's version (e.g. "0.4.0-swift").
    public var version: String

    /// Stable per-machine identifier (usually the provider's SE public key).
    public var machineId: String

    /// Account the machine is linked to, if any.
    public var accountId: String?

    /// Source tag for all events coming through this client.
    public var source: TelemetrySource

    /// Max number of events per HTTP batch. The coordinator accepts up to 100.
    public var maxBatch: Int

    /// How often to flush a partially-filled batch (seconds).
    public var flushIntervalSeconds: TimeInterval

    /// Max events held in the in-memory buffer before spilling to disk.
    public var memQueueCap: Int

    public init(
        coordinatorURL: String,
        source: TelemetrySource = .provider,
        authToken: String? = nil,
        version: String = ProviderCore.version,
        machineId: String = "",
        accountId: String? = nil,
        maxBatch: Int = 50,
        flushIntervalSeconds: TimeInterval = 10.0,
        memQueueCap: Int = 1000
    ) {
        self.coordinatorURL = coordinatorURL
        self.authToken = authToken
        self.version = version
        self.machineId = machineId
        self.accountId = accountId
        self.source = source
        self.maxBatch = maxBatch
        self.flushIntervalSeconds = flushIntervalSeconds
        self.memQueueCap = memQueueCap
    }
}

// MARK: - Client

/// Global telemetry pipeline. Thread-safe; the `emit()` path never blocks
/// on I/O. All mutable state is accessed through `withLock` for async-context
/// safety. A detached Task runs the periodic flush loop.
public final class TelemetryClient: @unchecked Sendable {

    /// Global singleton. Configure via `TelemetryClient.shared.configure(_:)`
    /// before first use. Until configured, events are silently dropped.
    public static let shared = TelemetryClient()

    private let logger = Logger(subsystem: "dev.darkbloom.provider", category: "telemetry")

    // State protected by a lock -- avoids actor overhead on the hot emit path.
    // All access goes through `withLock` for async-context safety.
    private let lock = NSLock()
    private var buffer: [TelemetryEvent] = []
    private var config: TelemetryClientConfig?
    private var flushTask: Task<Void, Never>?
    private var isShutdown = false

    private let urlSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 15
        return URLSession(configuration: cfg)
    }()

    private init() {}

    // MARK: - Setup

    /// Configure the telemetry pipeline. Must be called before events can flow.
    /// Safe to call multiple times (reconfigures).
    public func configure(_ config: TelemetryClientConfig) {
        let needsFlushTask = lock.withLock {
            self.config = config
            let needs = flushTask == nil && !isShutdown
            return needs
        }

        if needsFlushTask {
            startFlushLoop()
        }

        logger.info("Telemetry configured: endpoint=\(Self.ingestEndpoint(from: config.coordinatorURL))")
    }

    /// Update the auth token after device linking.
    public func setAuthToken(_ token: String?) {
        lock.withLock { config?.authToken = token }
    }

    /// Update the machine ID (e.g. after SE key generation).
    public func setMachineId(_ machineId: String) {
        lock.withLock { config?.machineId = machineId }
    }

    /// Update the account ID (e.g. after device linking).
    public func setAccountId(_ accountId: String?) {
        lock.withLock { config?.accountId = accountId }
    }

    // MARK: - Emit

    /// Non-blocking emit. Drops the event if not configured or if shutdown.
    /// When the in-memory buffer is full, spills to the disk overflow queue
    /// rather than dropping events.
    public func emit(_ event: TelemetryEvent) {
        // Capture everything we need under the lock in one scoped call.
        let result: EmitResult = lock.withLock {
            guard let cfg = config, !isShutdown else {
                return .dropped
            }

            var stamped = event
            stamp(&stamped, config: cfg)

            if buffer.count >= cfg.memQueueCap {
                return .spillToDisk(stamped)
            }

            buffer.append(stamped)

            if buffer.count >= cfg.maxBatch {
                let batch = extractBatch(max: cfg.maxBatch)
                let endpoint = Self.ingestEndpoint(from: cfg.coordinatorURL)
                return .flushBatch(batch ?? [], endpoint: endpoint, authToken: cfg.authToken)
            }

            return .buffered
        }

        switch result {
        case .dropped, .buffered:
            break
        case .spillToDisk(let ev):
            TelemetryOverflowQueue.shared.push(ev)
        case .flushBatch(let batch, let endpoint, let authToken):
            Task {
                await self.sendBatch(batch, endpoint: endpoint, authToken: authToken)
            }
        }
    }

    /// Convenience: build and emit in one call.
    public func emit(
        kind: TelemetryKind,
        severity: TelemetrySeverity,
        message: String,
        fields: [String: AnyCodableValue]? = nil,
        stack: String? = nil,
        requestId: String? = nil
    ) {
        var ev = TelemetryEvent(
            source: .provider,
            severity: severity,
            kind: kind,
            message: message
        )
        if let fields = fields {
            ev.fields = TelemetryFieldFilter.filter(fields)
        }
        if let stack = stack {
            ev.stack = stack
        }
        if let requestId = requestId {
            ev.requestId = requestId
        }
        emit(ev)
    }

    // MARK: - Shutdown

    /// Gracefully flush all pending events and stop the flush loop.
    /// Call from the shutdown path (e.g. before process exit).
    public func shutdown() async {
        let snapshot: ShutdownSnapshot = lock.withLock {
            isShutdown = true
            flushTask?.cancel()
            flushTask = nil
            let pending = buffer
            buffer.removeAll()
            guard let cfg = config else {
                return .empty
            }
            return .flush(
                events: pending,
                endpoint: Self.ingestEndpoint(from: cfg.coordinatorURL),
                authToken: cfg.authToken
            )
        }

        switch snapshot {
        case .empty:
            break
        case .flush(let events, let endpoint, let authToken):
            if !events.isEmpty {
                await sendBatch(events, endpoint: endpoint, authToken: authToken)
            }
        }
    }

    /// Synchronous shutdown for use from signal handlers. Writes remaining
    /// events to the disk queue rather than attempting a network send.
    public func shutdownSync() {
        let pending: [TelemetryEvent] = lock.withLock {
            isShutdown = true
            flushTask?.cancel()
            flushTask = nil
            let events = buffer
            buffer.removeAll()
            return events
        }

        for ev in pending {
            TelemetryOverflowQueue.shared.push(ev)
        }
    }

    // MARK: - Flush Loop

    private func startFlushLoop() {
        let task = Task.detached { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }

                let interval: TimeInterval = self.lock.withLock {
                    self.config?.flushIntervalSeconds ?? 10.0
                }

                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return // Cancelled
                }

                await self.flushOnce()
            }
        }

        lock.withLock {
            flushTask = task
        }
    }

    private func flushOnce() async {
        let snapshot: FlushSnapshot = lock.withLock {
            guard let cfg = config else {
                return .noConfig
            }
            let batch = extractBatch(max: cfg.maxBatch)
            let endpoint = Self.ingestEndpoint(from: cfg.coordinatorURL)
            let authToken = cfg.authToken
            let bufferEmpty = buffer.isEmpty
            if let batch = batch {
                return .sendBatch(batch, endpoint: endpoint, authToken: authToken)
            } else if bufferEmpty {
                return .drainDisk(endpoint: endpoint, authToken: authToken, limit: cfg.maxBatch)
            }
            return .noConfig
        }

        switch snapshot {
        case .noConfig:
            break
        case .sendBatch(let batch, let endpoint, let authToken):
            await sendBatch(batch, endpoint: endpoint, authToken: authToken)
        case .drainDisk(let endpoint, let authToken, let limit):
            await drainDiskQueue(endpoint: endpoint, authToken: authToken, limit: limit)
        }
    }

    // MARK: - Batch extraction (must hold lock)

    /// Extract up to `max` events from the buffer. Returns nil if empty.
    /// Caller must hold `lock`.
    private func extractBatch(max: Int) -> [TelemetryEvent]? {
        guard !buffer.isEmpty else { return nil }
        let count = min(buffer.count, max)
        let batch = Array(buffer.prefix(count))
        buffer.removeFirst(count)
        return batch
    }

    // MARK: - Network

    private func sendBatch(
        _ events: [TelemetryEvent],
        endpoint: String,
        authToken: String?
    ) async {
        guard !events.isEmpty, let url = URL(string: endpoint) else { return }

        let batch = TelemetryBatch(events: events)
        let encoder = JSONEncoder()

        guard let body = try? encoder.encode(batch) else {
            logger.warning("Telemetry: failed to encode batch of \(events.count) events")
            spillToDisk(events)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body

        do {
            let (_, response) = try await urlSession.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                logger.warning("Telemetry ingest failed: HTTP \(http.statusCode)")
                spillToDisk(events)
            }
        } catch {
            logger.debug("Telemetry send failed: \(error.localizedDescription)")
            spillToDisk(events)
        }
    }

    private func spillToDisk(_ events: [TelemetryEvent]) {
        for ev in events {
            TelemetryOverflowQueue.shared.push(ev)
        }
    }

    private func drainDiskQueue(endpoint: String, authToken: String?, limit: Int) async {
        let events = TelemetryOverflowQueue.shared.drain(limit: limit)
        guard !events.isEmpty else { return }

        let batch = TelemetryBatch(events: events)
        guard let url = URL(string: endpoint),
              let body = try? JSONEncoder().encode(batch) else {
            for ev in events {
                TelemetryOverflowQueue.shared.push(ev)
            }
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body

        do {
            let (_, response) = try await urlSession.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                logger.debug("Telemetry disk drain failed: HTTP \(http.statusCode), re-queuing")
                for ev in events { TelemetryOverflowQueue.shared.push(ev) }
            }
        } catch {
            logger.debug("Telemetry disk drain failed: \(error.localizedDescription), re-queuing")
            for ev in events { TelemetryOverflowQueue.shared.push(ev) }
        }
    }

    // MARK: - Stamping

    /// Stamp server-relevant defaults (version, machine_id, source, account)
    /// that individual call sites don't bother setting.
    private func stamp(_ ev: inout TelemetryEvent, config: TelemetryClientConfig) {
        if ev.version == nil || ev.version?.isEmpty == true {
            ev.version = config.version
        }
        if ev.machineId == nil || ev.machineId?.isEmpty == true {
            ev.machineId = config.machineId.isEmpty ? nil : config.machineId
        }
        if ev.accountId == nil || ev.accountId?.isEmpty == true {
            ev.accountId = config.accountId
        }
        // Source is always the client's configured source -- trust the transport.
        ev.source = config.source
    }

    // MARK: - URL normalization

    /// Convert a coordinator URL (which may be a WebSocket URL) to the HTTPS
    /// telemetry ingest endpoint.
    public static func ingestEndpoint(from coordinatorURL: String) -> String {
        var base = coordinatorURL
        while base.hasSuffix("/") {
            base = String(base.dropLast())
        }
        if base.hasPrefix("wss://") {
            base = "https://" + base.dropFirst("wss://".count)
        } else if base.hasPrefix("ws://") {
            base = "http://" + base.dropFirst("ws://".count)
        }
        if base.hasSuffix("/ws/provider") {
            base = String(base.dropLast("/ws/provider".count))
        }
        while base.hasSuffix("/") {
            base = String(base.dropLast())
        }
        return base + "/v1/telemetry/events"
    }
}

// MARK: - Internal result types (avoid holding locks across await points)

private enum EmitResult {
    case dropped
    case buffered
    case spillToDisk(TelemetryEvent)
    case flushBatch([TelemetryEvent], endpoint: String, authToken: String?)
}

private enum FlushSnapshot {
    case noConfig
    case sendBatch([TelemetryEvent], endpoint: String, authToken: String?)
    case drainDisk(endpoint: String, authToken: String?, limit: Int)
}

private enum ShutdownSnapshot {
    case empty
    case flush(events: [TelemetryEvent], endpoint: String, authToken: String?)
}

// MARK: - Logger shim

#if !canImport(os)
private struct Logger {
    let subsystem: String
    let category: String
    func info(_ msg: String) { print("[\(category)] INFO: \(msg)") }
    func warning(_ msg: String) { print("[\(category)] WARN: \(msg)") }
    func debug(_ msg: String) { print("[\(category)] DEBUG: \(msg)") }
}
#endif
