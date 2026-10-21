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
}
