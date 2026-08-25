import Foundation
import ProviderCoreFoundation
import Testing
@testable import ProviderCore

@Suite("SelfUpdater two-phase concurrency", .serialized)
struct SelfUpdaterConcurrencyTests {
    @Test("stalled release transfer does not hold installation mutation locks")
    func stalledDownloadDoesNotBlockInstallerMutation() async throws {
        let fixture = try UpdateRecoveryFixture()
        defer { fixture.cleanup() }
        let gate = MockReleaseArtifactGate()
        let mock = MockCoordinator(
            release: fixture.mockReleaseFixture(),
            releaseArtifact: fixture.artifact,
            releaseArtifactGate: gate
        )
        let baseURL = try await mock.start()
        defer {
            Task {
                await gate.release()
                await mock.shutdown()
            }
        }
        let updater = fixture.updater(baseURL: baseURL)

        let update = Task {
            await updater.update()
        }
        await gate.waitUntilRequested()

        let mutation = fixture.installRoot.appendingPathComponent(
            "concurrent-installer-mutation"
        )
        try InstallMutationLock.withOneShotInstallLock(
            in: fixture.installRoot,
            timeout: 0
        ) {
            try Data("completed".utf8).write(to: mutation)
        }
        #expect(
            try String(contentsOf: mutation, encoding: .utf8) == "completed"
        )

        update.cancel()
        await gate.release()
        guard case .cancelled = await update.value else {
            Issue.record("cancelled stalled update did not preserve cancellation")
            return
        }
        #expect(try fixture.liveBinaryContents() == "1.0.0-darkbloom")
    }

    @Test("completed competing update wins over stale downloaded release")
    func stalePreparedReleaseCannotOverwriteCompetitor() async throws {
        let stale = try UpdateRecoveryFixture(
            oldVersion: "1.0.0",
            newVersion: "2.0.0"
        )
        defer { stale.cleanup() }
        let winner = try UpdateRecoveryFixture(
            oldVersion: "1.0.0",
            newVersion: "3.0.0"
        )
        defer { winner.cleanup() }

        let staleGate = MockReleaseArtifactGate()
        let staleMock = MockCoordinator(
            release: stale.mockReleaseFixture(),
            releaseArtifact: stale.artifact,
            releaseArtifactGate: staleGate
        )
        let staleBaseURL = try await staleMock.start()
        defer {
            Task {
                await staleGate.release()
                await staleMock.shutdown()
            }
        }
        let staleUpdater = stale.updater(baseURL: staleBaseURL)
        let staleTask = Task {
            await staleUpdater.update()
        }
        await staleGate.waitUntilRequested()

        let winnerMock = MockCoordinator(
            release: winner.mockReleaseFixture(),
            releaseArtifact: winner.artifact
        )
        let winnerBaseURL = try await winnerMock.start()
        defer { Task { await winnerMock.shutdown() } }
        let winnerUpdater = SelfUpdater(
            coordinatorBaseURL: winnerBaseURL.absoluteString,
            installRoot: stale.installRoot,
            verifyCodeSignatures: false,
            currentVersion: stale.oldVersion,
            now: { 200 }
        )

        guard case .updated(let from, let to) = await winnerUpdater.update()
        else {
            Issue.record("competing v3 update did not complete")
            staleTask.cancel()
            await staleGate.release()
            _ = await staleTask.value
            return
        }
        #expect(from == "1.0.0")
        #expect(to == "3.0.0")
        #expect(try stale.liveBinaryContents() == "3.0.0-darkbloom")

        await staleGate.release()
        let staleResult = await staleTask.value
        guard case .restartRequired(let from, let installed) = staleResult
        else {
            Issue.record(
                "stale v2 preparation was not discarded after v3 commit: "
                    + "\(staleResult)"
            )
            return
        }
        #expect(from == "1.0.0")
        #expect(installed == "3.0.0")
        #expect(try stale.liveBinaryContents() == "3.0.0-darkbloom")

        let state = try UpdateRecoveryStore(
            installRoot: stale.installRoot,
            verifyCodeSignatures: false
        ).loadState()
        #expect(state.installGeneration == 1)
        #expect(state.candidate?.release.version == "3.0.0")
        #expect(state.predecessor?.release.version == "1.0.0")
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: stale.installRoot.path
        ).filter { $0.hasPrefix(".update-staging-") }
        #expect(leftovers.isEmpty)
    }
}
