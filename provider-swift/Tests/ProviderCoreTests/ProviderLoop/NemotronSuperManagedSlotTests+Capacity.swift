// Copyright © 2026 Eigen Labs.

import Foundation
import Testing
@testable import ProviderCore

/// The managed Super owner holds its prefill lane, paged decode rows and MTP
/// round in the shared budget beside its KV grant; only its prefix bank is
/// carved from the grant. The grant and the heartbeat count those
/// reservations as resident, so the advertised token budget fits the ledger.
extension NemotronSuperManagedSlotTests {
    @Test(.timeLimit(.minutes(2)))
    func advertisedTokenBudgetFitsTheLedgerBesideTheOwnerReservations() async throws {
        let fixture = try await Self.fixture(mode: .auto)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let loop = fixture.loop
        // Grants and the heartbeat clamp come from this machine, not the host.
        let physical: UInt64 = 64 << 30
        await loop.setEngineV2SlotHooksForTesting(ProviderLoop.EngineV2SlotHooks(
            physicalMemoryBytes: physical, makeEngine: { _, _ in throw CancellationError() }))
        try await loop.ensureModelLoaded(modelId: Self.modelID, allowEviction: false,
                                         revisionDirectory: fixture.directory)
        let owner = try #require(await loop.nemotronSuperOwnerForTesting(modelId: Self.modelID))
        let held = await fixture.budget.reservationBytesSnapshot()
        let besideGrant = held.filter {
            NemotronSuperLocalPrefill.isLaneReservationID($0.key)
                || NemotronSuperLocalKVBackend.isDecodeRowsReservationID($0.key)
                || NemotronSuperLocalMTP.isRoundReservationID($0.key)
        }.values.reduce(0, +)
        #expect(besideGrant > 0 && UInt64(owner.reservedBesideGrantBytes) == besideGrant)

        // The lone slot's grant: the fleet budget less its weights and those
        // reservations. The engine admits no more than the ledger holds.
        let fleet = UnifiedMemoryCap.kvBudgetBytes(physicalBytes: physical,
            residentWeightBytes: UInt64(owner.sizing.weightsBytes) + besideGrant,
            activationReserveBytes: UnifiedMemoryCap.resolvedActivationReserveBytes(modelIDs: [Self.modelID]),
            configReserveBytes: 4 << 30)
        #expect(await owner.bridge.slotKVBytesClaim() == Int(fleet))
        let room = fixture.budget.memoryHeadroomSnapshot().runtimeRemainingBytes
        let ceiling = await owner.bridge.engineKVBytesCapacity()
        #expect(UInt64(ceiling) <= room, "engine ceiling \(ceiling) B beside a ledger room of \(room) B")

        // Every request the heartbeat advertises fits beside the reservations:
        // the token budget at its rate, with each prospective request's fixed bytes.
        await loop.updateAggregateCapacity()
        let slot = try #require(await loop.backendCapacityForTesting()?.slots.first { $0.model == Self.modelID })
        let overhead = try #require(await owner.bridge.maximumRequestOverheadBytes())
        #expect(slot.activeTokenBudgetMax > 0 && slot.maxConcurrency == 8)
        let advertised = UInt64(slot.activeTokenBudgetMax) * UInt64(slot.kvBytesPerToken)
            + UInt64(overhead) * UInt64(slot.maxConcurrency)
        #expect(advertised <= room, "advertised \(advertised) B beside a ledger room of \(room) B")

        // Unloading returns the reservations with the grant.
        #expect(await loop.unloadModel(Self.modelID))
        #expect(await fixture.budget.outstandingReservedBytes() == 0)
    }

    /// Beside an idle model with a far larger KV share (the fixture owner
    /// publishes its 1,024-token context against that model's 8,192), Super's
    /// proportional share is a few MiB. Both floors fit the budget, so Super
    /// is funded to its floor and loads; the co-resident model keeps its own.
    @Test(.timeLimit(.minutes(2)))
    func superBesideALargerKVShareLoadsAtItsFloor() async throws {
        let fixture = try await Self.coResidentFixture(weightsGiB: 1, availableGiB: 110)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let loop = fixture.loop
        await loop.setEngineV2SlotHooksForTesting(ProviderLoop.EngineV2SlotHooks(
            physicalMemoryBytes: 128 << 30, makeEngine: { _, _ in throw CancellationError() }))
        try await loop.ensureModelLoaded(modelId: Self.modelID, allowEviction: false,
                                         revisionDirectory: fixture.directory)
        let owner = try #require(await loop.nemotronSuperOwnerForTesting(modelId: Self.modelID))
        let grant = await owner.bridge.resliceAdmissionBytesClaim()
        #expect(grant >= (await owner.bridge.minimumServiceableGrantBytes()))
        #expect(await owner.bridge.superGrantRefusal(grantBytes: grant, requests: 1) == nil)
        let coResidentGrant = try #require(fixture.idle.capacityUpdates.last)
        #expect(coResidentGrant >= Int(EngineV2KVSizing.minimumServiceableGrantBytes))
        #expect(await loop.modelLoadingResidentIDs() == [Self.coResidentID, Self.modelID].sorted())
        #expect(await loop.unloadModel(Self.modelID))
    }

    /// The newcomer check counts Super's planned lane and round beside its
    /// grant. A co-resident model whose own floor leaves less than Super's
    /// base floor of that budget refuses the load before anything is built:
    /// nothing is published or retained, and the co-resident model keeps its
    /// grant and is not evicted.
    @Test(.timeLimit(.minutes(2)))
    func floorsAboveTheBudgetRefuseTheLoadBeforeTheBuild() async throws {
        let fixture = try await Self.coResidentFixture(weightsGiB: 1, availableGiB: 110)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let loop = fixture.loop
        await loop.setEngineV2SlotHooksForTesting(ProviderLoop.EngineV2SlotHooks(
            physicalMemoryBytes: 128 << 30, makeEngine: { _, _ in throw CancellationError() }))
        await loop.resliceGrowSurvivorsForTesting()
        let lone = try #require(fixture.idle.capacityUpdates.last)
        // Its floor leaves 1.75 GiB of the lone budget, less than Super's
        // planned reservations and base floor need.
        let coResident = ResliceFloorScenario.makeBridge(modelId: Self.coResidentID,
            fixedRequestBytes: Int(Double(lone - (7 << 28)) * 0.95) - (1 << 30), grant: lone)
        await loop.modelLoadingInstallSlot(Self.coResidentID, bridge: coResident, weightsBytes: 1 << 30)
        var refusal: Error?
        do {
            try await loop.ensureModelLoaded(modelId: Self.modelID, allowEviction: false,
                                             revisionDirectory: fixture.directory)
        } catch { refusal = error }
        let error = try #require(refusal)
        #expect(ProviderLoop.loadErrorStatusCode(for: error) == 503)
        #expect("\(error)".contains("below its serviceable KV grant"), "\(error)")
        #expect(await loop.modelLoadingLastLoadError()?.message.contains("below its serviceable KV grant") == true)
        #expect(await loop.nemotronSuperOwnerForTesting(modelId: Self.modelID) == nil)
        #expect(await loop.engineV2Runtime.bridge(forModel: Self.modelID) == nil)
        #expect(await loop.modelLoadingResidentIDs() == [Self.coResidentID])
        #expect(await coResident.engineKVBytesCapacity() == lone, "the co-resident model keeps its grant")
        #expect(await fixture.budget.outstandingReservedBytes() == 0)
        #expect(await loop.nemotronSuperRetainedWeightBytesForTesting() == 0)
        await coResident.shutdown()
    }

    /// A load whose native work did not retire keeps the installation's size
    /// and the lane, round and bank its pinned LOAD claim holds beside it
    /// charged in the fleet budget, and refuses Super from then on. Super
    /// loads alone on an emulated 128 GiB Mac, so its grant, and with it the
    /// planned bank, does not depend on the test machine's memory.
    @Test(.timeLimit(.minutes(1)))
    func retainedLoadFaultKeepsItsPlannedReservationsCharged() async throws {
        let fixture = try await Self.coResidentFixture(weightsGiB: [], availableGiB: 110)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let loop = fixture.loop
        await loop.setEngineV2SlotHooksForTesting(ProviderLoop.EngineV2SlotHooks(
            physicalMemoryBytes: 128 << 30, makeEngine: { _, _ in throw CancellationError() }))
        let requested = Box<NemotronSuperSlotLoader.Request>()
        await loop.setNemotronSuperSlotLoaderForTesting(NemotronSuperSlotLoader(pinned: true,
            physicalBytes: 128 << 30, kvBytesPerToken: { _ in 64 }) { request in
            requested.set(request)
            throw NemotronSuperSlotError.retainedFault
        }, environment: [PrefixCachePolicy.memoryEnvironmentFlag: "1"])
        var refusal: Error?
        do {
            try await loop.ensureModelLoaded(modelId: Self.modelID, allowEviction: false,
                                             revisionDirectory: fixture.directory)
        } catch { refusal = error }
        let error = try #require(refusal)
        #expect(ProviderLoop.loadErrorStatusCode(for: error) == 503)
        #expect("\(error)".contains("native work did not retire"), "\(error)")
        let request = try #require(requested.value)
        let shares = try NemotronSuperLocalBridgeBuilder.pinnedOwnerShares(environment: request.environment,
            kvBytesCapacity: request.kvBytesCapacity, speculates: true, physicalBytes: 128 << 30)
        #expect(shares.bank > 0 && shares.round > 0)
        let model = try #require(await loop.advertisedModels[Self.modelID])
        let besideWeights = UInt64(try #require(shares.total))
        #expect(await loop.nemotronSuperRetainedWeightBytesForTesting() == model.sizeBytes + besideWeights)
        #expect(await loop.fastAdmissionReject(modelId: Self.modelID))
    }
}
