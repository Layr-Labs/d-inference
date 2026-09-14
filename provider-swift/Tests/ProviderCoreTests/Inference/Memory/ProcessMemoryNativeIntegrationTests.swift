import Foundation
import MLX
import Testing

@testable import MLXLMCommon
@testable import ProviderCore

/// Run this suite in its own test process: exact-fit assertions observe the
/// real process allocator. Existing native test access binds Admission to the
/// paged pool; no production test-only API or synthetic U/M reader is added.
/// OS availability is non-binding; the test controls the cap for exact fits.
/// This exercises Admission/pool/adapter integration, not Engine submit or load.
@Suite("Process memory: native pages and real allocator", .serialized)
struct ProcessMemoryNativeIntegrationTests {
    private static func usage() -> ProcessMemoryLedger.Usage {
        let memory = Memory.snapshot()
        return .init(
            activeBytes: UInt64(memory.activeMemory),
            cacheBytes: UInt64(memory.cacheMemory),
            systemAvailableBytes: .max)
    }

    private func ledger() -> ProcessMemoryLedger {
        // Warm before constructing either the ledger or native Admission.
        _ = Memory.snapshot()
        return ProcessMemoryLedger(
            policy: .init(epoch: 0, capBytes: .max, reserveBytes: 0),
            readUsage: Self.usage)
    }

    private func fixture(_ owner: EngineProcessMemoryOwner) throws
        -> (PagedKVBackend, AdmissionV2, [CBv2LayerKind])
    {
        let kinds = [CBv2LayerKind(
            attention: .full, headDim: 64, kvHeads: 2, queryHeads: 4)]
        let config = PagedKVPoolConfig(
            capacityBytes: 32 << 20, maxPrefillChunk: 64, maxBufferLength: 32 << 20,
            segmentSizeBytes: 32 << 10, layerDTypes: [.bfloat16])
        let backend = try PagedKVBackend(layerKinds: kinds, config: config)
        let admission = AdmissionV2(
            layerKinds: kinds, bytesCapacity: config.capacityBytes,
            config: .init(watermarkFraction: 0, layerElementBytes: [DType.bfloat16.size]),
            residency: CBv2PagedKVResidency(config: config), processMemoryOwner: owner)
        backend.pool.bindAdmission(admission)
        return (backend, admission, kinds)
    }

    @discardableResult
    private func observe(_ ledger: ProcessMemoryLedger, _ phase: String)
        -> ProcessMemoryLedger.Snapshot
    {
        let snapshot = ledger.snapshot()
        print("native-memory phase=\(phase) active=\(snapshot.usage.activeBytes) "
              + "cache=\(snapshot.usage.cacheBytes) C=\(snapshot.chargedBytes) "
              + "M=\(snapshot.materializedBytes) C-M=\(snapshot.unmaterializedBytes) "
              + "remaining=\(snapshot.remainingBytes) debt=\(snapshot.commitmentDebtBytes) "
              + "owners=\(snapshot.ownerCount) "
              + "closing=\(snapshot.closingOwnerCount)")
        return snapshot
    }

    @Test func evaluatedPagesAvoidDoubleTaxAndRetainedAliasKeepsPressure() throws {
        let ledger = ledger()
        let owner = EngineProcessMemoryOwner(ledger: ledger)
        let competitor = EngineProcessMemoryOwner(ledger: ledger)
        let (backend, admission, kinds) = try fixture(owner)
        let request = CBv2RequestID(1)
        let before = observe(ledger, "before-reserve")
        #expect(before.chargedBytes == 0 && before.materializedBytes == 0)

        try admission.reserve(id: request, additionalTokens: 65)
        let reserved = observe(ledger, "reserved-before-allocation")
        #expect(reserved.chargedBytes == UInt64(admission.bytesReserved))
        #expect(reserved.chargedBytes > 0 && reserved.materializedBytes == 0)
        // Five usable pages occupy two three-page buffers and one two-page buffer.
        // Every independent buffer needs its own cache-reuse/alignment bound.
        let pageBytes = 2 * 2 * 16 * 64 * DType.bfloat16.size
        let preparationBound = try [3, 3, 2].reduce(UInt64(0)) { total, pages in
            total + UInt64(try Memory.allocationFootprintUpperBound(byteCount: pages * pageBytes))
        }
        var observedPreparation = false
        backend.pool.slabEval = { array in
            if !observedPreparation {
                observedPreparation = true
                let preparing = observe(ledger, "first-buffer-before-evaluation")
                #expect(preparing.chargedBytes == preparationBound)
                #expect(preparing.materializedBytes == 0)
                let remainder: UInt64 = 4096
                let used = preparing.usage.activeBytes + preparing.usage.cacheBytes
                let cap = used + preparationBound + remainder
                #expect(ledger.updatePolicy(.init(epoch: 1, capBytes: cap, reserveBytes: 0)))
                #expect(throws: ProcessMemoryLedger.Refusal.insufficientCapacity) {
                    try competitor.replaceCharge(remainder + 1)
                }
                #expect(competitor.snapshot()?.chargedBytes == 0)
                try competitor.replaceCharge(remainder)
                let exact = observe(ledger, "preparation-competing-owner-exact-fit")
                #expect(exact.remainingBytes == 0 && exact.commitmentDebtBytes == 0)
                #expect(exact.usage.activeBytes + exact.usage.cacheBytes
                    + exact.unmaterializedBytes == cap)
                try competitor.replaceCharge(0)
                #expect(ledger.updatePolicy(.init(epoch: 2, capBytes: .max, reserveBytes: 0)))
            }
            try withError { eval(array) }
        }
        let rows = try backend.makeSequenceState(
            layerKinds: kinds, promptLength: 17, maxLength: 65)
        #expect(observedPreparation)
        let evaluated = observe(ledger, "evaluated-native-pages")
        let physical = try backend.pool.groups.values.reduce(UInt64(0)) { total, group in
            try group.segments.values.reduce(total) { sum, segment in
                let observed = try segment.storage.evaluatedBufferInfo()
                let info = try #require(observed)
                return sum + UInt64(info.allocatedBytes)
            }
        }
        #expect(physical > 0 && physical <= preparationBound)
        #expect(UInt64(backend.pool.bytesMaterialized) == physical)
        #expect(evaluated.chargedBytes == physical)
        print("native-footprint preparation_bound=\(preparationBound) actual_buffers=\(physical) "
            + "returned_allowance=\(preparationBound - physical)")
        #expect(evaluated.materializedBytes == physical)
        #expect(evaluated.chargedBytes == UInt64(admission.bytesReserved))
        #expect(evaluated.usage.activeBytes >= physical)

        // M comes exclusively from native evaluated segment ownership. U is
        // always the real coherent allocator sample, never an allocation delta.
        let remainder: UInt64 = 4096
        let used = evaluated.usage.activeBytes + evaluated.usage.cacheBytes
        let cap = used + evaluated.unmaterializedBytes + remainder
        #expect(ledger.updatePolicy(.init(epoch: 3, capBytes: cap, reserveBytes: 0)))
        #expect(throws: ProcessMemoryLedger.Refusal.insufficientCapacity) {
            try competitor.replaceCharge(remainder + 1)
        }
        #expect(competitor.snapshot()?.chargedBytes == 0)
        try competitor.replaceCharge(remainder)
        let exact = observe(ledger, "competing-owner-exact-fit")
        #expect(exact.remainingBytes == 0)
        #expect(exact.usage.activeBytes + exact.usage.cacheBytes
                + exact.unmaterializedBytes == cap)
        #expect(exact.usage.activeBytes + exact.usage.cacheBytes
                + exact.chargedBytes > cap)
        #expect(throws: ProcessMemoryLedger.Refusal.insufficientCapacity) {
            try competitor.replaceCharge(remainder + 1)
        }
        try competitor.replaceCharge(0)

        let group = backend.pool.group(backend.pool.groupKey(forLayer: 0))
        var alias: MLXArray? = try #require(group.segments.values.first?.storage)
        weak var weakAlias = alias
        let aliasLogicalBytes = try #require(alias).nbytes
        let observedAlias = try alias?.evaluatedBufferInfo()
        let aliasInfo = try #require(observedAlias)
        let aliasBytes = UInt64(aliasInfo.allocatedBytes)
        #expect(aliasBytes >= UInt64(aliasLogicalBytes))
        print("native-footprint retained_alias_logical=\(aliasLogicalBytes) "
            + "retained_alias_allocated=\(aliasBytes)")
        admission.closeProcessMemoryOwner()
        let closing = observe(ledger, "native-owner-closing")
        #expect(owner.snapshot()?.closing == true)
        #expect(closing.chargedBytes == evaluated.chargedBytes)
        #expect(closing.materializedBytes == physical)
        #expect(throws: CBv2KVError.self) {
            try admission.reserve(id: .init(2), additionalTokens: 8192)
        }
        #expect(UInt64(admission.bytesReserved) == closing.chargedBytes)

        backend.release(rows)
        let uncovered = observe(ledger, "pool-released-alias-retained")
        #expect(uncovered.materializedBytes == 0)
        #expect(uncovered.chargedBytes > 0)
        #expect(weakAlias != nil)
        admission.releaseAll(id: request)
        #expect(owner.snapshot() == nil)
        #expect(throws: ProcessMemoryLedger.Refusal.unknownOwner) {
            try owner.replaceCharge(0)
        }
        // Native repeated empty retirement must not call the removed generation.
        backend.pool.physicalLease?.close()
        backend.pool.physicalLease?.close()
        owner.retire()
        Memory.clearCache()
        let retained = observe(ledger, "charge-retired-alias-retained")
        #expect(retained.chargedBytes == 0 && retained.materializedBytes == 0)
        #expect(retained.usage.activeBytes >= aliasBytes)
        #expect(try #require(alias).nbytes == aliasLogicalBytes)

        let retainedUsed = retained.usage.activeBytes + retained.usage.cacheBytes
        #expect(ledger.updatePolicy(.init(
            epoch: 4, capBytes: retainedUsed + remainder, reserveBytes: 0)))
        try competitor.replaceCharge(remainder)
        #expect(throws: ProcessMemoryLedger.Refusal.insufficientCapacity) {
            try competitor.replaceCharge(remainder + 1)
        }
        withExtendedLifetime(alias) {}
        alias = nil
        #expect(weakAlias == nil)
        Memory.clearCache()
        let drained = observe(ledger, "last-array-alias-drained")
        #expect(drained.usage.activeBytes + aliasBytes <= retained.usage.activeBytes)
        #expect(drained.remainingBytes >= aliasBytes)
        try competitor.replaceCharge(remainder + aliasBytes)
        observe(ledger, "competitor-reuses-drained-capacity")
        try competitor.replaceCharge(0)
        competitor.retire()
        #expect(observe(ledger, "all-owners-retired").ownerCount == 0)
    }

    @Test func emptyNativePoolTeardownUsesActualRetiredAdapter() throws {
        let ledger = ledger()
        let owner = EngineProcessMemoryOwner(ledger: ledger)
        do {
            let (backend, admission, _) = try fixture(owner)
            admission.closeProcessMemoryOwner()
            #expect(owner.snapshot() == nil)
            backend.pool.physicalLease?.close()
            backend.pool.physicalLease?.close()
        }
        owner.retire()
        #expect(throws: ProcessMemoryLedger.Refusal.unknownOwner) {
            try owner.replaceCharge(0)
        }
        #expect(observe(ledger, "empty-native-owner-retired").ownerCount == 0)
    }
}
