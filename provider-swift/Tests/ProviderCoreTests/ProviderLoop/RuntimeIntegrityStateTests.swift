// Contract under test: ProviderLoop's handling of a coordinator
// `runtime_status{verified:false}` message.
//
// `ProviderLoop` carries a diagnostics property next to `lastTrustStatus`:
//
//     internal var lastRuntimeIntegrity: DaemonState.RuntimeIntegrity?
//
// threaded into `currentDaemonState()` as `DaemonState.runtimeIntegrity`
// the same way `lastTrustStatus` threads into `DaemonState.trust`.
//
// The coordinator-event entry point (called from ProviderLoop+Serve.swift's
// `.runtimeOutdated` case) is:
//
//     internal func handleRuntimeOutdatedEvent(mismatches: [RuntimeMismatch])
//
// which:
//   1. records + persists the mismatch state (a `DaemonState.RuntimeIntegrity`
//      with `status == "outdated"`, `mismatchCount == mismatches.count`, the
//      mismatches themselves, and a fresh `receivedAt`), mirroring
//      `handleTrustStatus`'s cache + persist pattern;
//   2. consults `RuntimeOutdatedUpdateTrigger.shouldCheck` with
//      `autoUpdateEnabled: loopConfig.config.provider.autoUpdate`,
//      `envDisabled: (DARKBLOOM_NO_UPDATE_CHECK set)`, and
//      `lastCheckAt: lastRuntimeUpdateCheckAt`;
//   3. when due, sets `lastRuntimeUpdateCheckAt = now` and starts
//      `performAutoUpdateCheck(coordinatorURL:)` as a tracked task
//      (`runtimeOutdatedUpdateTask: Task<Void, Never>?`, alongside the
//      existing `autoUpdateTask`) so stop/shutdown can cancel it;
//   4. when not due (auto-update disabled, env-disabled, or inside the
//      10-minute spacing), leaves `lastRuntimeUpdateCheckAt` and
//      `runtimeOutdatedUpdateTask` untouched.
//
// The coordinator never re-verifies a mismatch once reported (it keeps
// re-sending `verified:false` on every attestation challenge for as long as
// the mismatch lasts), so `handleRuntimeOutdatedEvent` is the only entry
// point exercised below -- there is no `verified:true` path left to test.
// `clearConnectionAuthorization()` (already clearing `lastTrustStatus`)
// additionally clears `lastRuntimeIntegrity` to nil on reconnect; that is
// the only way a recorded mismatch is cleared before it ages out.
//
// `currentDaemonState()` threads `lastRuntimeIntegrity` into
// `DaemonState.runtimeIntegrity` the same way it threads `lastTrustStatus`
// into `DaemonState.trust`.
//
// `RuntimeIntegrity.receivedAt` and `lastRuntimeUpdateCheckAt` are real
// wall-clock values (epoch seconds via `Date().timeIntervalSince1970`), not
// merely non-nil -- tests below bound them against the call's actual
// wall-clock window rather than only checking presence.

import Foundation
import Testing
@testable import ProviderCore

@Suite("ProviderLoop runtime-integrity state")
struct RuntimeIntegrityStateTests {
    private func makeLoop(autoUpdate: Bool = true) throws -> ProviderLoop {
        let config = ProviderLoopConfig(
            // Deliberately NOT a real coordinator: the positive trigger case
            // starts a real `performAutoUpdateCheck`, which must never reach
            // production infrastructure from a unit test. Port 0 is
            // unconnectable, so any network attempt fails immediately.
            coordinatorURL: "ws://127.0.0.1:0/unused",
            hardware: HardwareInfo(
                machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
                memoryGb: 128, memoryAvailableGb: 124,
                cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
                gpuCores: 40, memoryBandwidthGbs: 546),
            models: [], config: ProviderConfig(
                provider: ProviderSettings(name: "runtime-integrity-test", autoUpdate: autoUpdate),
                backend: BackendSettings(), coordinator: CoordinatorSettings()))
        return try ProviderLoop(config: config, attestationSigner: nil)
    }

    @Test("the .runtimeOutdated event path records mismatch count and a real time, persisted")
    func outdatedEventRecordsState() async throws {
        let loop = try makeLoop(autoUpdate: false) // isolate from the trigger half below
        let stateURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stateURL) }
        await loop.installRuntimeIntegrityStateFileForTesting(stateURL)

        let mismatches = [RuntimeMismatch(component: "binary_hash", expected: "aaa", got: "bbb")]
        let before = Date().timeIntervalSince1970
        await loop.handleRuntimeOutdatedEvent(mismatches: mismatches)
        let after = Date().timeIntervalSince1970

        let persisted = DaemonStateFile.read(from: stateURL)?.runtimeIntegrity
        #expect(persisted?.status == "outdated")
        #expect(persisted?.mismatchCount == 1)
        #expect(persisted?.mismatches == mismatches)
        // Real value check (not just non-nil): receivedAt must fall inside
        // this call's actual wall-clock window.
        let receivedAt = try #require(persisted?.receivedAt)
        #expect(receivedAt >= before - 0.001)
        #expect(receivedAt <= after + 0.001)
    }

    @Test("the .runtimeOutdated event path starts a tracked update check when auto-update is on")
    func outdatedEventTriggersTrackedUpdateCheckWhenAutoUpdateEnabled() async throws {
        let loop = try makeLoop(autoUpdate: true)
        let stateURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stateURL) }
        await loop.installRuntimeIntegrityStateFileForTesting(stateURL)

        #expect(await loop.lastRuntimeUpdateCheckAt == nil)
        #expect(await loop.runtimeOutdatedUpdateTask == nil)

        let before = Date().timeIntervalSince1970
        await loop.handleRuntimeOutdatedEvent(mismatches: [
            RuntimeMismatch(component: "binary_hash", expected: "aaa", got: "bbb"),
        ])
        let after = Date().timeIntervalSince1970

        let lastCheckAt = try #require(await loop.lastRuntimeUpdateCheckAt)
        #expect(lastCheckAt >= before - 0.001)
        #expect(lastCheckAt <= after + 0.001)
        #expect(await loop.runtimeOutdatedUpdateTask != nil)

        // Don't leak the background check into later tests/process exit.
        await loop.runtimeOutdatedUpdateTask?.cancel()
    }

    @Test("the .runtimeOutdated event path records no check time and starts no task when auto-update is off")
    func outdatedEventDoesNotTriggerWhenAutoUpdateDisabled() async throws {
        let loop = try makeLoop(autoUpdate: false)
        let stateURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stateURL) }
        await loop.installRuntimeIntegrityStateFileForTesting(stateURL)

        await loop.handleRuntimeOutdatedEvent(mismatches: [
            RuntimeMismatch(component: "binary_hash", expected: "aaa", got: "bbb"),
        ])

        #expect(await loop.lastRuntimeUpdateCheckAt == nil)
        #expect(await loop.runtimeOutdatedUpdateTask == nil)
        // The mismatch is still recorded regardless of the trigger decision.
        #expect(DaemonStateFile.read(from: stateURL)?.runtimeIntegrity?.status == "outdated")
    }

    @Test("clearing connection authorization also clears runtime-integrity state")
    func clearConnectionAuthorizationClearsRuntimeIntegrity() async throws {
        let loop = try makeLoop(autoUpdate: false) // isolate from the trigger half above
        let stateURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stateURL) }
        await loop.installRuntimeIntegrityStateFileForTesting(stateURL)

        await loop.handleRuntimeOutdatedEvent(mismatches: [
            RuntimeMismatch(component: "binary_hash", expected: "aaa", got: "bbb"),
        ])
        #expect(DaemonStateFile.read(from: stateURL)?.runtimeIntegrity != nil)

        await loop.clearConnectionAuthorization()
        #expect(DaemonStateFile.read(from: stateURL)?.runtimeIntegrity == nil)
    }
}

private extension ProviderLoop {
    func installRuntimeIntegrityStateFileForTesting(_ url: URL) {
        daemonStateFileOverride = url
    }
}
