/// Rolling a single Mac back to its retained predecessor after the installed
/// release was promoted, through the watchdog's journaled rollback.
///
/// Every install root is a temporary `UpdateRecoveryFixture`; releases come
/// from the loopback `MockCoordinator`; restarts and the launchd baseline are
/// injected. No real binary, launchd job or provider process is touched.

import Foundation
import Testing
@testable import ProviderCore

/// v2 installed over v1 by the updater, with v1 retained as the verified
/// predecessor. `promote` passes v2's stabilization through the watchdog's
/// health observation, as on a Mac where a release served for 10 minutes.
struct InstalledUpdate {
    let fixture: UpdateRecoveryFixture
    let mock: MockCoordinator
    let baseURL: URL

    var store: UpdateRecoveryStore {
        UpdateRecoveryStore(installRoot: fixture.installRoot, verifyCodeSignatures: false)
    }

    /// The updater of the rolled-back v1 install (the restarted provider and watchdog).
    var updater: SelfUpdater { fixture.updater(baseURL: baseURL) }

    static func make(promote: Bool) async throws -> InstalledUpdate {
        let fixture = try UpdateRecoveryFixture()
        let mock = MockCoordinator(release: fixture.mockReleaseFixture(), releaseArtifact: fixture.artifact)
        let installed = InstalledUpdate(fixture: fixture, mock: mock, baseURL: try await mock.start())
        let outcome = await installed.updater.update()
        guard case .updated(_, "2.0.0") = outcome else {
            await installed.shutdown()
            throw InstalledUpdateSetupError.installFailed("\(outcome)")
        }
        if promote {
            let health = watchdogRecovery(installed.updater, stabilizationSeconds: 0).observeHealthyProvider(
                providerRunning: true,
                daemonState: DaemonState(pid: 4242, version: "2.0.0", writtenAt: 150, startedAt: 120),
                now: 150)
            guard health == .promoted(version: "2.0.0") else {
                await installed.shutdown()
                throw InstalledUpdateSetupError.promotionFailed("\(health)")
            }
        }
        return installed
    }

    func shutdown() async {
        await mock.shutdown()
        fixture.cleanup()
    }

    /// The live `Darkbloom.app` is one complete release and `bin/` resolves into it.
    func liveRelease() throws -> String? {
        let app = fixture.installRoot.appendingPathComponent("Darkbloom.app/Contents/MacOS")
        let bin = fixture.installRoot.appendingPathComponent("bin")
        func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
        let binary = try read(app.appendingPathComponent("darkbloom"))
        guard let version = binary.split(separator: "-").first.map(String.init),
              try read(app.appendingPathComponent("darkbloom-enclave")) == "\(version)-enclave",
              try read(app.appendingPathComponent("mlx.metallib")) == "\(version)-metallib",
              try read(bin.appendingPathComponent("darkbloom")) == binary,
              try read(bin.appendingPathComponent("mlx.metallib")) == "\(version)-metallib"
        else { return nil }
        return version
    }

    func leftoverRollbackFiles() throws -> [String] {
        let root = try FileManager.default.contentsOfDirectory(atPath: fixture.installRoot.path)
            .filter { $0.hasPrefix(".rollback-staging-") || $0.hasPrefix(".recovery-restore-") }
        let journal = FileManager.default.fileExists(
            atPath: store.recoveryRoot.appendingPathComponent("transaction.json").path)
        return root + (journal ? ["transaction.json"] : [])
    }
}

enum InstalledUpdateSetupError: Error {
    case installFailed(String)
    case promotionFailed(String)
}

func watchdogRecovery(
    _ updater: SelfUpdater,
    restarts: RecoveryRestartCounter = RecoveryRestartCounter(),
    stabilizationSeconds: Double = 180
) -> WatchdogRecoveryService {
    WatchdogRecoveryService(
        updater: updater,
        dependencies: .init(
            kickstartIfLoaded: {
                restarts.increment()
                return true
            },
            launchSnapshot: { nil },
            processAlive: { _ in true },
            log: { _ in }
        ),
        stabilizationSeconds: stabilizationSeconds,
        candidateStartupTimeoutSeconds: 300
    )
}

/// A loop with no coordinator connection, as in `AutoUpdateCycleTests`.
func rollbackAutoUpdateLoop() throws -> ProviderLoop {
    let config = ProviderLoopConfig(
        coordinatorURL: "ws://127.0.0.1:0/ignored",
        hardware: HardwareInfo(
            machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
            memoryGb: 128, memoryAvailableGb: 124,
            cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
            gpuCores: 40, memoryBandwidthGbs: 546),
        models: [ModelInfo(id: "org/model-a", modelType: "gpt_oss", sizeBytes: 1, estimatedMemoryGb: 1)],
        config: ProviderConfig(
            provider: ProviderSettings(
                name: "update-rollback-test", memoryReserveGB: 1, autoUpdate: true, updateJitterSeconds: 0),
            backend: BackendSettings(
                model: nil, enabledModels: ["org/model-a"], idleTimeoutMins: 0, preloadModels: []),
            coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)))
    return try ProviderLoop(config: config, attestationSigner: nil)
}

@Suite("Update rollback recovery", .serialized)
struct UpdateRollbackRecoveryTests {
    @Test("rolling back a promoted release restores the predecessor, records the generation and quarantines it")
    func promotedReleaseRollsBack() async throws {
        let installed = try await InstalledUpdate.make(promote: true)
        defer { Task { await installed.shutdown() } }
        let before = try installed.store.loadState()
        #expect(before.candidate == nil)
        #expect(before.current?.version == "2.0.0")
        let predecessor = try #require(before.predecessor)

        let session = try installed.updater.beginUpdateSession(operation: "test-rollback")
        defer { session.release() }
        try session.recover(now: 500)
        let restored = try session.rollback(now: 500, reason: "operator rollback")

        #expect(restored == "1.0.0")
        #expect(try installed.liveRelease() == "1.0.0")
        #expect(try installed.fixture.persistentStateIsIntact())
        #expect(try installed.leftoverRollbackFiles().isEmpty)
        let after = try installed.store.loadState()
        #expect(after.installGeneration == before.installGeneration + 1)
        #expect(after.current == predecessor.release)
        #expect(after.candidate == nil)
        #expect(after.predecessor == predecessor)
        #expect(after.quarantine == FailedReleaseQuarantine(
            version: "2.0.0", failureCount: 0, quarantinedAt: 500, reason: "operator rollback"))
    }

    @Test("every boundary of a promoted-release rollback leaves a runnable bundle that recovery finishes")
    func everyBoundaryLeavesARunnableBundle() async throws {
        enum ProcessDeath: Error { case injected }
        let boundaries: [UpdateRecoveryStore.FaultPoint] = [
            .transactionPersisted, .liveLayoutExchanged, .liveLayoutReplaced, .statePersisted, .transactionRemoved,
        ]
        for boundary in boundaries {
            let installed = try await InstalledUpdate.make(promote: true)
            let generation = try installed.store.loadState().installGeneration
            let dying = UpdateRecoveryStore(
                installRoot: installed.fixture.installRoot,
                verifyCodeSignatures: false,
                faultInjector: { if $0 == boundary { throw ProcessDeath.injected } })
            let lock = try UpdateProcessLock.acquire(at: dying.lockPath, operation: "dies-at-\(boundary)")
            #expect(throws: ProcessDeath.self, "\(boundary)") {
                try dying.rollback(now: 500, reason: "operator rollback")
            }
            lock.release()
            // Whatever the boundary, the live layout is one complete release.
            let interrupted = try installed.liveRelease()
            #expect(interrupted == "1.0.0" || interrupted == "2.0.0", "\(boundary): \(String(describing: interrupted))")

            // The next lease holder (watchdog tick, provider start) finishes it.
            let session = try installed.updater.beginUpdateSession(operation: "next-tick")
            try session.recover(now: 501)
            session.release()
            #expect(try installed.liveRelease() == "1.0.0", "\(boundary)")
            // After `.transactionRemoved` only the swapped-out staging copy is
            // left; the next staging pass removes it (`removeStaleUpdateDirs`).
            let leftovers = try installed.leftoverRollbackFiles()
            #expect(boundary == .transactionRemoved
                ? leftovers.allSatisfy { $0.hasPrefix(".rollback-staging-") }
                : leftovers.isEmpty, "\(boundary): \(leftovers)")
            let state = try installed.store.loadState()
            #expect(state.current?.version == "1.0.0", "\(boundary)")
            #expect(state.quarantine?.version == "2.0.0", "\(boundary)")
            #expect(state.installGeneration == generation + 1, "\(boundary)")
            await installed.shutdown()
        }
    }

    @Test("after a rollback neither auto-update path reinstalls the release, and a newer one installs")
    func quarantineHoldsForBothAutoUpdatePaths() async throws {
        let installed = try await InstalledUpdate.make(promote: true)
        defer { Task { await installed.shutdown() } }
        let session = try installed.updater.beginUpdateSession(operation: "test-rollback")
        try session.recover(now: 500)
        _ = try session.rollback(now: 500, reason: "operator rollback")
        session.release()

        // The restarted v1 provider's next in-process check (every 30 minutes).
        let loop = try rollbackAutoUpdateLoop()
        let restarts = RecoveryRestartCounter()
        let cycle = await loop.performAutoUpdateCheck(
            coordinatorURL: installed.baseURL.absoluteString, updater: installed.updater,
            launchSnapshot: { nil }, restart: { _ = restarts.increment() })
        #expect(cycle == .quarantined("2.0.0"))

        // The watchdog's down-path update, from the v1 watchdog and from a
        // v2 watchdog process that outlived the rollback.
        let staleWatchdog = SelfUpdater(
            coordinatorBaseURL: installed.baseURL.absoluteString, installRoot: installed.fixture.installRoot,
            verifyCodeSignatures: false, currentVersion: "2.0.0")
        for updater in [installed.updater, staleWatchdog] {
            let outcome = await watchdogRecovery(updater, restarts: restarts)
                .recoverDownProvider(autoUpdateEnabled: true, now: 600)
            #expect(outcome == .restartIssued(updatedTo: nil, rolledBackTo: nil))
        }
        #expect(restarts.value == 2)
        #expect(try installed.liveRelease() == "1.0.0")
        #expect(try installed.store.loadState().candidate == nil)

        // The next release installs normally, through either path.
        let newer = try UpdateRecoveryFixture(oldVersion: "1.0.0", newVersion: "3.0.0")
        defer { newer.cleanup() }
        let newerMock = MockCoordinator(release: newer.mockReleaseFixture(), releaseArtifact: newer.artifact)
        let newerURL = try await newerMock.start()
        defer { Task { await newerMock.shutdown() } }
        let newerUpdater = SelfUpdater(
            coordinatorBaseURL: newerURL.absoluteString, installRoot: installed.fixture.installRoot,
            verifyCodeSignatures: false, currentVersion: "1.0.0", now: { 700 })
        let next = await loop.performAutoUpdateCheck(
            coordinatorURL: newerURL.absoluteString, updater: newerUpdater,
            launchSnapshot: { nil }, restart: { _ = restarts.increment() })
        #expect(next == .restarted(from: "1.0.0", to: "3.0.0", drained: true))
        #expect(try installed.liveRelease() == "3.0.0")
        let state = try installed.store.loadState()
        #expect(state.candidate?.release.version == "3.0.0")
        #expect(state.predecessor?.release.version == "1.0.0")
        #expect(state.quarantine?.version == "2.0.0")
    }
}
