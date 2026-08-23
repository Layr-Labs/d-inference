/// Privacy-disabled client telemetry facade.
///
/// The old implementation accepted free-form messages, stacks, request IDs,
/// and field values, buffered them in memory, spilled them to disk, and POSTed
/// them to the coordinator. An allowlist of field *names* cannot make arbitrary
/// values safe: inference errors can contain prompts, media URLs, tool input,
/// or generated output. The public API remains as a no-op so operational call
/// sites and injected test sinks do not need a flag day, but the production
/// singleton never persists or transmits an event.

import Foundation
#if canImport(os)
import os
#endif

public struct TelemetryClientConfig: Sendable {
    public var coordinatorURL: String
    public var authToken: String?
    public var version: String
    public var machineId: String
    public var accountId: String?
    public var source: TelemetrySource
    public var maxBatch: Int
    public var flushIntervalSeconds: TimeInterval
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

public final class TelemetryClient: @unchecked Sendable {
    public static let shared = TelemetryClient()

    private let logger = Logger(subsystem: "dev.darkbloom.provider", category: "telemetry")

    private init() {}

    /// Retains source compatibility while permanently disabling the sink.
    /// Legacy disk cleanup belongs to the common locked media-serving startup
    /// seam, not configuration, so connected mode cannot purge twice.
    public func configure(_ config: TelemetryClientConfig) {
        _ = config
        logger.info("Client telemetry is disabled for inference privacy")
    }

    public func setAuthToken(_ token: String?) { _ = token }
    public func setMachineId(_ machineId: String) { _ = machineId }
    public func setAccountId(_ accountId: String?) { _ = accountId }

    /// Deliberately drops every production event before buffering or I/O.
    public func emit(_ event: TelemetryEvent) { _ = event }

    public func emit(
        kind: TelemetryKind,
        severity: TelemetrySeverity,
        message: String,
        fields: [String: AnyCodableValue]? = nil,
        stack: String? = nil,
        requestId: String? = nil
    ) {
        _ = (kind, severity, message, fields, stack, requestId)
    }

    public func shutdown() async {}

    public func shutdownSync() {}

}

#if !canImport(os)
private struct Logger {
    let subsystem: String
    let category: String
    func info(_ msg: String) { print("[\(category)] INFO: \(msg)") }
}
#endif
