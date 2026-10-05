/// One background auto-update cycle on a real `ProviderLoop`.
///
/// The updater targets a temp install root (`UpdateRecoveryFixture`), the
/// release comes from the loopback `MockCoordinator`, and the restart and the
/// launchd baseline are injected. No real binary is replaced and launchd is
/// never called.

import Foundation
import Testing
@testable import ProviderCore

// MARK: - Fixtures

private func autoUpdateHardware() -> HardwareInfo {
    HardwareInfo(
        machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
        memoryGb: 128, memoryAvailableGb: 124,
        cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
        gpuCores: 40, memoryBandwidthGbs: 546
    )
}

/// A loop with no coordinator connection and no model on disk. Jitter is 0 so
/// the cycle goes from stage to drain at once.
private func makeAutoUpdateLoop(autoUpdate: Bool = true) throws -> ProviderLoop {
    let config = ProviderLoopConfig(
        coordinatorURL: "ws://127.0.0.1:0/ignored",
        hardware: autoUpdateHardware(),
        models: [ModelInfo(id: "org/model-a", modelType: "gpt_oss", sizeBytes: 1, estimatedMemoryGb: 1)],
        config: ProviderConfig(
            provider: ProviderSettings(
                name: "auto-update-cycle-test",
                memoryReserveGB: 1,
                autoUpdate: autoUpdate,
                updateJitterSeconds: 0
            ),
            backend: BackendSettings(
                model: nil, enabledModels: ["org/model-a"], idleTimeoutMins: 0, preloadModels: []),
            coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)
        )
    )
    return try ProviderLoop(config: config, attestationSigner: nil)
}

private func recoveryStore(_ fixture: UpdateRecoveryFixture) -> UpdateRecoveryStore {
    UpdateRecoveryStore(installRoot: fixture.installRoot, verifyCodeSignatures: false)
}

private func stagingDirectories(_ fixture: UpdateRecoveryFixture) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: fixture.installRoot.path)
        .filter { $0.hasPrefix(".update-staging-") }
}

private let injectedBaseline = ProviderLaunchSnapshot(
    label: LaunchAgent.label, runs: 7, process: nil)

private struct InjectedRestartFailure: Error, CustomStringConvertible {
    var description: String { "injected restart failure" }
}

/// Start a mock that serves `release` (and the fixture tarball as the
/// artifact), then return it with its base URL.
private func startMock(
    _ fixture: UpdateRecoveryFixture,
    release: MockReleaseFixture? = nil
) async throws -> (MockCoordinator, URL) {
    let mock = MockCoordinator(
        release: release ?? fixture.mockReleaseFixture(),
        releaseArtifact: fixture.artifact
    )
    let baseURL = try await mock.start()
    return (mock, baseURL)
}

/// Run one cycle against the fixture install and the mock at `baseURL`, with
/// the injected launchd baseline. Each test supplies its own restart.
private func runAutoUpdateCycle(
    _ loop: ProviderLoop,
    fixture: UpdateRecoveryFixture,
    baseURL: URL,
    restart: @escaping @Sendable () throws -> Void
) async -> AutoUpdateController.Outcome {
    await loop.performAutoUpdateCheck(
        coordinatorURL: baseURL.absoluteString,
        updater: fixture.updater(baseURL: baseURL),
        launchSnapshot: { injectedBaseline },
        restart: restart
    )
}

// MARK: - Tests

@Suite("Auto-update cycle", .serialized)
struct AutoUpdateCycleTests {

    @Test("same version: the cycle reports up to date, frees the lease and keeps serving")
    func upToDateReleasesLease() async throws {
        let fixture = try UpdateRecoveryFixture()
        defer { fixture.cleanup() }
        var release = fixture.mockReleaseFixture()
        release.version = fixture.oldVersion
        let (mock, baseURL) = try await startMock(fixture, release: release)
        defer { Task { await mock.shutdown() } }

        let loop = try makeAutoUpdateLoop()
        let restarts = RecoveryRestartCounter()
        let outcome = await runAutoUpdateCycle(
            loop, fixture: fixture, baseURL: baseURL, restart: { _ = restarts.increment() })

        #expect(outcome == .upToDate)
        #expect(restarts.value == 0)
        #expect(await loop.updatePhase == .idle)
        #expect(await loop.updateSession == nil)
        #expect(!(await loop.state.refusingNewWork))
        #expect(try fixture.liveBinaryContents() == "1.0.0-darkbloom")
        // The lease is free again: a new session can take it at once.
        let session = try fixture.updater(baseURL: baseURL)
            .beginUpdateSession(operation: "lease-check", timeout: 0)
        session.release()
    }

    @Test("a release for another platform fails the check and the loop resumes serving")
    func wrongPlatformFailsCheck() async throws {
        let fixture = try UpdateRecoveryFixture()
        defer { fixture.cleanup() }
        var release = fixture.mockReleaseFixture()
        release.platform = "linux-x86_64"
        let (mock, baseURL) = try await startMock(fixture, release: release)
        defer { Task { await mock.shutdown() } }

        let loop = try makeAutoUpdateLoop()
        let outcome = await runAutoUpdateCycle(
            loop, fixture: fixture, baseURL: baseURL, restart: {})

        guard case .checkFailed(let reason) = outcome else {
            Issue.record("expected checkFailed, got \(outcome)")
            return
        }
        #expect(reason.contains("unsupported release platform linux-x86_64"))
        #expect(await loop.updatePhase == .idle)
        #expect(await loop.updateSession == nil)
        #expect(try fixture.liveBinaryContents() == "1.0.0-darkbloom")
    }

    @Test("a quarantined release is not downloaded")
    func quarantinedReleaseIsSkipped() async throws {
        let fixture = try UpdateRecoveryFixture()
        defer { fixture.cleanup() }
        let store = recoveryStore(fixture)
        try FileManager.default.createDirectory(
            at: store.recoveryRoot, withIntermediateDirectories: true)
        try store.writeState(UpdateRecoveryState(
            quarantine: FailedReleaseQuarantine(
                version: fixture.newVersion,
                failureCount: 3,
                quarantinedAt: 50,
                reason: "failed three starts"
            )
        ))
        let (mock, baseURL) = try await startMock(fixture)
        defer { Task { await mock.shutdown() } }

        let loop = try makeAutoUpdateLoop()
        let outcome = await runAutoUpdateCycle(
            loop, fixture: fixture, baseURL: baseURL, restart: {})

        #expect(outcome == .quarantined(fixture.newVersion))
        #expect(await loop.updatePhase == .idle)
        #expect(try stagingDirectories(fixture).isEmpty)
        #expect(try fixture.liveBinaryContents() == "1.0.0-darkbloom")
    }

    @Test("a bundle hash mismatch fails the stage before any drain")
    func hashMismatchFailsStage() async throws {
        let fixture = try UpdateRecoveryFixture()
        defer { fixture.cleanup() }
        var release = fixture.mockReleaseFixture()
        release.bundleHash = String(repeating: "0", count: 64)
        let (mock, baseURL) = try await startMock(fixture, release: release)
        defer { Task { await mock.shutdown() } }

        let loop = try makeAutoUpdateLoop()
        let outcome = await runAutoUpdateCycle(
            loop, fixture: fixture, baseURL: baseURL, restart: {})

        guard case .stageFailed(let reason) = outcome else {
            Issue.record("expected stageFailed, got \(outcome)")
            return
        }
        #expect(reason.contains("hashMismatch"))
        #expect(reason.contains(String(repeating: "0", count: 64)))
        #expect(await loop.updatePhase == .idle)
        #expect(await loop.stagedUpdateBundle == nil)
        #expect(!(await loop.state.refusingNewWork))
        #expect(try stagingDirectories(fixture).isEmpty)
        #expect(try fixture.liveBinaryContents() == "1.0.0-darkbloom")
    }

    @Test("a newer release is staged, drained, committed and restarted once")
    func newerReleaseInstallsAndRestarts() async throws {
        let fixture = try UpdateRecoveryFixture()
        defer { fixture.cleanup() }
        let (mock, baseURL) = try await startMock(fixture)
        defer { Task { await mock.shutdown() } }

        let loop = try makeAutoUpdateLoop()
        let restarts = RecoveryRestartCounter()
        let outcome = await runAutoUpdateCycle(
            loop, fixture: fixture, baseURL: baseURL, restart: { _ = restarts.increment() })

        #expect(outcome == .restarted(from: "1.0.0", to: "2.0.0", drained: true))
        #expect(restarts.value == 1)
        #expect(try fixture.liveBinaryContents() == "2.0.0-darkbloom")
        #expect(try fixture.persistentStateIsIntact())
        // The restart leaves the loop drained: nothing resumes in-process.
        #expect(await loop.updatePhase == .draining)
        #expect(await loop.state.refusingNewWork)
        #expect(await loop.stagedUpdateBundle == nil)
        #expect(await loop.updateSession == nil)

        let state = try recoveryStore(fixture).loadState()
        #expect(state.candidate?.release.version == "2.0.0")
        #expect(state.candidate?.launchIntent?.baseline == injectedBaseline)
        #expect(state.predecessor?.release.version == "1.0.0")
        #expect(try stagingDirectories(fixture).isEmpty)
    }

    @Test("a failed restart resumes serving, and the next cycle restarts the installed candidate")
    func failedRestartThenRestartRequired() async throws {
        let fixture = try UpdateRecoveryFixture()
        defer { fixture.cleanup() }
        let (mock, baseURL) = try await startMock(fixture)
        defer { Task { await mock.shutdown() } }

        let loop = try makeAutoUpdateLoop()
        let first = await runAutoUpdateCycle(
            loop, fixture: fixture, baseURL: baseURL, restart: { throw InjectedRestartFailure() })

        guard case .restartFailed(let reason) = first else {
            Issue.record("expected restartFailed, got \(first)")
            return
        }
        #expect(reason.contains("injected restart failure"))
        #expect(await loop.updatePhase == .idle)
        #expect(!(await loop.state.refusingNewWork))
        #expect(try fixture.liveBinaryContents() == "2.0.0-darkbloom")
        let afterFailure = try recoveryStore(fixture).loadState()
        #expect(afterFailure.candidate?.release.version == "2.0.0")
        #expect(afterFailure.candidate?.pendingAttemptID == nil)

        // The binary on disk is already v2 while this process is v1: the
        // next tick drains and restarts without a new download.
        let restarts = RecoveryRestartCounter()
        let second = await runAutoUpdateCycle(
            loop, fixture: fixture, baseURL: baseURL, restart: { _ = restarts.increment() })

        #expect(second == .restarted(from: "1.0.0", to: "2.0.0", drained: true))
        #expect(restarts.value == 1)
        #expect(await loop.updatePhase == .draining)
        #expect(await loop.updateSession == nil)
    }

    @Test("a cycle that cannot take the cross-process lease does nothing")
    func busyLeaseSkipsCycle() async throws {
        let fixture = try UpdateRecoveryFixture()
        defer { fixture.cleanup() }
        let (mock, baseURL) = try await startMock(fixture)
        defer { Task { await mock.shutdown() } }

        let holder = try fixture.updater(baseURL: baseURL)
            .beginUpdateSession(operation: "other-process", timeout: 0)
        defer { holder.release() }

        let loop = try makeAutoUpdateLoop()
        let restarts = RecoveryRestartCounter()
        let outcome = await runAutoUpdateCycle(
            loop, fixture: fixture, baseURL: baseURL, restart: { _ = restarts.increment() })

        #expect(outcome == .alreadyRunning)
        #expect(restarts.value == 0)
        #expect(await loop.updatePhase == .idle)
        #expect(await loop.updateSession == nil)
        #expect(try fixture.liveBinaryContents() == "1.0.0-darkbloom")
    }
}

@Suite("Auto-update phase claims")
struct AutoUpdateClaimTests {

    @Test("claim enters installing once; a second claim is refused until resume")
    func claimIsExclusive() async throws {
        let fixture = try UpdateRecoveryFixture()
        defer { fixture.cleanup() }
        let updater = fixture.updater(baseURL: URL(string: "http://127.0.0.1:9")!)
        let loop = try makeAutoUpdateLoop()

        #expect(await loop.claimUpdateStart(updater: updater))
        #expect(await loop.updatePhase == .installing)
        #expect(await loop.updateSession != nil)
        #expect(!(await loop.claimUpdateStart(updater: updater)))

        await loop.resumeServingAfterUpdate()
        #expect(await loop.updatePhase == .idle)
        #expect(await loop.updateSession == nil)
        #expect(await loop.claimUpdateStart(updater: updater))
        await loop.resumeServingAfterUpdate()
    }

    @Test("a loop that is shutting down never claims an update")
    func shuttingDownRefusesClaim() async throws {
        let fixture = try UpdateRecoveryFixture()
        defer { fixture.cleanup() }
        let updater = fixture.updater(baseURL: URL(string: "http://127.0.0.1:9")!)
        let loop = try makeAutoUpdateLoop()
        await loop.beginShutdownForTesting()

        #expect(!(await loop.claimUpdateStart(updater: updater)))
        #expect(await loop.updatePhase == .idle)
        #expect(await loop.updateSession == nil)
    }

    @Test("a draining loop never claims an update")
    func drainingRefusesClaim() async throws {
        let fixture = try UpdateRecoveryFixture()
        defer { fixture.cleanup() }
        let updater = fixture.updater(baseURL: URL(string: "http://127.0.0.1:9")!)
        let loop = try makeAutoUpdateLoop()
        await loop.beginUpdateDraining()

        #expect(!(await loop.claimUpdateStart(updater: updater)))
        #expect(await loop.updatePhase == .draining)
    }

    @Test("candidate restart without a lease fails and reads no launch baseline")
    func candidateRestartNeedsLease() async throws {
        let fixture = try UpdateRecoveryFixture()
        defer { fixture.cleanup() }
        let updater = fixture.updater(baseURL: URL(string: "http://127.0.0.1:9")!)
        let loop = try makeAutoUpdateLoop()
        let reads = RecoveryRestartCounter()

        let outcome = await loop.prepareInstalledCandidateRestart(
            updater: updater,
            baseline: {
                _ = reads.increment()
                return injectedBaseline
            }
        )

        #expect(outcome == .failed("cross-process update lease was lost before candidate restart"))
        #expect(reads.value == 0)
    }

    @Test("candidate restart with a lease and no candidate releases the lease")
    func candidateRestartWithoutCandidateReleasesLease() async throws {
        let fixture = try UpdateRecoveryFixture()
        defer { fixture.cleanup() }
        let updater = fixture.updater(baseURL: URL(string: "http://127.0.0.1:9")!)
        let loop = try makeAutoUpdateLoop()
        #expect(await loop.claimUpdateStart(updater: updater))

        let outcome = await loop.prepareInstalledCandidateRestart(
            updater: updater,
            baseline: { injectedBaseline }
        )

        #expect(outcome == .completed)
        #expect(await loop.updateSession == nil)
        #expect(try recoveryStore(fixture).loadState().candidate == nil)
        let session = try updater.beginUpdateSession(operation: "lease-check", timeout: 0)
        session.release()
    }
}

@Suite("Auto-update monitor start")
struct AutoUpdateMonitorStartTests {

    @Test("auto_update = false starts no monitor task")
    func disabledByConfig() async throws {
        let loop = try makeAutoUpdateLoop(autoUpdate: false)
        await loop.startAutoUpdateMonitor()
        #expect(await loop.autoUpdateTask == nil)
    }

    @Test("auto_update = true starts one monitor task unless the environment opts out")
    func enabledStartsTask() async throws {
        let loop = try makeAutoUpdateLoop(autoUpdate: true)
        await loop.startAutoUpdateMonitor()
        let task = await loop.autoUpdateTask
        // The first check waits five minutes, so cancel before it runs.
        task?.cancel()
        if ProcessInfo.processInfo.environment["DARKBLOOM_NO_UPDATE_CHECK"] == nil {
            #expect(task != nil)
        } else {
            #expect(task == nil)
        }
    }
}
