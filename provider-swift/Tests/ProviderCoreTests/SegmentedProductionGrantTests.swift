import Foundation
import MLX
import Testing

@testable import MLXLMCommon
@testable import ProviderCore

@Suite("Segmented production grants: configuration and synthetic envelopes", .serialized)
struct SegmentedProductionGrantTests {
    private let gib: UInt64 = 1 << 30

    @Test func qwenB1NoLongerFailsTheEagerPoolMinimumAndStartsWithoutPages() throws {
        for fleet in try SegmentedFleetGeometry.all().prefix(2) {
            // Before: useful-context cap 32768 * 20480 = 640 MiB was below
            // the provider's 1 GiB eager-pool minimum even with a 12 GiB grant.
            #expect(32_768 * fleet.resliceSlot.fp16KVBytesPerToken == 640 << 20)
            let backend = try EngineV2Factory.makeSegmentedPagedBackend(
                admittedGrantBytes: 12 << 30, layerKinds: fleet.kinds, layerDTypes: fleet.dtypes,
                schedulerConfig: .init(maxConcurrentRequests: 1, soloPrefillStripeTokens: fleet.maximumPrefillChunk),
                maxContextLength: fleet.context,
                maxBufferLength: 256 << 20)
            let storage = try #require(backend.pool.segmentStorageSnapshot)
            #expect(storage.grantBytes == 12 << 30)
            #expect(storage.committedBytes == 0 && storage.segmentCount == 0 && storage.addressPages == 0)
            let policy = try #require(Memory.allocationFootprintPolicy())
            let admission = AdmissionV2(layerKinds: fleet.kinds, bytesCapacity: backend.bytesCapacity,
                config: try fleet.admissionConfig(policy: policy), residency: backend.kvResidency)
            try admission.reserve(id: .init(1), additionalTokens: 32_768)
            #expect(admission.bytesReserved > 640 << 20) // normal recurrent + MTP state is included
            admission.releaseAll(id: .init(1))
        }
    }

    @Test func smallGrantAndLargeGrantUseSegmentBoundsRatherThanWholeGrantBuffers() throws {
        let all = try SegmentedFleetGeometry.all()
        let fleet = try #require(all.last)
        for grant in [256 << 20, 24 << 30] {
            let backend = try EngineV2Factory.makeSegmentedPagedBackend(
                admittedGrantBytes: grant, layerKinds: fleet.kinds, layerDTypes: fleet.dtypes,
                schedulerConfig: .init(maxConcurrentRequests: 4, soloPrefillStripeTokens: fleet.maximumPrefillChunk),
                maxContextLength: fleet.context,
                maxBufferLength: 128 << 20)
            #expect(backend.bytesCapacity == grant)
            #expect(backend.pool.bytesMaterialized == 0)
            let admission = AdmissionV2(layerKinds: fleet.kinds, bytesCapacity: grant,
                config: .init(watermarkFraction: 0, layerElementBytes: fleet.dtypes.map(\.size)),
                residency: backend.kvResidency)
            try admission.reserve(id: .init(1), additionalTokens: 17)
            #expect(admission.bytesReserved < grant)
            admission.releaseAll(id: .init(1))
        }
        // A real per-segment buffer limit still refuses even with ample grant.
        #expect(throws: CBv2KVError.self) {
            try EngineV2Factory.makeSegmentedPagedBackend(
                admittedGrantBytes: 24 << 30, layerKinds: fleet.kinds, layerDTypes: fleet.dtypes,
                schedulerConfig: .init(), maxContextLength: fleet.context, maxBufferLength: 1)
        }
    }

    @Test func exactFleetRowsUseNativeDtypesWindowRingsAndNormalQwenMTP() throws {
        let policy = try #require(Memory.allocationFootprintPolicy())
        for fleet in try SegmentedFleetGeometry.all() {
            let config = try fleet.admissionConfig(policy: policy)
            let residency = CBv2PagedKVResidency(config: fleet.poolConfig(grant: 32 << 30))
            let admission = AdmissionV2(layerKinds: fleet.kinds, bytesCapacity: 32 << 30,
                config: config, residency: residency)
            let tokens = 32_768
            let target = try fleet.kinds.enumerated().reduce(0) { total, pair in
                let (index, kind) = pair
                let rows = try #require(residency.residentRows(layer: kind, tokens: tokens))
                return total + rows * 2 * kind.kvHeads * kind.headDim * fleet.dtypes[index].size
            }
            let auxiliary: Int
            if let projection = config.auxiliaryAllocationProjection {
                let projected = projection.bytes(forTokens: tokens)
                auxiliary = try #require(projected)
            } else {
                auxiliary = 0
            }
            #expect(admission.allocatedBytes(forTokens: tokens) == target + config.fixedBytesPerRequest + auxiliary)
            if fleet.id == "gpt-oss-20b" {
                #expect(admission.fullKVBytesPerToken == 49_152)
                #expect(target > 32_768 * 24_576) // full KV alone is twice old fp16 cost
            }
            if fleet.id == "gemma-4-26b" {
                let window = try #require(fleet.kinds.first)
                let ring = try #require(residency.residentRows(layer: window, tokens: tokens))
                #expect(ring > 1024 && ring < tokens)
                #expect(config.auxiliaryBytesPerToken == 0 && config.fixedBytesPerRequest == 0)
            }
            if let qwen = fleet.qwen {
                let logicalGeneration = try qwen.cbv2RecurrentStateSpec().fixedBytesPerRequest()
                #expect(config.fixedBytesPerRequest >= logicalGeneration * 4)
                #expect(auxiliary > tokens * config.auxiliaryBytesPerToken)
            }
        }
    }

    @Test func fleetB1B2B4Across36_64_128GiBPreservesExactProcessAndSlotBoundaries() throws {
        let policy = try #require(Memory.allocationFootprintPolicy())
        for fleet in try SegmentedFleetGeometry.all() {
            for physicalGiB in [36, 64, 128] {
                let physical = UInt64(physicalGiB) * gib
                // Deliberately synthetic resident weight and OS observations.
                // This tests policy composition, never model fit on a machine.
                let weights = 18 * gib
                let activation = UnifiedMemoryCap.activationFloorBytes(forModelIDs: [fleet.id])
                let cap = min(UnifiedMemoryCap.hardCapBytes(physicalBytes: physical, capFraction: 0.90), physical - 4 * gib)
                let budget = UnifiedMemoryCap.kvBudgetBytes(physicalBytes: physical,
                    residentWeightBytes: weights, activationReserveBytes: activation,
                    configReserveBytes: 4 * gib, capFraction: 0.90)
                let grants = EngineV2KVSizing.resliceGrants(existing: [], newcomer: fleet.resliceSlot,
                    fleetKVBudgetBytes: budget)
                let grant = try #require(grants[fleet.id])
                #expect(UInt64(grant) == cap - weights - activation)
                for batch in [1, 2, 4] {
                    let process = ProcessMemoryLedger(policy: .init(epoch: 0, capBytes: cap, reserveBytes: activation),
                        readUsage: { .init(activeBytes: weights, cacheBytes: 0, systemAvailableBytes: physical - weights) })
                    let owner = EngineProcessMemoryOwner(ledger: process)
                    let admission = AdmissionV2(layerKinds: fleet.kinds, bytesCapacity: grant,
                        config: try fleet.admissionConfig(policy: policy),
                        residency: CBv2PagedKVResidency(config: fleet.poolConfig(grant: grant)), processMemoryOwner: owner)
                    let row = admission.allocatedBytes(forTokens: 4096)
                    #expect(row > 0 && row < Int.max / batch)
                    let exact = row * batch
                    admission.updateBytesCapacity(min(exact - 1, grant))
                    let acceptedRows = min(batch - 1, grant / row)
                    for i in 0..<acceptedRows {
                        try admission.reserve(id: .init(UInt64(i + 1)), additionalTokens: 4096)
                    }
                    #expect(throws: CBv2KVError.self) {
                        try admission.reserve(id: .init(UInt64(acceptedRows + 1)), additionalTokens: 4096)
                    }
                    admission.updateBytesCapacity(min(exact, grant))
                    if exact <= grant {
                        try admission.reserve(id: .init(UInt64(batch)), additionalTokens: 4096)
                        #expect(admission.bytesReserved == exact)
                        #expect(process.snapshot().chargedBytes == UInt64(exact))
                        #expect(process.snapshot().materializedBytes == 0) // no synthetic M credit
                        let competitor = EngineProcessMemoryOwner(ledger: process)
                        try competitor.replaceCharge(budget - UInt64(exact))
                        #expect(process.snapshot().remainingBytes == 0)
                        admission.updateBytesCapacity(grant)
                        #expect(throws: CBv2KVError.self) { try admission.reserve(id: .init(99), additionalTokens: 1) }
                        try competitor.replaceCharge(0)
                        competitor.retire()
                    }
                    for i in 1...batch { admission.releaseAll(id: .init(UInt64(i))) }
                    admission.closeProcessMemoryOwner()
                    #expect(process.snapshot().chargedBytes == 0)
                }
            }
        }
    }
}

extension SegmentedProductionGrantTests {
    @Test func coResidentFairSharesKeepOperatorActivationAndServiceabilityPolicy() throws {
        let fleet = try SegmentedFleetGeometry.all()
        for physicalGiB in [36, 64, 128] {
            let physical = UInt64(physicalGiB) * gib
            for newcomer in fleet.dropFirst() {
                let first = fleet[0]
                let activation = UnifiedMemoryCap.activationFloorBytes(forModelIDs: [first.id, newcomer.id])
                #expect(activation == 11 * gib / 2)
                func budget(weights: UInt64, operatorReserve: UInt64 = 4 << 30) -> UInt64 {
                    UnifiedMemoryCap.kvBudgetBytes(physicalBytes: physical, residentWeightBytes: weights,
                        activationReserveBytes: activation, configReserveBytes: operatorReserve, capFraction: 0.90)
                }
                let alone = EngineV2KVSizing.resliceGrants(existing: [], newcomer: first.resliceSlot,
                    fleetKVBudgetBytes: budget(weights: 12 * gib))
                let together = EngineV2KVSizing.resliceGrants(existing: [first.resliceSlot],
                    newcomer: newcomer.resliceSlot, fleetKVBudgetBytes: budget(weights: 20 * gib))
                let firstShare = try #require(together[first.id])
                let secondShare = try #require(together[newcomer.id])
                #expect(UInt64(firstShare + secondShare) <= budget(weights: 20 * gib))
                #expect(firstShare < (alone[first.id] ?? 0))
                #expect(EngineV2KVSizing.resliceMeetsServiceabilityFloor(together))
                #expect(budget(weights: 20 * gib, operatorReserve: physical / 2) < budget(weights: 20 * gib))
                // The existing floor still refuses a load when every slot
                // cannot retain useful KV, even though segmented init is empty.
                let exhausted = EngineV2KVSizing.resliceGrants(existing: [first.resliceSlot],
                    newcomer: newcomer.resliceSlot,
                    fleetKVBudgetBytes: UnifiedMemoryCap.minimumLoadKVBytes)
                #expect(!EngineV2KVSizing.resliceMeetsServiceabilityFloor(exhausted))
                #expect(!UnifiedMemoryCap.loadIsServeable(
                    measuredLiveKVHeadroomBytes: UnifiedMemoryCap.minimumLoadKVBytes - 1))
                #expect(UnifiedMemoryCap.loadIsServeable(
                    measuredLiveKVHeadroomBytes: UnifiedMemoryCap.minimumLoadKVBytes))
                let restored = EngineV2KVSizing.resliceGrants(existing: [first.resliceSlot], newcomer: nil,
                    fleetKVBudgetBytes: budget(weights: 12 * gib))
                #expect(restored == alone)
            }
        }
        #expect(UnifiedMemoryCap.activationFloorBytes(forModelIDs: ["gpt-oss-20b"]) == 7 * gib / 2)
    }

    @Test func shrinkKeepsNativePhysicalChargeAndRejectsGrowthUntilRetirement() throws {
        let policy = try #require(Memory.allocationFootprintPolicy())
        for fleet in try SegmentedFleetGeometry.all() {
            let process = ProcessMemoryLedger(policy: .init(epoch: 0, capBytes: 32 << 30, reserveBytes: 0),
                readUsage: { .init(activeBytes: 0, cacheBytes: 0, systemAvailableBytes: .max) })
            let owner = EngineProcessMemoryOwner(ledger: process)
            let admission = AdmissionV2(layerKinds: fleet.kinds, bytesCapacity: 16 << 30,
                config: try fleet.admissionConfig(policy: policy),
                residency: CBv2PagedKVResidency(config: fleet.poolConfig(grant: 16 << 30)), processMemoryOwner: owner)
            let floor = admission.bindBackendPhysicalFloor(initialBytes: 0)
            defer { floor.close() }
            try admission.reserve(id: .init(1), additionalTokens: 4096)
            // This is a synthetic native ownership obligation, not a claim
            // that MLX allocated these bytes: M deliberately stays zero.
            let physical = admission.bytesReserved * 2
            try floor.resize(to: physical)
            let held = admission.bytesReserved
            admission.updateBytesCapacity(held / 2)
            #expect(admission.bytesReserved == held)
            #expect(process.snapshot().chargedBytes == UInt64(held))
            #expect(process.snapshot().materializedBytes == 0)
            #expect(throws: CBv2KVError.self) { try admission.reserveTransient(bytes: 1) }
            #expect(throws: CBv2KVError.self) { try floor.resize(to: physical + 1) }
            admission.releaseAll(id: .init(1))
            #expect(admission.bytesReserved == physical)
            floor.release(to: 0)
            #expect(process.snapshot().chargedBytes == 0)
            admission.updateBytesCapacity(16 << 30)
            try admission.reserve(id: .init(2), additionalTokens: 4096)
            admission.releaseAll(id: .init(2))
            admission.closeProcessMemoryOwner()
            #expect(process.snapshot().ownerCount == 0)
        }
    }

    @Test func borrowedStorageAndInvalidGeometryKeepNativeSafetyChecks() throws {
        let owner = CBv2LayerKind(attention: .full, headDim: 64, kvHeads: 2, queryHeads: 4)
        let borrower = CBv2LayerKind(attention: .full, sharesKVWithLayer: 0,
                                    headDim: 64, kvHeads: 2, queryHeads: 4)
        let config = PagedKVPoolConfig(capacityBytes: 1 << 30, maxBufferLength: 128 << 20,
                                      segmentSizeBytes: 64 << 20, layerDTypes: [.bfloat16, .bfloat16])
        let admission = AdmissionV2(layerKinds: [owner, borrower], bytesCapacity: 1 << 30,
            config: .init(watermarkFraction: 0), residency: CBv2PagedKVResidency(config: config))
        #expect(admission.allocatedBytes(forTokens: 17) == 32 * 2 * 2 * 64 * 2)
        let backend = try EngineV2Factory.makeSegmentedPagedBackend(
            admittedGrantBytes: 1 << 30, layerKinds: [owner, borrower], layerDTypes: [.bfloat16, .bfloat16],
            schedulerConfig: .init(), maxContextLength: 131_072, maxBufferLength: 128 << 20)
        #expect(backend.pool.bytesMaterialized == 0)
        #expect(throws: CBv2KVError.self) {
            try EngineV2Factory.makeSegmentedPagedBackend(
                admittedGrantBytes: 1 << 30, layerKinds: [owner, borrower], layerDTypes: [.bfloat16, .float32],
                schedulerConfig: .init(), maxContextLength: 131_072, maxBufferLength: 128 << 20)
        }
        let overflow = CBv2PagedKVResidency(config: config)
        #expect(overflow.residentRows(layer: owner, tokens: Int.max) == nil)
        let badWindow = CBv2LayerKind(attention: .slidingWindow(Int.max), headDim: 64, kvHeads: 2, queryHeads: 4)
        #expect(overflow.residentRows(layer: badWindow, tokens: 1) == nil)
    }
}

extension SegmentedProductionGrantTests {
    @Test func abundantSlotGrantCannotBypassLiveOSAndActivationHeadroom() throws {
        let policy = try #require(Memory.allocationFootprintPolicy())
        for fleet in try SegmentedFleetGeometry.all() {
            let config = try fleet.admissionConfig(policy: policy)
            let residency = CBv2PagedKVResidency(config: fleet.poolConfig(grant: 12 << 30))
            let quote = AdmissionV2(layerKinds: fleet.kinds, bytesCapacity: 12 << 30,
                                    config: config, residency: residency)
            let row = quote.allocatedBytes(forTokens: 4096)
            let activation = UnifiedMemoryCap.activationFloorBytes(forModelIDs: [fleet.id])
            let available = activation + UInt64(row) - 1
            let process = ProcessMemoryLedger(policy: .init(epoch: 0, capBytes: 64 << 30, reserveBytes: activation),
                readUsage: { .init(activeBytes: 18 << 30, cacheBytes: 0, systemAvailableBytes: available) })
            let owner = EngineProcessMemoryOwner(ledger: process)
            let admission = AdmissionV2(layerKinds: fleet.kinds, bytesCapacity: 12 << 30,
                config: config, residency: residency, processMemoryOwner: owner)
            #expect(throws: CBv2KVError.self) { try admission.reserve(id: .init(1), additionalTokens: 4096) }
            #expect(admission.bytesReserved == 0 && process.snapshot().chargedBytes == 0)
            admission.closeProcessMemoryOwner()
        }
    }
}
