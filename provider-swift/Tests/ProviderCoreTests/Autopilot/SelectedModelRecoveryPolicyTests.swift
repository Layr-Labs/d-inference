import Foundation
import Testing
@testable import ProviderCore

/// When a waiting selected model loads, what it may evict, how checks back
/// off, and what the daemon reports, on the scripted 256 GB machine with
/// Super waiting behind GLM-5.3-Flash. Super's load itself is replaced by a
/// stub slot holding its scripted bytes.
@Suite("Selected-model recovery policy", .serialized)
struct SelectedModelRecoveryPolicyTests {
    private typealias Fixture = UnreclaimableLoadMemoryFixture

    /// GLM adopted outside the selection (optionally held) and Super waiting.
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

    @Test(.timeLimit(.minutes(1)))
    func busyThenRecentlyIdleThenIdleLongEnough() async throws {
        let fixture = try await superWaitingBehindAdoptedGLM()
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        let start = ContinuousClock.now

        await fixture.beginGLMRequest()
        await check(loop, at: start)
        var waiting = try await entry(loop)
        #expect(waiting.blocker?.hasPrefix("needs 83.6 GB; 34.8 GB usable; waiting for glm-5.3-flash "
            + "(171.3 GB: 1 request in flight") == true, "\(waiting.blocker ?? "")")
        #expect(waiting.checks == 1)
        #expect(waiting.nextCheckAt == start.advanced(by: .seconds(30)))
        let state = try #require(await loop.currentDaemonState().selectedModelRecovery?.first)
        #expect(state.model == Fixture.superID && state.blocker == waiting.blocker && state.loading == nil)

        // Just idle: a gap between requests is not idle enough.
        await fixture.endGLMRequest()
        let lastRequest = ContinuousClock.now
        await loop.markInferenceForTesting(Fixture.glmID, at: lastRequest)
        await check(loop, at: start.advanced(by: .seconds(31)))
        waiting = try await entry(loop)
        #expect(waiting.blocker?.contains("glm-5.3-flash (idle ") == true, "\(waiting.blocker ?? "")")
        // The next backoff step comes before GLM's idle threshold.
        #expect(waiting.nextCheckAt == start.advanced(by: .seconds(91)))
        await check(loop, at: start.advanced(by: .seconds(91)))
        waiting = try await entry(loop)
        #expect(waiting.nextCheckAt == lastRequest.advanced(by: SelectedModelRecovery.victimMinimumIdle))
        #expect(fixture.shutdownCalls(Fixture.glmID) == 0)

        // Idle for the hysteresis: GLM goes, the selected Gemma stays.
        await check(loop, at: lastRequest.advanced(by: .seconds(121)))
        #expect(fixture.shutdownCalls(Fixture.glmID) == 1)
        #expect(fixture.shutdownCalls(Fixture.gemmaID) == 0)
        #expect(await loop.modelLoadingResidentIDs() == [Fixture.gemmaID, Fixture.superID])
        #expect(await loop.selectedModelRecovery.isEmpty)
        #expect(await loop.currentDaemonState().selectedModelRecovery == nil)
        #expect(await loop.autopilotServesModel(Fixture.glmID) == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func aHoldKeepsGLMUntilItExpires() async throws {
        let fixture = try await superWaitingBehindAdoptedGLM(holdSeconds: 3_600)
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        let start = ContinuousClock.now
        await check(loop, at: start)
        let held = try await entry(loop)
        #expect(held.blocker?.contains("Autopilot hold until ") == true, "\(held.blocker ?? "")")
        // The hold ends in an hour: checks keep backing off meanwhile.
        #expect(held.nextCheckAt == start.advanced(by: .seconds(30)))
        #expect(fixture.shutdownCalls(Fixture.glmID) == 0)

        // Expired: idle is measured from the expiry, so GLM qualifies two
        // minutes after it.
        await loop.setAutopilotHoldForTesting(Fixture.glmID, until: .now.advanced(by: .seconds(-1)))
        await check(loop, at: start.advanced(by: .seconds(600)))
        #expect(fixture.shutdownCalls(Fixture.glmID) == 1)
        #expect(await loop.modelLoadingResidentIDs() == [Fixture.gemmaID, Fixture.superID])
        #expect(await loop.selectedModelRecovery.isEmpty)
    }

    /// GLM in the running daemon's selection (the saved filter dropped it
    /// after the start) is never evicted: the operator's selection outranks
    /// recovery, and the blocker says a restart applies the filter.
    @Test(.timeLimit(.minutes(1)))
    func aModelInTheRunningSelectionIsNeverEvicted() async throws {
        let fixture = try await Fixture.make(glm: .ordinary)
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        var config = try ConfigManager.load(from: fixture.configPath)
        config.backend.enabledModels = [Fixture.superID, Fixture.gemmaID]
        try ConfigManager.save(config, to: fixture.configPath)
        await loop.refreshAutopilotSettings()
        await loop.setSelectedModelRecoveryLoadOverrideForTesting { id in await fixture.install(id) }
        await loop.enqueueSelectedModelRecovery([Fixture.superID])
        await check(loop, at: .now)
        let waiting = try await entry(loop)
        #expect(waiting.blocker == "needs 83.6 GB; 36.8 GB usable; glm-5.3-flash stays in the running daemon's "
            + "selection until a restart applies the saved enabled_models", "\(waiting.blocker ?? "")")
        #expect(fixture.shutdownCalls(Fixture.glmID) == 0 && fixture.shutdownCalls(Fixture.gemmaID) == 0)
        #expect(await loop.currentDaemonState().enabledModelsAtStart
            == [Fixture.superID, Fixture.gemmaID, Fixture.glmID])
    }

    @Test(.timeLimit(.minutes(1)))
    func aMemoryRefusalKeepsWaitingAndAnyOtherFailureEndsTheRecovery() async throws {
        let fixture = try await superWaitingBehindAdoptedGLM()
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        let refusal = "Insufficient memory (1.0 GB free, need 2.0 GB) to load without evicting resident models"
        await loop.setSelectedModelRecoveryLoadOverrideForTesting { _ in throw InferenceError.modelLoadFailed(refusal) }
        await check(loop, at: .now)
        let waiting = try await entry(loop)
        #expect(waiting.blocker == refusal && waiting.checks == 1)

        // GLM is gone now; the next failure is not about memory.
        await loop.setSelectedModelRecoveryLoadOverrideForTesting { id in
            throw InferenceError.invalidModelDirectory("Model '\(id)' not found in local HuggingFace cache")
        }
        await check(loop, at: waiting.nextCheckAt)
        #expect(await loop.selectedModelRecovery.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func anotherLoadPausesTheCheckWithoutBackingOff() async throws {
        let fixture = try await superWaitingBehindAdoptedGLM()
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        let now = ContinuousClock.now
        await loop.modelLoadingSetLoadingAny(true)
        await check(loop, at: now)
        let paused = try await entry(loop)
        #expect(paused.checks == 0)
        #expect(paused.blocker == "another model load or unload is in progress")
        #expect(paused.nextCheckAt == now.advanced(by: SelectedModelRecovery.pauseRecheck))
        #expect(fixture.shutdownCalls(Fixture.glmID) == 0)
        await loop.modelLoadingSetLoadingAny(false)
    }

    /// With no explicit selection every model on disk is served and a cold
    /// one loads on request: nothing is retried.
    @Test func withoutAnExplicitSelectionNothingIsRetried() async throws {
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        let loop = try await ModelLoadingFixtures.makeLoop(sandbox: sandbox,
            models: [ModelLoadingFixtures.model("on-disk-a"), ModelLoadingFixtures.model("on-disk-b")])
        await loop.enqueueSelectedModelRecovery(["on-disk-a", "on-disk-b"])
        #expect(await loop.selectedModelRecovery.isEmpty)
    }

    @Test func checksBackOffToTenMinutesAndAnUnloadMakesThemDue() {
        var recovery = SelectedModelRecovery()
        let start = ContinuousClock.now
        recovery.enqueue("m", now: start, nowEpoch: 0)
        var steps: [Duration] = []
        for _ in 0..<7 {
            let now = recovery.entries["m"]!.nextCheckAt
            recovery.deferCheck("m", blocker: "short", now: now)
            steps.append(now.duration(to: recovery.entries["m"]!.nextCheckAt))
        }
        #expect(steps == [.seconds(30), .seconds(60), .seconds(120), .seconds(300), .seconds(600), .seconds(600),
                          .seconds(600)])
        let late = recovery.entries["m"]!.nextCheckAt
        #expect(recovery.nextDue(now: start) == nil)
        recovery.makeAllDue(now: start)
        #expect(recovery.nextDue(now: start) == "m")
        recovery.deferCheck("m", blocker: "hold", now: late, retryAt: late.advanced(by: .seconds(45)))
        #expect(recovery.entries["m"]!.nextCheckAt == late.advanced(by: .seconds(45)))
    }
}
