import Foundation
import Testing
@testable import ProviderCore

@Suite("Autopilot placement holds", .serialized)
struct AutopilotPlacementHoldTests {
    private typealias Fixture = AutopilotPlacementFixture

    @Test func heldSlotIsNoEvictionCandidateUntilItsHoldExpires() async throws {
        let fixture = try await Fixture.make()
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        await loop.settleAutopilotOperationForTesting(target: Fixture.ordinary, holdSeconds: 600)
        #expect(await loop.autopilotHoldsModel(Fixture.ordinary))
        #expect(await loop.evictableModelSlots().keys.sorted() == [Fixture.inventory, Fixture.spare].sorted())

        await loop.setAutopilotHoldForTesting(Fixture.ordinary, until: .now.advanced(by: .seconds(-1)))
        #expect(await loop.autopilotHoldsModel(Fixture.ordinary) == false)
        #expect(await loop.evictableModelSlots().keys.sorted() == Fixture.all.sorted())
        // An expired hold stays the idle anchor but is no longer reported.
        #expect(await loop.autopilotPlacementsForTesting.held == [Fixture.ordinary])
        await loop.publishModelAutopilotSnapshot()
        #expect(await loop.state.modelAutopilot?.heldModels == nil)
    }

    @Test func idleUnloadWaitsForHoldExpiryPlusTheIdleTimeout() async throws {
        let fixture = try await Fixture.make()
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        let timeout = Duration.seconds(3_600)
        await loop.settleAutopilotOperationForTesting(target: Fixture.ordinary, holdSeconds: 600)

        // Every resident has been idle for two hours. Only the unheld models
        // reach the timeout; ordinary idle policy for them is unchanged.
        await loop.tickIdleMonitor(timeout: timeout)
        #expect(fixture.engines[Fixture.ordinary]?.shutdownCalls == 0)
        #expect(fixture.engines[Fixture.inventory]?.shutdownCalls == 1)
        #expect(fixture.engines[Fixture.spare]?.shutdownCalls == 1)

        // Expired, but the idle timeout restarts at the expiry.
        await loop.setAutopilotHoldForTesting(Fixture.ordinary, until: .now.advanced(by: .seconds(-1_800)))
        await loop.tickIdleMonitor(timeout: timeout)
        #expect(fixture.engines[Fixture.ordinary]?.shutdownCalls == 0)

        // Activity after the expiry remains the later reference.
        await loop.setAutopilotHoldForTesting(Fixture.ordinary, until: .now.advanced(by: .seconds(-3_700)))
        await loop.setIdleForTesting(Fixture.ordinary, since: .now.advanced(by: .seconds(-60)))
        await loop.tickIdleMonitor(timeout: timeout)
        #expect(fixture.engines[Fixture.ordinary]?.shutdownCalls == 0)

        await loop.setIdleForTesting(Fixture.ordinary, since: .now.advanced(by: .seconds(-7_200)))
        await loop.tickIdleMonitor(timeout: timeout)
        #expect(fixture.engines[Fixture.ordinary]?.shutdownCalls == 1)
        #expect(await loop.autopilotPlacementsForTesting.held.isEmpty)
    }

    @Test func coldLoadNeedingAHeldSlotFailsWithoutEvictingIt() async throws {
        // Two configured slots, both resident and held.
        let fixture = try await Fixture.make(resident: [Fixture.ordinary, Fixture.inventory], maxModelSlots: 2)
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        await loop.activateAutopilotForTesting()
        await loop.restoreAutopilotResidentModels()
        await loop.settleAutopilotOperationForTesting(target: Fixture.ordinary, holdSeconds: 600)
        await loop.settleAutopilotOperationForTesting(target: Fixture.inventory, holdSeconds: 600)
        await loop.clearAutopilotControl()
        let snapshot = try #require(await loop.state.modelAutopilot)
        #expect(snapshot.heldModels?.map(\.modelId) == [Fixture.inventory, Fixture.ordinary].sorted())

        // Slot-cap eviction: refused with the existing transient slot error.
        await loop.advertiseOrdinaryForTesting(Fixture.model("cold"))
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        #expect(await loop.fastAdmissionReject(modelId: "cold"))
        do {
            try await loop.ensureModelLoaded(modelId: "cold", revisionDirectory: try sandbox.makeSnapshot("cold"))
            Issue.record("a cold load evicted a held placement")
        } catch let error as InferenceError {
            #expect(ProviderLoop.loadErrorStatusCode(for: error) == 503)
            #expect("\(error)".contains("slot"))
        }
        #expect(fixture.engines.values.allSatisfy { $0.shutdownCalls == 0 })
        #expect(await loop.modelLoadingResidentIDs() == [Fixture.inventory, Fixture.ordinary].sorted())
    }

    @Test func memoryEvictionNeverReclaimsAHeldSlot() async throws {
        let fixture = try await Fixture.make(resident: [Fixture.ordinary])
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        await loop.settleAutopilotOperationForTesting(target: Fixture.ordinary, holdSeconds: 600)
        await ModelLoadingFixtures.setAvailableMemory(loop, gb: 0)
        do {
            try await loop.evictUntilAvailable(weightsGb: 1)
            Issue.record("insufficient memory was satisfied by evicting a held placement")
        } catch InferenceError.modelLoadFailed(let message) {
            #expect(message.contains("Insufficient memory"))
        }
        #expect(fixture.engines[Fixture.ordinary]?.shutdownCalls == 0)
    }

    @Test func coldLoadCapacityGivesHeldWeightsNoReclaimCredit() async throws {
        let gib: UInt64 = 1 << 30
        // MLX holds the resident weights; nothing else is in use.
        let budget = GlobalKVCacheBudget(
            activationReserveBytes: UnifiedMemoryCap.resolvedActivationReserveBytes(modelIDs: Fixture.all),
            configReserveBytes: 0,
            memorySnapshot: { .init(total: 64 * gib, active: 24 * gib, cache: 0, systemAvailable: 40 * gib) })
        let fixture = try await Fixture.make(resident: [Fixture.ordinary, Fixture.inventory],
            weightsBytes: Int(8 * gib), kvBudget: budget)
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        await loop.updateAggregateCapacity()
        let unheld = try #require(await loop.backendCapacityForTesting()?.freeForLoadGb)
        await loop.settleAutopilotOperationForTesting(target: Fixture.ordinary, holdSeconds: 600)
        #expect(await loop.autopilotHeldWeightBytes() == 8 * gib)
        await loop.updateAggregateCapacity()
        let held = try #require(await loop.backendCapacityForTesting()?.freeForLoadGb)
        #expect(abs((unheld - held) - 8) < 0.001)
    }

    @Test func holdReportCarriesItsWallClockExpiry() async throws {
        let fixture = try await Fixture.make()
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        let before = Int64(Date().timeIntervalSince1970 * 1_000)
        await loop.settleAutopilotOperationForTesting(target: Fixture.ordinary, holdSeconds: 600)
        let after = Int64(Date().timeIntervalSince1970 * 1_000)
        let hold = try #require(await loop.state.modelAutopilot?.heldModels?.first)
        #expect(hold.modelId == Fixture.ordinary)
        #expect(hold.expiresAtMs >= before + 599_000 && hold.expiresAtMs <= after + 600_000)
        // A zero or absent hold records nothing and leaves an existing hold.
        await loop.settleAutopilotOperationForTesting(target: Fixture.inventory, holdSeconds: 0)
        await loop.settleAutopilotOperationForTesting(target: Fixture.ordinary)
        #expect(await loop.state.modelAutopilot?.heldModels?.map(\.modelId) == [Fixture.ordinary])
    }

    @Test func adminUnloadOfAHeldVictimSucceedsAndClearsTheHold() async throws {
        let fixture = try await Fixture.make()
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        await loop.settleAutopilotOperationForTesting(target: Fixture.ordinary, holdSeconds: 600)
        await loop.activateAutopilotForTesting()
        let released = await loop.runAutopilotCommandForTesting(
            Fixture.command("release-held", unload: [Fixture.ordinary]))
        #expect(released?.status == .succeeded)
        #expect(fixture.engines[Fixture.ordinary]?.shutdownCalls == 1)
        #expect(await loop.autopilotPlacementsForTesting.held.isEmpty)
    }
}

private extension ProviderLoop {
    /// An ordinary selection the operator added; cached but not resident.
    func advertiseOrdinaryForTesting(_ model: ModelInfo) {
        ordinaryServingModelIDs.insert(model.id)
        advertisedModels[model.id] = model
    }
}
