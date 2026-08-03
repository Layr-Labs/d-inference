import Foundation
import ProviderCore
import Testing

@testable import darkbloom

/// `doctor --clear-backend-guard` is the operator's explicit "give paged a
/// fresh trial". Clearing the guard record alone is not enough: the operator
/// typically clears within minutes of the trip, so `watchdog-state.json`
/// still holds a threshold-level crash-loop counter and a recent
/// `lastRestartAt` — without a chain reset, ONE crash during the
/// `darkbloom restart` retry would continue the old chain past the threshold
/// and re-trip the guard immediately, instead of after the
/// `crashLoopTripThreshold` restarts the command's own output promises.
@Suite("doctor --clear-backend-guard")
struct DoctorClearBackendGuardTests {

    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).json")
    }

    @Test("clearing the guard resets the chain: one crash during the retry computes 1, no re-trip")
    func clearResetsChain() throws {
        let guardURL = tempURL("kv-backend-guard")
        let stateURL = tempURL("watchdog-state")
        defer {
            try? FileManager.default.removeItem(at: guardURL)
            try? FileManager.default.removeItem(at: stateURL)
        }
        let env = [KVBackendGuardStore.pathEnvKey: guardURL.path]
        let now = 10_000.0

        // Tripped five minutes ago; the operator diagnoses, clears within
        // the 15-minute uptime bound, and immediately retries.
        KVBackendGuardStore.write(
            KVBackendGuard(trippedAt: now - 300, providerVersion: "0.8.0", crashCount: 3),
            environment: env)
        WatchdogStateStore.write(
            WatchdogState(
                downSince: nil,
                lastRestartAt: now - 60,
                lastRestartVersion: "0.8.0",
                consecutiveCrashLoopRestarts: 3),
            to: stateURL)

        var lines: [String] = []
        try Doctor.runClearBackendGuard(
            environment: env,
            watchdogStateURL: stateURL,
            now: now,
            output: { lines.append($0) })

        #expect(KVBackendGuardStore.read(environment: env) == nil)
        let state = WatchdogStateStore.read(from: stateURL)
        #expect(state.consecutiveCrashLoopRestarts == 0)
        #expect(state.lastRestartVersion == nil)
        // The restart TIMER survives — it describes a real outage, not chain
        // length, and a zero counter alone guarantees the fresh window below.
        #expect(state.lastRestartAt == now - 60)
        // The reset is announced, so the operator knows what happened.
        #expect(lines.contains {
            $0.contains("reset the watchdog's crash-loop restart chain (was 3)")
        })

        // One crash two minutes into the retry: the chain computes 1 — a
        // fresh trial window, NOT old-chain 4 — so the guard does not
        // re-trip until the promised threshold.
        let count = WatchdogPolicy.crashLoopCount(
            current: state, effectiveDownSince: now + 120)
        #expect(count == 1)
        #expect(count < WatchdogPolicy.crashLoopTripThreshold,
            "the retry must get the full \(WatchdogPolicy.crashLoopTripThreshold)-restart window")
    }

    @Test("no guard present: nothing to clear, and the chain is left untouched")
    func noGuardLeavesChainAlone() throws {
        let guardURL = tempURL("kv-backend-guard")
        let stateURL = tempURL("watchdog-state")
        defer { try? FileManager.default.removeItem(at: stateURL) }
        // A live chain with NO guard: the box is mid-loop but below the
        // threshold — the clear verb must not zero a chain the watchdog is
        // still counting.
        WatchdogStateStore.write(
            WatchdogState(
                lastRestartAt: 9_000, lastRestartVersion: "0.8.0",
                consecutiveCrashLoopRestarts: 2),
            to: stateURL)

        var lines: [String] = []
        try Doctor.runClearBackendGuard(
            environment: [KVBackendGuardStore.pathEnvKey: guardURL.path],
            watchdogStateURL: stateURL,
            now: 10_000,
            output: { lines.append($0) })

        #expect(lines == ["No crash-loop KV-backend guard is present; nothing to clear."])
        let state = WatchdogStateStore.read(from: stateURL)
        #expect(state.consecutiveCrashLoopRestarts == 2)
        #expect(state.lastRestartVersion == "0.8.0")
    }

    @Test("a clear with an already-clean chain does not rewrite or announce a reset")
    func cleanChainNoRewrite() throws {
        let guardURL = tempURL("kv-backend-guard")
        let stateURL = tempURL("watchdog-state")
        defer { try? FileManager.default.removeItem(at: guardURL) }
        let env = [KVBackendGuardStore.pathEnvKey: guardURL.path]
        KVBackendGuardStore.write(
            KVBackendGuard(trippedAt: 9_000, providerVersion: "0.8.0", crashCount: 3),
            environment: env)
        // No watchdog-state file at all (fresh box shape).

        var lines: [String] = []
        try Doctor.runClearBackendGuard(
            environment: env,
            watchdogStateURL: stateURL,
            now: 10_000,
            output: { lines.append($0) })

        #expect(KVBackendGuardStore.read(environment: env) == nil)
        #expect(!lines.contains { $0.contains("crash-loop restart chain") },
            "nothing was reset, so nothing should be announced")
        #expect(!FileManager.default.fileExists(atPath: stateURL.path),
            "an already-clean chain must not be rewritten")
    }
}
