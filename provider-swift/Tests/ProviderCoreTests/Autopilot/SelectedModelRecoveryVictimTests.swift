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

    /// GLM adopted outside the selection (optionally held), resident and idle
    /// for two hours, and Super waiting; Super's load installs a stub slot.
    private func superWaitingBehindAdoptedGLM(holdSeconds: Int? = nil) async throws -> Fixture {
        let fixture = try await Fixture.make(glm: .autopilotInventory)
        let loop = fixture.loop
        await loop.settleAutopilotOperationForTesting(target: Fixture.glmID, holdSeconds: holdSeconds)
        await loop.setSelectedModelRecoveryLoadOverrideForTesting { id in await fixture.install(id) }
        await loop.enqueueSelectedModelRecovery([Fixture.superID])
        #expect(await loop.selectedModelRecovery.entries.keys.sorted() == [Fixture.superID])
        return fixture
    }

    private func check(_ loop: ProviderLoop, at now: ContinuousClock.Instant) async {
        await loop.checkSelectedModelRecoveryIfDue(now: now)
        await loop.awaitSelectedModelRecoveryAttemptForTesting()
    }

    private func entry(_ loop: ProviderLoop) async throws -> SelectedModelRecovery.Entry {
        try #require(await loop.selectedModelRecovery.entries[Fixture.superID])
    }

    /// The operation Mark's coordinator sends: load GLM with a placement hold,
    /// unloading Super first, with no lease.
    private static func operation(expecting residents: [String]) -> ModelAutopilotCommand {
        ModelAutopilotCommand(commandId: "op_fedcba9876543210fedcba9876543210",
            loadModelId: Fixture.glmID, unloadModelIds: [Fixture.superID], expectedResidentModels: residents,
            expiresAtMs: ProviderLoop.autopilotNowMs + 60_000, leaseSeconds: 0,
            sessionId: "session", revision: "test", holdSeconds: 600)
    }

    // MARK: - Operation victims

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
        await check(loop, at: .now)
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
            await check(loop, at: start.advanced(by: .seconds(offset)))
        }
        #expect(fixture.shutdownCalls(Fixture.glmID) == 0)
        #expect(fixture.shutdownCalls(Fixture.gemmaID) == 0)
        #expect(await loop.modelLoadingResidentIDs() == [Fixture.gemmaID, Fixture.glmID])
        let waiting = try await entry(loop)
        #expect(waiting.blocker == "needs 83.6 GB; 36.8 GB usable; glm-5.3-flash stays in the running daemon's "
            + "selection until a restart applies the saved enabled_models", "\(waiting.blocker ?? "")")
    }

    // MARK: - Autopilot's victim rules

    /// GLM was placed ten minutes ago, without a hold, and has been idle since:
    /// an operation could not unload it before Autopilot's minimum dwell, so
    /// recovery waits for it too.
    @Test(.timeLimit(.minutes(1)))
    func anAdoptionYoungerThanTheMinimumDwellStays() async throws {
        let fixture = try await superWaitingBehindAdoptedGLM()
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        let start = ContinuousClock.now
        await loop.setAutopilotResidentSinceForTesting(Fixture.glmID, start.advanced(by: .seconds(-600)))
        await loop.setIdleForTesting(Fixture.glmID, since: start.advanced(by: .seconds(-600)))

        await check(loop, at: start)
        #expect(fixture.shutdownCalls(Fixture.glmID) == 0)
        let waiting = try await entry(loop)
        #expect(waiting.blocker?.contains("waiting for glm-5.3-flash (resident 10m of Autopilot's 30m minimum dwell)")
            == true, "\(waiting.blocker ?? "")")

        await check(loop, at: start.advanced(by: .seconds(1_200)))
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
        let fixture = try await superWaitingBehindAdoptedGLM(holdSeconds: 3_600)
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        await loop.updateAutopilotSettingsForTesting { $0.minIdleSeconds = 600 }
        let start = ContinuousClock.now
        let expiry = start.advanced(by: .seconds(-300))
        await loop.setAutopilotHoldForTesting(Fixture.glmID, until: expiry)

        await check(loop, at: start)
        #expect(fixture.shutdownCalls(Fixture.glmID) == 0)
        let waiting = try await entry(loop)
        #expect(waiting.blocker?.contains("waiting for glm-5.3-flash (idle 5m of the 10m recovery waits for)") == true,
                "\(waiting.blocker ?? "")")

        await check(loop, at: expiry.advanced(by: .seconds(600)))
        #expect(fixture.shutdownCalls(Fixture.glmID) == 1)
        #expect(await loop.modelLoadingResidentIDs() == [Fixture.gemmaID, Fixture.superID])
    }

    /// An operation's per-model lease keeps its target off other operations'
    /// victim lists (`active_lease`); recovery honours it the same way.
    @Test(.timeLimit(.minutes(1)))
    func aPerModelLeaseKeepsTheAdoption() async throws {
        let fixture = try await superWaitingBehindAdoptedGLM()
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        let start = ContinuousClock.now
        await loop.setAutopilotLeaseForTesting(Fixture.glmID, until: start.advanced(by: .seconds(900)))

        await check(loop, at: start)
        #expect(fixture.shutdownCalls(Fixture.glmID) == 0)
        let waiting = try await entry(loop)
        #expect(waiting.blocker?.contains("waiting for glm-5.3-flash (Autopilot lease for another 15m)") == true,
                "\(waiting.blocker ?? "")")

        await check(loop, at: start.advanced(by: .seconds(900)))
        #expect(fixture.shutdownCalls(Fixture.glmID) == 1)
        #expect(await loop.modelLoadingResidentIDs() == [Fixture.gemmaID, Fixture.superID])
    }

    @Test(.timeLimit(.minutes(1)))
    func aPinnedModelIsNeverEvicted() async throws {
        let fixture = try await superWaitingBehindAdoptedGLM()
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        await loop.updateAutopilotSettingsForTesting { $0.pinnedModels = [Fixture.glmID] }
        await check(loop, at: .now.advanced(by: .seconds(86_400)))
        #expect(fixture.shutdownCalls(Fixture.glmID) == 0)
        let waiting = try await entry(loop)
        #expect(waiting.blocker?.hasSuffix("no model outside the selection can be evicted to make room") == true,
                "\(waiting.blocker ?? "")")
    }

    /// The release of a busy adoption after its hold (policy) waits for the
    /// same minimum dwell: GLM, resident fifteen minutes, goes at thirty.
    @Test(.timeLimit(.minutes(1)))
    func aBusyAdoptionIsNotReleasedBeforeItsMinimumDwell() async throws {
        let fixture = try await Fixture.make(glm: .autopilotInventory)
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        await loop.settleAutopilotOperationForTesting(target: Fixture.glmID, holdSeconds: 600)
        await loop.setSelectedModelRecoveryLoadOverrideForTesting { id in await fixture.install(id) }
        await loop.enqueueSelectedModelRecovery([Fixture.superID])
        let start = ContinuousClock.now
        await loop.setAutopilotHoldForTesting(Fixture.glmID, until: start.advanced(by: .seconds(-660)))
        await loop.setAutopilotResidentSinceForTesting(Fixture.glmID, start.advanced(by: .seconds(-900)))
        await fixture.beginGLMRequest()

        await check(loop, at: start)
        await check(loop, at: start.advanced(by: .seconds(601)))
        #expect(await loop.autopilotServesModel(Fixture.glmID))
        await check(loop, at: start.advanced(by: .seconds(901)))
        #expect(await loop.autopilotServesModel(Fixture.glmID) == false)
        #expect(fixture.shutdownCalls(Fixture.glmID) == 0)
        await fixture.endGLMRequest()
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

        await fixture.withModelCache { await check(loop, at: .now) }
        #expect(attempts.value == 1)
        #expect(fixture.shutdownCalls(Fixture.glmID) == 1)
        #expect(fixture.shutdownCalls(Fixture.gemmaID) == 0)
        #expect(await loop.modelLoadingLastLoadError()?.message == refusal)
        #expect(await loop.selectedModelRecovery.isEmpty)

        await fixture.withModelCache { await check(loop, at: .now.advanced(by: .seconds(86_400))) }
        #expect(attempts.value == 1)
    }
}

extension ProviderLoop {
    func setAutopilotResidentSinceForTesting(_ id: String, _ since: ContinuousClock.Instant) {
        autopilotResidentSince[id] = since
    }

    func setAutopilotLeaseForTesting(_ id: String, until: ContinuousClock.Instant) {
        autopilotLeaseUntil[id] = until
    }
}
