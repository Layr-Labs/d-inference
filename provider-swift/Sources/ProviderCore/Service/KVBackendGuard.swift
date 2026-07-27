import Foundation

/// The crash-loop KV-backend guard: a small on-disk record the watchdog
/// persists after `WatchdogPolicy.crashLoopTripThreshold` consecutive
/// crash-loop-shaped restarts (`WatchdogPolicy.crashLoopCount`).
///
/// WHY IT EXISTS. v0.8.0 resolves `.auto` to PAGED, and a paged defect that
/// kills the daemon at load or first decode had no automated way back: the
/// provider's launchd job has `KeepAlive = false`, so the watchdog is the
/// only restarter — and it restarted the same binary into the same config
/// every ~5 minutes, unbounded. In-process engine recovery rebuilds on the
/// same resolved backend, and the fleet has no push channel (a fleet-wide
/// rollback is a release), so the only machine that can flip a
/// crash-looping box back to contiguous is that box itself. This record is
/// that flip.
///
/// EFFECT. While the record is present AND its `providerVersion` equals the
/// RUNNING binary's version, `.auto` resolves CONTIGUOUS with
/// `kvBackendFallbackReason = "crash_loop_guard"`
/// (`EngineV2KVBackendPolicy.crashLoopGuardForcesContiguous`, enforced in
/// `EngineV2Factory.prepareProductionBackend` — the same deepest layer the
/// kill switch is enforced at, so no call path bypasses it). An EXPLICIT
/// `engine_v2_kv_backend = "paged"` (global or by-model) is NOT overridden:
/// operator intent beats automation, the same philosophy that makes the
/// kill switch a degrade rather than a refusal.
///
/// CLEARING — exactly two paths, both deliberate:
///
///   * A NEW BINARY VERSION. The record binds only the version that
///     tripped it: a mismatched version reads as inactive, and the daemon
///     deletes a mismatched record at startup
///     (`KVBackendGuardStore.clearIfStale`). A release is the fleet's only
///     fix-delivery vector, so "new version" IS the retry signal.
///   * MANUAL: `darkbloom doctor --clear-backend-guard`.
///
///   There is deliberately NO time-based auto-retry: a guard that re-tries
///   paged every N hours re-enters the ~5-minute crash loop daily, which is
///   the exact failure this record exists to stop.
///
/// FAIL OPEN. A missing, unreadable, or corrupt record reads as "no guard"
/// (`read` returns nil) and `.auto` resolves normally — garbage on disk
/// must never take a healthy box off paged, and must never crash anything.
public struct KVBackendGuard: Codable, Equatable, Sendable {
    /// Epoch seconds when the watchdog tripped the guard. Preserved across
    /// re-trips of the same version (`KVBackendCrashLoopGuard.trip`) so
    /// `darkbloom status` reports the age of the FIRST trip, not the most
    /// recent crash.
    public var trippedAt: Double
    /// `ProviderCore.version` of the binary that tripped the guard. The
    /// guard binds only this version — see CLEARING above.
    public var providerVersion: String
    /// The consecutive crash-loop-restart count at the most recent trip
    /// write (diagnostic; keeps climbing if the guarded binary still
    /// crashes for a non-paged reason).
    public var crashCount: Int

    public init(trippedAt: Double, providerVersion: String, crashCount: Int) {
        self.trippedAt = trippedAt
        self.providerVersion = providerVersion
        self.crashCount = crashCount
    }

    enum CodingKeys: String, CodingKey {
        case trippedAt = "tripped_at"
        case providerVersion = "provider_version"
        case crashCount = "crash_count"
    }
}

/// Reads/writes the guard record at `~/.darkbloom/kv-backend-guard.json` —
/// the same directory discipline as `WatchdogState` / `DaemonStateFile`
/// (atomic writes, same parent dir, env-var path override).
///
/// UNLIKE those two, the path override (`DARKBLOOM_KV_BACKEND_GUARD`) is
/// resolved from an INJECTED environment dictionary, not straight from
/// `ProcessInfo`: the reader that matters is
/// `EngineV2Factory.prepareProductionBackend`, whose hermetic-test seam is
/// its `environment:` parameter (the kill switch reads through the same
/// seam), and a store that peeked at the real process environment would
/// punch a hole in it. Production callers pass the process environment and
/// get the default path.
public enum KVBackendGuardStore {

    /// Path override, resolved from the CALLER's environment (see above).
    public static let pathEnvKey = "DARKBLOOM_KV_BACKEND_GUARD"

    public static func path(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment[pathEnvKey], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".darkbloom/kv-backend-guard.json")
    }

    /// nil when the record is missing, unreadable, or garbage — the fail-open
    /// contract: `.auto` then resolves normally (paged).
    public static func read(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> KVBackendGuard? {
        let url = path(environment: environment)
        guard let data = try? Data(contentsOf: url),
            let record = try? JSONDecoder().decode(KVBackendGuard.self, from: data)
        else { return nil }
        return record
    }

    /// Atomically persist `record`. Returns false on failure so the watchdog
    /// can log it — a guard that silently failed to persist leaves the box in
    /// the unbounded crash loop the caller believes it just stopped.
    @discardableResult
    public static func write(
        _ record: KVBackendGuard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let url = path(environment: environment)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(record).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Delete the record (the manual-clear verb's body). Returns false only
    /// when a record exists and could not be removed; clearing an absent
    /// record is a success — the desired state is "no guard".
    @discardableResult
    public static func clear(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let url = path(environment: environment)
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    /// Delete a record whose version no longer matches the running binary,
    /// returning the record that was cleared (nil when nothing was cleared).
    /// Called at daemon startup: the version check already keeps a stale
    /// record INERT, but leaving it on disk would make `darkbloom status`
    /// describe a guard that can never bind again.
    @discardableResult
    public static func clearIfStale(
        runningVersion: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> KVBackendGuard? {
        guard let record = read(environment: environment),
            record.providerVersion != runningVersion
        else { return nil }
        return clear(environment: environment) ? record : nil
    }
}

/// The trip action the watchdog's recovery path invokes at the threshold:
/// persist the record, then emit the ERROR `engine_health` trip event.
public enum KVBackendCrashLoopGuard {

    /// Persist the guard for the RUNNING binary version and emit the trip
    /// telemetry. Returns whether the record reached disk.
    ///
    /// `providerVersion` is `ProviderCore.version` of the tripping process —
    /// the watchdog runs the same binary it protects, so in the dominant
    /// case (no self-update in flight) this is exactly the version that was
    /// crash-looping. The one skew window — a long-lived watchdog process
    /// older than a freshly self-updated on-disk binary — can only be
    /// reached through a BLOCKED candidate rollback (a viable rollback
    /// suppresses the trip entirely; see `WatchdogRecoveryService`), and a
    /// version-mismatched record simply stays inert: fail open to today's
    /// behavior, never a wrong flip.
    ///
    /// Re-trips of the same version (the guarded binary still crashing, for
    /// whatever reason) refresh `crashCount` but keep the ORIGINAL
    /// `trippedAt`, so the guard's reported age stays the age of the trip.
    ///
    /// TELEMETRY TRANSPORT: the event is built by `EngineHealthEvent.make`
    /// (the one engine-health builder) but pushed straight to the
    /// `TelemetryOverflowQueue` disk queue rather than through
    /// `TelemetryClient.shared` — the watchdog process never configures the
    /// client (an unconfigured client silently DROPS), and the daemon is
    /// down at trip time anyway. This is the panic hook's transport
    /// (`PanicHook.swift`): the guarded daemon this trip guarantees will
    /// boot drains the queue to the coordinator once it reconnects.
    @discardableResult
    public static func trip(
        crashCount: Int,
        now: Double,
        lastKnownModel: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        emitTelemetry: (@Sendable (TelemetryEvent) -> Void)? = nil
    ) -> Bool {
        let existing = KVBackendGuardStore.read(environment: environment)
        let record = KVBackendGuard(
            trippedAt: existing?.providerVersion == ProviderCore.version
                ? existing?.trippedAt ?? now
                : now,
            providerVersion: ProviderCore.version,
            crashCount: max(crashCount, existing?.crashCount ?? 0))
        let wrote = KVBackendGuardStore.write(record, environment: environment)

        var event = EngineHealthEvent.make(
            severity: .error,
            message: "engine_v2: crash-loop backend guard tripped after \(crashCount) "
                + "short-uptime restarts on v\(ProviderCore.version) — `.auto` resolves "
                + "contiguous on this box until the next release or a manual clear"
                + (wrote ? "" : " (WARNING: guard record could not be persisted)"),
            operation: "engine_v2_crash_loop_guard",
            // The daemon died before anyone could ask it which slot was
            // loading; the last daemon-state snapshot's current model is the
            // best available attribution, and "unknown" is the honest
            // fallback — never a guess.
            model: lastKnownModel ?? "unknown",
            // Omitted, not guessed: the crashing slot's backend was never
            // observed by this process. The `reason` field carries the same
            // class token the guarded slot's heartbeat will report, so the
            // trip event and the resulting degrade join on one value.
            kvBackend: nil,
            extra: ["reason": .string("crash_loop_guard")])
        // Straight-to-disk events skip TelemetryClient's identity stamping;
        // set the one field the fleet dashboard groups trips by.
        event.version = ProviderCore.version
        emitEngineHealth(event, sink: emitTelemetry ?? { TelemetryOverflowQueue.shared.push($0) })
        return wrote
    }
}
