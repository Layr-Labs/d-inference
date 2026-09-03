import Foundation
import Testing

@testable import ProviderCore

/// The cross-tick timer state persistence.
@Suite("Watchdog state")
struct WatchdogStateTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("watchdog-state-\(UUID().uuidString).json")
    }

    @Test("state round-trips through disk")
    func roundTrip() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let original = WatchdogState(downSince: 123.5, lastRestartAt: 456.75)
        WatchdogStateStore.write(original, to: url)
        let read = WatchdogStateStore.read(from: url)
        #expect(read == original)
    }

    @Test("reading a missing file yields empty state, not an error")
    func missingFileIsEmpty() {
        let read = WatchdogStateStore.read(from: tempURL())
        #expect(read == WatchdogState())
        #expect(read.downSince == nil)
        #expect(read.lastRestartAt == nil)
    }

    @Test("write reports success, and failure on an unwritable path")
    func writeReportsOutcome() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(WatchdogStateStore.write(WatchdogState(downSince: 1), to: url))
        // /dev/null is a file, so it can never become a parent directory.
        #expect(!WatchdogStateStore.write(WatchdogState(), to: URL(fileURLWithPath: "/dev/null/watchdog/state.json")))
    }


    @Test("the state store rejects semantically corrupt counters as a corrupt file")
    func storeRejectsCorruptCounters() throws {
        func read(_ json: String) throws -> WatchdogState {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("watchdog-state-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: url) }
            try Data(json.utf8).write(to: url)
            return WatchdogStateStore.read(from: url)
        }
        // Valid JSON, impossible counters: the whole file is treated as
        // corrupt (fresh state) — the same fail-open posture as undecodable
        // JSON. `Int.max` in particular would otherwise reach the chain's
        // `+ 1` and trap the watchdog on every launchd relaunch.
        #expect(try read(
            #"{"down_since": 100, "last_restart_at": 50, "consecutive_crash_loop_restarts": \#(Int.max)}"#
        ) == WatchdogState())
        #expect(try read(
            #"{"consecutive_crash_loop_restarts": -3}"#
        ) == WatchdogState())
        #expect(try read(
            #"{"consecutive_crash_loop_restarts": \#(WatchdogStateStore.maxPlausibleCrashLoopRestarts + 1)}"#
        ) == WatchdogState())
        // Plausible-but-large is a real box, not corruption: kept — up to
        // and including the bound itself.
        #expect(try read(
            #"{"last_restart_at": 50, "consecutive_crash_loop_restarts": 500000}"#
        ).consecutiveCrashLoopRestarts == 500_000)
        #expect(try read(
            #"{"consecutive_crash_loop_restarts": \#(WatchdogStateStore.maxPlausibleCrashLoopRestarts)}"#
        ).consecutiveCrashLoopRestarts == WatchdogStateStore.maxPlausibleCrashLoopRestarts)
    }

    @Test("the counter and version round-trip through the state store")
    func counterRoundTrips() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("watchdog-state-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let original = WatchdogState(
            downSince: nil, lastRestartAt: 456.75, lastRestartVersion: "0.8.0",
            consecutiveCrashLoopRestarts: 2)
        #expect(WatchdogStateStore.write(original, to: url))
        #expect(WatchdogStateStore.read(from: url) == original)
    }
}

// MARK: - Guard record store

@Suite("KV-backend guard store")
struct KVBackendGuardStoreTests {
    private func tempEnv() -> (env: [String: String], url: URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kv-backend-guard-\(UUID().uuidString).json")
        return ([KVBackendGuardStore.pathEnvKey: url.path], url)
    }

    @Test("the record round-trips through disk")
    func roundTrip() {
        let (env, url) = tempEnv()
        defer { try? FileManager.default.removeItem(at: url) }
        let record = KVBackendGuard(
            trippedAt: 1_234.5, providerVersion: "0.8.0", crashCount: 3)
        #expect(KVBackendGuardStore.write(record, environment: env))
        #expect(KVBackendGuardStore.read(environment: env) == record)
    }

    @Test("missing file reads as no guard")
    func missingIsNil() {
        let (env, _) = tempEnv()
        #expect(KVBackendGuardStore.read(environment: env) == nil)
    }

    @Test("a RELATIVE path override is rejected — the default path is used")
    func relativeOverrideRejected() {
        // A relative override resolves against each process's own CWD: the
        // launchd-spawned watchdog (CWD `/`) and the daemon would silently
        // agree on the ENV VALUE while reading and writing different files —
        // the guard written by the watchdog would never reach the daemon.
        let defaultPath = KVBackendGuardStore.path(environment: [:])
        for relative in ["guard.json", "./guard.json", "../guard.json", "~/guard.json"] {
            let resolved = KVBackendGuardStore.path(
                environment: [KVBackendGuardStore.pathEnvKey: relative])
            #expect(
                resolved == defaultPath,
                "relative override \(relative.debugDescription) must fall back to the default path")
        }
        // An absolute override is honored unchanged.
        let absolute = KVBackendGuardStore.path(
            environment: [KVBackendGuardStore.pathEnvKey: "/tmp/guard.json"])
        #expect(absolute.path == "/tmp/guard.json")
    }

    @Test("a corrupt/garbage file fails OPEN to no guard, not a crash")
    func corruptFailsOpen() throws {
        for garbage in ["", "not json at all", "{\"tripped_at\": \"words\"}", "[1,2,3]"] {
            let (env, url) = tempEnv()
            defer { try? FileManager.default.removeItem(at: url) }
            try Data(garbage.utf8).write(to: url)
            #expect(
                KVBackendGuardStore.read(environment: env) == nil,
                "garbage \(garbage.debugDescription) must read as no guard")
            // And the factory-facing predicate agrees: no record, no force.
            #expect(!EngineV2KVBackendPolicy.crashLoopGuardForcesContiguous(
                record: KVBackendGuardStore.read(environment: env),
                runningVersion: ProviderCore.version))
        }
    }

    @Test("semantically hostile timestamps fail OPEN as corrupt, not a trap")
    func hostileTimestampsFailOpen() throws {
        // Every one of these DECODES (syntactically valid JSON), so the old
        // syntax-only check accepted them — and `-1e308` made the
        // diagnostics' `Int(age)` conversion trap `status`/`doctor` exactly
        // when they were needed. Semantic validation rejects them at `read`,
        // so every reader fails open to "no guard" (normal `.auto`).
        let now = 1_700_000_000.0
        let hostile: [(String, String)] = [
            ("-1e308", #"{"tripped_at": -1e308, "provider_version": "0.8.0", "crash_count": 3}"#),
            ("1e308", #"{"tripped_at": 1e308, "provider_version": "0.8.0", "crash_count": 3}"#),
            // NaN cannot be written as a JSON literal; null is its wire shape.
            ("null", #"{"tripped_at": null, "provider_version": "0.8.0", "crash_count": 3}"#),
            ("plausible future",
             #"{"tripped_at": \#(now + 7 * 86_400), "provider_version": "0.8.0", "crash_count": 3}"#),
            ("pre-epoch", #"{"tripped_at": -1, "provider_version": "0.8.0", "crash_count": 3}"#),
            ("negative crash count",
             #"{"tripped_at": 1000, "provider_version": "0.8.0", "crash_count": -3}"#),
        ]
        for (label, json) in hostile {
            let (env, url) = tempEnv()
            defer { try? FileManager.default.removeItem(at: url) }
            try Data(json.utf8).write(to: url)
            #expect(
                KVBackendGuardStore.read(environment: env, now: now) == nil,
                "\(label) must read as corrupt → no guard")
            #expect(!EngineV2KVBackendPolicy.crashLoopGuardForcesContiguous(
                record: KVBackendGuardStore.read(environment: env, now: now),
                runningVersion: "0.8.0"))
        }

        // Skew INSIDE the tolerance is a real record: a trip stamped just
        // before an NTP step backwards must keep guarding.
        let (env, url) = tempEnv()
        defer { try? FileManager.default.removeItem(at: url) }
        let skewed = KVBackendGuard(
            trippedAt: now + KVBackendGuardStore.futureSkewToleranceSeconds - 1,
            providerVersion: "0.8.0", crashCount: 3)
        #expect(KVBackendGuardStore.write(skewed, environment: env))
        #expect(KVBackendGuardStore.read(environment: env, now: now) == skewed)
    }

    @Test("manual clear removes the record; clearing nothing succeeds")
    func manualClear() {
        let (env, url) = tempEnv()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(KVBackendGuardStore.clear(environment: env), "clearing an absent guard is success")
        KVBackendGuardStore.write(
            KVBackendGuard(trippedAt: 1, providerVersion: "0.8.0", crashCount: 3),
            environment: env)
        #expect(KVBackendGuardStore.read(environment: env) != nil)
        #expect(KVBackendGuardStore.clear(environment: env))
        #expect(KVBackendGuardStore.read(environment: env) == nil)
    }

    @Test("clearIfStale deletes only a version-mismatched record")
    func clearIfStale() {
        let (env, url) = tempEnv()
        defer { try? FileManager.default.removeItem(at: url) }
        let record = KVBackendGuard(trippedAt: 1, providerVersion: "0.7.9", crashCount: 3)
        KVBackendGuardStore.write(record, environment: env)

        // Same version: kept.
        #expect(KVBackendGuardStore.clearIfStale(
            runningVersion: "0.7.9", environment: env) == nil)
        #expect(KVBackendGuardStore.read(environment: env) == record)

        // New version: deleted, and the cleared record is reported back.
        #expect(KVBackendGuardStore.clearIfStale(
            runningVersion: "0.8.0", environment: env) == record)
        #expect(KVBackendGuardStore.read(environment: env) == nil)
    }
}

// MARK: - Activation predicate

@Suite("Crash-loop guard trip action")
struct CrashLoopGuardTripTests {
    private final class EventCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [TelemetryEvent] = []
        var events: [TelemetryEvent] { lock.withLock { _events } }
        func record(_ event: TelemetryEvent) { lock.withLock { _events.append(event) } }
    }

    @Test("trip persists the GUARDED version's record and emits ERROR engine_health")
    func tripWritesAndEmits() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kv-backend-guard-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let env = [KVBackendGuardStore.pathEnvKey: url.path]
        let capture = EventCapture()

        let wrote = KVBackendCrashLoopGuard.trip(
            crashCount: 3,
            now: 5_000,
            guardedVersion: "0.8.3",
            lastKnownModel: "gemma-4-26b-qat-4bit",
            environment: env,
            emitTelemetry: { capture.record($0) })
        #expect(wrote)

        let record = KVBackendGuardStore.read(environment: env)
        #expect(record == KVBackendGuard(
            trippedAt: 5_000, providerVersion: "0.8.3", crashCount: 3))
        // The record it wrote is ACTIVE for the guarded (installed daemon)
        // binary — the whole point.
        #expect(EngineV2KVBackendPolicy.crashLoopGuardForcesContiguous(
            record: record, runningVersion: "0.8.3"))

        #expect(capture.events.count == 1)
        let event = capture.events[0]
        #expect(event.severity == .error)
        #expect(event.kind == .engineHealth)
        #expect(event.fields?["operation"]?.description == "engine_v2_crash_loop_guard")
        #expect(event.fields?["reason"]?.description == "crash_loop_guard")
        #expect(event.fields?["model"]?.description == "gemma-4-26b-qat-4bit")
        // Box-wide event: the crashing slot's backend was never observed,
        // so the key is OMITTED, not guessed (EngineHealthEvent contract).
        #expect(event.fields?["kv_backend"] == nil)
        // The injected compatibility event records the guarded binary's
        // version, not the watchdog process version.
        #expect(event.version == "0.8.3")
    }

    @Test("stageTrip writes the record NOW but queues no event until emit() runs")
    func stageTripDefersEvent() {
        // The record must land before the kickstart (the relaunching daemon
        // reads it), but the ERROR event must not be queued until the
        // kickstart is issued — a rolled-back trip cannot retract a queued
        // event, and a false `engine_v2_crash_loop_guard` is exactly the
        // signal operators alert on during the rollout.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kv-backend-guard-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let env = [KVBackendGuardStore.pathEnvKey: url.path]
        let capture = EventCapture()

        let staged = KVBackendCrashLoopGuard.stageTrip(
            crashCount: 3, now: 5_000, guardedVersion: "0.8.3",
            lastKnownModel: nil,
            environment: env, emitTelemetry: { capture.record($0) })
        #expect(staged.persisted)
        #expect(KVBackendGuardStore.read(environment: env) != nil,
            "the record is on disk immediately")
        #expect(capture.events.isEmpty, "no event before emit()")
        #expect(staged.undo != nil)

        staged.emit()
        #expect(capture.events.count == 1)
        #expect(capture.events.first?.fields?["operation"]?.description
            == "engine_v2_crash_loop_guard")
    }

    @Test("re-tripping the same version keeps the original trippedAt, raises crashCount")
    func retripPreservesTrippedAt() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kv-backend-guard-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let env = [KVBackendGuardStore.pathEnvKey: url.path]

        KVBackendCrashLoopGuard.trip(
            crashCount: 3, now: 5_000, guardedVersion: "0.8.3", lastKnownModel: nil,
            environment: env, emitTelemetry: { _ in })
        KVBackendCrashLoopGuard.trip(
            crashCount: 4, now: 6_000, guardedVersion: "0.8.3", lastKnownModel: nil,
            environment: env, emitTelemetry: { _ in })

        let record = KVBackendGuardStore.read(environment: env)
        #expect(record?.trippedAt == 5_000, "age must report the FIRST trip")
        #expect(record?.crashCount == 4)
    }

    @Test("an unattributable trip reports model=unknown rather than guessing")
    func unknownModelAttribution() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kv-backend-guard-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let capture = EventCapture()
        KVBackendCrashLoopGuard.trip(
            crashCount: 3, now: 5_000, guardedVersion: "0.8.3", lastKnownModel: nil,
            environment: [KVBackendGuardStore.pathEnvKey: url.path],
            emitTelemetry: { capture.record($0) })
        #expect(capture.events.first?.fields?["model"]?.description == "unknown")
    }
}

// MARK: - Recovery-flow wiring
