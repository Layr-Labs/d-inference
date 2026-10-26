import Foundation
import Testing
@testable import ProviderCore

/// Selected models an Autopilot operation unloaded come back through the
/// recovery, and the recovery displaces a model outside the selection only
/// where Autopilot's own victim rules would: resident for
/// `min_dwell_seconds`, idle (from its last request or its hold's expiry) for
/// `min_idle_seconds`, no per-model lease, no pin, and never a model a
/// request could load straight back. Scripted 256 GB machine of
/// `UnreclaimableLoadMemoryFixture`; Super's load is a stub slot unless a test
/// drives the real gate.
@Suite("Selected models an operation displaced recover within the victim rules", .serialized)
struct SelectedModelRecoveryVictimTests {
    private typealias Fixture = UnreclaimableLoadMemoryFixture

    /// The operation Mark's coordinator sends: load GLM with a placement hold,
    /// unloading Super first, with no lease.
    private static func operation(expecting residents: [String]) -> ModelAutopilotCommand {
        ModelAutopilotCommand(commandId: "op_fedcba9876543210fedcba9876543210",
            loadModelId: Fixture.glmID, unloadModelIds: [Fixture.superID], expectedResidentModels: residents,
            expiresAtMs: ProviderLoop.autopilotNowMs + 60_000, leaseSeconds: 0,
            sessionId: "session", revision: "test", holdSeconds: 600)
    }

    // MARK: - Operation victims

    /// The reported operation, with Super resident and its explicit victim:
    /// Super waits, and GLM's hold keeps it for its ten minutes.
    @Test(.timeLimit(.minutes(1)))
    func anOperationThatUnloadsSuperForGLMQueuesSuper() async throws {
        let fixture = try await Fixture.make(glm: .autopilotInventory)
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        await fixture.install(Fixture.superID, idleFor: .seconds(3_600))
        await loop.ageAutopilotResidentsForTesting()
        await loop.activateAutopilotForTesting()
        let status = try #require(await fixture.withModelCache {
            await loop.runAutopilotCommandForTesting(
                Self.operation(expecting: [Fixture.gemmaID, Fixture.glmID, Fixture.superID]))
        })
        #expect(status.status == .succeeded, "\(status.error ?? "")")
        await loop.clearAutopilotControl()
        #expect(fixture.shutdownCalls(Fixture.superID) == 1)
        #expect(await loop.selectedModelRecovery.entries.keys.sorted() == [Fixture.superID])

        await loop.setSelectedModelRecoveryLoadOverrideForTesting { id in await fixture.install(id) }
        await checkSelectedModelRecovery(loop, at: .now)
        let held = try await superRecoveryEntry(loop)
        #expect(held.blocker?.contains("Autopilot hold until ") == true, "\(held.blocker ?? "")")
        #expect(fixture.shutdownCalls(Fixture.glmID) == 0)
    }

    /// The operation unloads Super, then GLM's own load fails: nothing took
    /// Super's memory, yet nothing retried it. Super now waits from the moment
    /// it leaves residency and loads at the next check.
    @Test(.timeLimit(.minutes(1)))
    func aVictimWaitsEvenWhenItsOperationThenFails() async throws {
        let fixture = try await Fixture.make(glm: .autopilotInventory, resident: [Fixture.gemmaID])
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        await fixture.install(Fixture.superID, idleFor: .seconds(3_600))
        await loop.ageAutopilotResidentsForTesting()
        await loop.activateAutopilotForTesting()
        let status = try #require(await fixture.withModelCache {
            await loop.runAutopilotCommandForTesting(Self.operation(expecting: [Fixture.gemmaID, Fixture.superID]))
        })
        #expect(status.status == .failed, "\(status.error ?? "")")
        await loop.clearAutopilotControl()
        #expect(fixture.shutdownCalls(Fixture.superID) == 1)
        #expect(await loop.modelLoadingResidentIDs() == [Fixture.gemmaID])
        #expect(await loop.selectedModelRecovery.entries.keys.sorted() == [Fixture.superID])

        await loop.setSelectedModelRecoveryLoadOverrideForTesting { id in await fixture.install(id) }
        await checkSelectedModelRecovery(loop, at: .now)
        #expect(await loop.modelLoadingResidentIDs() == [Fixture.gemmaID, Fixture.superID])
        #expect(await loop.selectedModelRecovery.isEmpty)
    }

    /// An operation for a model of the running daemon's selection (here a
    /// stale one: the saved filter dropped GLM after the start) unloads Super.
    /// Super waits, and its blocker says a restart applies the filter. GLM is
    /// never evicted however long it idles after its hold, since any request
    /// could load it straight back and evict Super in turn.
    @Test(.timeLimit(.minutes(1)))
    func aVictimOfTheStaleSelectionWaitsAndTheStaleModelIsNeverEvicted() async throws {
        let fixture = try await Fixture.make(glm: .ordinary)
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        var config = try ConfigManager.load(from: fixture.configPath)
        config.backend.enabledModels = [Fixture.superID, Fixture.gemmaID]
        try ConfigManager.save(config, to: fixture.configPath)
        await loop.refreshAutopilotSettings()
        await fixture.install(Fixture.superID, idleFor: .seconds(3_600))
        await loop.ageAutopilotResidentsForTesting()
        await loop.activateAutopilotForTesting()
        let status = try #require(await fixture.withModelCache {
            await loop.runAutopilotCommandForTesting(
                Self.operation(expecting: [Fixture.gemmaID, Fixture.glmID, Fixture.superID]))
        })
        #expect(status.status == .succeeded, "\(status.error ?? "")")
        await loop.clearAutopilotControl()
        #expect(fixture.shutdownCalls(Fixture.superID) == 1)
        #expect(await loop.selectedModelRecovery.entries.keys.sorted() == [Fixture.superID])

        await loop.setSelectedModelRecoveryLoadOverrideForTesting { id in await fixture.install(id) }
        let start = ContinuousClock.now
        await loop.setAutopilotHoldForTesting(Fixture.glmID, until: start.advanced(by: .seconds(-7_200)))
        await loop.setIdleForTesting(Fixture.glmID, since: start.advanced(by: .seconds(-7_200)))
        for offset in [0, 3_600, 86_400] {
            await checkSelectedModelRecovery(loop, at: start.advanced(by: .seconds(offset)))
        }
        #expect(fixture.shutdownCalls(Fixture.glmID) == 0)
        #expect(fixture.shutdownCalls(Fixture.gemmaID) == 0)
        #expect(await loop.modelLoadingResidentIDs() == [Fixture.gemmaID, Fixture.glmID])
        let waiting = try await superRecoveryEntry(loop)
        #expect(waiting.blocker == "needs 83.6 GB; 36.8 GB usable; glm-5.3-flash stays in the running daemon's "
            + "selection until a restart applies the saved enabled_models", "\(waiting.blocker ?? "")")
    }

    // MARK: - Autopilot's victim rules

    /// GLM was placed ten minutes ago, without a hold, and has been idle since:
    /// an operation could not unload it before Autopilot's minimum dwell, so
    /// recovery waits for it too.
    @Test(.timeLimit(.minutes(1)))
    func anAdoptionYoungerThanTheMinimumDwellStays() async throws {
        let fixture = try await Fixture.superWaitingBehindAdoptedGLM()
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        let start = ContinuousClock.now
        await loop.setAutopilotResidentSinceForTesting(Fixture.glmID, start.advanced(by: .seconds(-600)))
        await loop.setIdleForTesting(Fixture.glmID, since: start.advanced(by: .seconds(-600)))

        await checkSelectedModelRecovery(loop, at: start)
        #expect(fixture.shutdownCalls(Fixture.glmID) == 0)
        let waiting = try await superRecoveryEntry(loop)
        #expect(waiting.blocker?.contains("waiting for glm-5.3-flash (resident 10m of Autopilot's 30m minimum dwell)")
            == true, "\(waiting.blocker ?? "")")

        await checkSelectedModelRecovery(loop, at: start.advanced(by: .seconds(1_200)))
        #expect(fixture.shutdownCalls(Fixture.glmID) == 1)
        #expect(fixture.shutdownCalls(Fixture.gemmaID) == 0)
        #expect(await loop.modelLoadingResidentIDs() == [Fixture.gemmaID, Fixture.superID])
        #expect(await loop.selectedModelRecovery.isEmpty)
    }

    /// Autopilot's `min_idle_seconds` is ten minutes and GLM's hold expired
    /// five minutes ago; GLM's last request was hours before that. Idle time
    /// runs from the hold's expiry, so recovery waits five more minutes.
    @Test(.timeLimit(.minutes(1)))
    func idleRunsFromTheHoldExpiryForAutopilotsMinimumIdle() async throws {
        let fixture = try await Fixture.superWaitingBehindAdoptedGLM(holdSeconds: 3_600)
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        await loop.updateAutopilotSettingsForTesting { $0.minIdleSeconds = 600 }
        let start = ContinuousClock.now
        let expiry = start.advanced(by: .seconds(-300))
        await loop.setAutopilotHoldForTesting(Fixture.glmID, until: expiry)

        await checkSelectedModelRecovery(loop, at: start)
        #expect(fixture.shutdownCalls(Fixture.glmID) == 0)
        let waiting = try await superRecoveryEntry(loop)
        #expect(waiting.blocker?.contains("waiting for glm-5.3-flash (idle 5m of the 10m recovery waits for)") == true,
                "\(waiting.blocker ?? "")")

        await checkSelectedModelRecovery(loop, at: expiry.advanced(by: .seconds(600)))
        #expect(fixture.shutdownCalls(Fixture.glmID) == 1)
        #expect(await loop.modelLoadingResidentIDs() == [Fixture.gemmaID, Fixture.superID])
    }

    /// An operation's per-model lease keeps its target off other operations'
    /// victim lists (`active_lease`); recovery honours it the same way.
    @Test(.timeLimit(.minutes(1)))
    func aPerModelLeaseKeepsTheAdoption() async throws {
        let fixture = try await Fixture.superWaitingBehindAdoptedGLM()
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        let start = ContinuousClock.now
        await loop.setAutopilotLeaseForTesting(Fixture.glmID, until: start.advanced(by: .seconds(900)))

        await checkSelectedModelRecovery(loop, at: start)
        #expect(fixture.shutdownCalls(Fixture.glmID) == 0)
        let waiting = try await superRecoveryEntry(loop)
        #expect(waiting.blocker?.contains("waiting for glm-5.3-flash (Autopilot lease for another 15m)") == true,
                "\(waiting.blocker ?? "")")

        await checkSelectedModelRecovery(loop, at: start.advanced(by: .seconds(900)))
        #expect(fixture.shutdownCalls(Fixture.glmID) == 1)
        #expect(await loop.modelLoadingResidentIDs() == [Fixture.gemmaID, Fixture.superID])
    }

    @Test(.timeLimit(.minutes(1)))
    func aPinnedModelIsNeverEvicted() async throws {
        let fixture = try await Fixture.superWaitingBehindAdoptedGLM()
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        await loop.updateAutopilotSettingsForTesting { $0.pinnedModels = [Fixture.glmID] }
        await checkSelectedModelRecovery(loop, at: .now.advanced(by: .seconds(86_400)))
        #expect(fixture.shutdownCalls(Fixture.glmID) == 0)
        let waiting = try await superRecoveryEntry(loop)
        #expect(waiting.blocker?.hasSuffix("no model outside the selection can be evicted to make room") == true,
                "\(waiting.blocker ?? "")")
    }

    // MARK: - Refusals

    /// The production attempt through Super's real gate: the idle GLM makes
    /// room, then Super's loader refuses for a reason other than memory. Super
    /// leaves the recovery and is never tried again.
    @Test(.timeLimit(.minutes(1)))
    func aRefusalOtherThanMemoryIsNotRetried() async throws {
        let fixture = try await Fixture.make(glm: .autopilotInventory)
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        await loop.settleAutopilotOperationForTesting(target: Fixture.glmID)
        let attempts = ScriptedCounter()
        let refusal = "Nemotron Super load of '\(Fixture.superID)': checkpoint identity is not pinned"
        await loop.setNemotronSuperSlotLoaderForTesting(NemotronSuperSlotLoader(
            pinned: true, physicalBytes: Fixture.physicalBytes,
            kvBytesPerToken: { _ in
                attempts.increment()
                throw InferenceError.modelLoadFailed(refusal)
            },
            load: { _ in throw InferenceError.modelLoadFailed("the scripted machine never loads Super") }),
            environment: [:])
        await loop.enqueueSelectedModelRecovery([Fixture.superID])

        await fixture.withModelCache { await checkSelectedModelRecovery(loop, at: .now) }
        #expect(attempts.value == 1)
        #expect(fixture.shutdownCalls(Fixture.glmID) == 1)
        #expect(fixture.shutdownCalls(Fixture.gemmaID) == 0)
        #expect(await loop.modelLoadingLastLoadError()?.message == refusal)
        #expect(await loop.selectedModelRecovery.isEmpty)

        await fixture.withModelCache { await checkSelectedModelRecovery(loop, at: .now.advanced(by: .seconds(86_400))) }
        #expect(attempts.value == 1)
    }
}
