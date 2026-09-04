// Copyright © 2026 Eigen Labs.
//
// An auto-update cycle that is already past its claim must not commit the
// staged binary or restart (execv / kickstart -k) a process that is draining
// for shutdown: under `darkbloom stop` the job is booted out, so the restart
// path execv's the draining process into the new binary (same PID, which
// launchd is waiting on); under restart/watchdog it is `kickstart -k`, whose
// SIGTERM is the trap's second signal — exit 130 mid-drain, no goingAway
// frame. `beginShutdownDrain` cancels a cycle that has not started draining,
// and the commit/restart steps refuse once the shutdown has begun.

import Foundation
import Testing

@testable import ProviderCore

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.withLock { _value } }
    func set() { lock.withLock { _value = true } }
}

private func makeLoop() throws -> ProviderLoop {
    let config = ProviderLoopConfig(
        coordinatorURL: "ws://127.0.0.1:0/ignored",
        hardware: HardwareInfo(
            machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
            memoryGb: 128, memoryAvailableGb: 124,
            cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
            gpuCores: 40, memoryBandwidthGbs: 546),
        models: [],
        config: ProviderConfig(
            provider: ProviderSettings(name: "update-shutdown-guard-test", memoryReserveGB: 1),
            backend: BackendSettings(idleTimeoutMins: 0, maxModelSlots: 3),
            coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)))
    return try ProviderLoop(config: config, purgeLegacyFiles: false, attestationSigner: nil)
}

/// A client that is never started: `shutdown()` on it is a no-op on the
/// wire, which is all `beginShutdownDrain` needs here.
private func makeIdleClient(state: ProviderState) -> CoordinatorClient {
    CoordinatorClient(
        config: CoordinatorClientConfig(
            url: "ws://127.0.0.1:0/ignored",
            hardware: HardwareInfo(
                machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
                memoryGb: 128, memoryAvailableGb: 124,
                cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
                gpuCores: 40, memoryBandwidthGbs: 546),
            models: [], backendName: "mlx-swift", heartbeatInterval: 60,
            publicKey: "", privacyCapabilities: PrivacyCapabilities(
                textBackendInprocess: true, textProxyDisabled: true,
                pythonRuntimeLocked: false, dangerousModulesBlocked: false,
                sipEnabled: true, antiDebugEnabled: false,
                coreDumpsDisabled: false, envScrubbed: false)),
        stats: AtomicProviderStats(), state: state)
}

private func tmpStateURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("update-guard-\(UUID().uuidString).json")
}

@Suite("AutoUpdateController shutdown guard (update cycle vs shutdown drain)")
struct AutoUpdateControllerShutdownGuardTests {

    @Test("the commit and restart steps refuse once the shutdown drain has begun")
    func commitAndRestartRefuseDuringShutdown() async throws {
        let loop = try makeLoop()
        let stateURL = tmpStateURL()
        defer { try? FileManager.default.removeItem(at: stateURL) }
        await loop.setDaemonStateFileForTesting(stateURL)
        let state = await loop.state
        await loop.beginShutdownDrain(coordinator: makeIdleClient(state: state))
        #expect(await loop.isShuttingDownForTesting())

        let updater = SelfUpdater(coordinatorBaseURL: "https://coordinator.test")
        let commit = await loop.commitStagedUpdateBundleForTesting(updater: updater)
        guard case .failed(let reason) = commit, reason.contains("shutting down") else {
            Issue.record("commit did not refuse during the shutdown: \(commit)")
            return
        }
        let prepare = await loop.prepareInstalledCandidateRestartForTesting(updater: updater)
        guard case .failed(let prepareReason) = prepare, prepareReason.contains("shutting down") else {
            Issue.record("candidate restart prep did not refuse during the shutdown: \(prepare)")
            return
        }

        let restarted = Flag()
        await #expect(throws: ProviderLoopError.self) {
            try await loop.closeLinkThenRestart { restarted.set() }
        }
        #expect(!restarted.value, "the restart command ran on a draining process")
    }

    /// A cycle whose commit/restart was refused resumes serving — but a
    /// shutting-down provider must keep refusing quotes for the rest of the
    /// drain, or the coordinator routes-then-reroutes against the 503 gate.
    @Test("resumeServing keeps refusing new work while the shutdown drain runs")
    func resumeServingKeepsRefusingDuringShutdown() async throws {
        let loop = try makeLoop()
        let stateURL = tmpStateURL()
        defer { try? FileManager.default.removeItem(at: stateURL) }
        await loop.setDaemonStateFileForTesting(stateURL)
        let state = await loop.state
        await loop.beginShutdownDrain(coordinator: makeIdleClient(state: state))
        #expect(state.refusingNewWork)
        await loop.resumeServingAfterUpdateForTesting()
        #expect(state.refusingNewWork, "resumeServing re-opened quotes during the shutdown drain")

        // The normal update path still re-opens admission.
        let serving = try makeLoop()
        let servingState = await serving.state
        await serving.beginUpdateDrainingForTesting()
        #expect(servingState.refusingNewWork)
        await serving.resumeServingAfterUpdateForTesting()
        #expect(!servingState.refusingNewWork)
    }

    /// Shutdown cancels a cycle that is still checking/staging/jittering
    /// (it aborts at its next cancellation check) but leaves a cycle that is
    /// already draining alone: cancelling that one would short-circuit its
    /// `waitForInflightDrain` and force-cancel the very work the shutdown
    /// drain is protecting.
    @Test("shutdown cancels a not-yet-draining cycle and leaves a draining one to finish")
    func shutdownCancelsOnlyPreDrainCycles() async throws {
        for (phase, expectCancelled) in [
            (ProviderLoop.UpdatePhase.installing, true),
            (ProviderLoop.UpdatePhase.draining, false),
        ] {
            let loop = try makeLoop()
            let stateURL = tmpStateURL()
            defer { try? FileManager.default.removeItem(at: stateURL) }
            await loop.setDaemonStateFileForTesting(stateURL)
            let cycle = Task<Void, Never> { do { try await Task.sleep(for: .seconds(60)) } catch {} }
            defer { cycle.cancel() }
            await loop.installAutoUpdateTaskForTesting(cycle)
            await loop.setUpdatePhaseForTesting(phase)
            let state = await loop.state
            await loop.beginShutdownDrain(coordinator: makeIdleClient(state: state))
            #expect(cycle.isCancelled == expectCancelled, "phase \(phase): cancelled=\(cycle.isCancelled)")
        }
    }
}
