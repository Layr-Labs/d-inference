import Foundation
import MLXLMCommon
@testable import ProviderCore

struct ReleaseCoResidencyStreamResult: Codable, Sendable {
    var text = ""
    var completionTokens = 0
    var finishReason: String?
    var errors: [String] = []
}

actor ReleaseCoResidencyStreamProbe {
    private var result = ReleaseCoResidencyStreamResult()
    private var complete = false
    func consume(_ stream: AsyncStream<GenerationEvent>) async -> ReleaseCoResidencyStreamResult {
        for await event in stream {
            switch event {
            case .chunk(let text): result.text += text
            case .info(_, let count, _, let finish):
                result.completionTokens = count; result.finishReason = finish
            case .error(let message): result.errors.append(message)
            case .terminal(_, let message, _, let count):
                result.completionTokens = count; result.errors.append(message)
            }
        }
        complete = true
        return result
    }
    func hasOutput() -> Bool { !result.text.isEmpty }
    func completed() -> Bool { complete }
}

struct ReleaseCoResidencyObservation: Codable, Sendable {
    struct Slot: Codable, Sendable {
        let modelID: String
        let activeIDs: [String]
        let mtpActive: Bool
        let ssdEnabled: Bool
        let values: [String: UInt64]
    }
    let stage: String
    let uptimeNanoseconds: UInt64
    let fleetBudget: UInt64
    let grantSum: UInt64
    let ledger: [String: UInt64]
    let slots: [Slot]

    static func capture(stage: String, loop: ProviderLoop, bridges: [String: EngineV2Bridge],
                        reserveGiB: UInt64) async throws -> Self {
        var slots: [Slot] = []
        var weights: UInt64 = 0
        var grants: UInt64 = 0
        for modelID in bridges.keys.sorted() {
            guard let bridge = bridges[modelID], let sizing = await loop.slotSizingForTesting(modelId: modelID),
                  let mtp = await loop.slotMTPStatusForTesting(modelId: modelID) else {
                throw ReleaseCoResidencyFailure("loaded slot identity missing")
            }
            let c = await bridge.capacitySnapshot()
            let grant = await bridge.engineKVBytesCapacity()
            guard let storage = c.pagedStorage else { throw ReleaseCoResidencyFailure("segmented storage missing") }
            try ReleaseCoResidencyFixture.require(await bridge.kvBackendKind == .paged, "actual paged backend required")
            try ReleaseCoResidencyFixture.require(await bridge.pagedPoolResizeShortfall() == nil, "resize shortfall")
            try ReleaseCoResidencyFixture.require(grant >= 0 && sizing.weightsBytes > 0, "invalid loaded sizing")
            weights += UInt64(sizing.weightsBytes); grants += UInt64(grant)
            let store = bridge.ssdHybridCheckpointStore
            let stats = store?.stats()
            let qwen = modelID == ReleaseCoResidencyFixture.modelIDs[0]
            try ReleaseCoResidencyFixture.require(mtp.active == qwen && (store != nil) == qwen,
                                                  "shipping MTP/cache policy differs")
            try ReleaseCoResidencyFixture.require(bridge.residentPrefixCacheEvidence == nil,
                                                  "resident retention must stay off")
            try ReleaseCoResidencyFixture.require(bridge.ssdPrefixCache == nil, "unexpected raw SSD fallback")
            if let store { try ReleaseCoResidencyFixture.require(store.usesEphemeralKey, "isolated test key required") }
            func u(_ x: Int) throws -> UInt64 {
                try ReleaseCoResidencyFixture.require(x >= 0, "negative native/SSD capacity counter")
                return UInt64(x)
            }
            var backing: UInt64 = 0
            for bytes in [storage.reservedPageBytes, storage.poisonBytes, storage.slackBytes, storage.allocatorPaddingBytes] {
                let addition = try backing.addingReportingOverflow(u(bytes))
                try ReleaseCoResidencyFixture.require(!addition.overflow, "paged backing counter overflow")
                backing = addition.partialValue
            }
            try ReleaseCoResidencyFixture.require(try u(storage.committedBytes) == backing,
                                                  "paged backing accounting differs")
            slots.append(Slot(modelID: modelID, activeIDs: await bridge._testActiveRequestIds(),
                mtpActive: mtp.active, ssdEnabled: store != nil, values: [
                    "weights": try u(sizing.weightsBytes), "assistantWeights": try u(sizing.auxiliaryWeightBytes),
                    "grant": try u(grant), "active": try u(c.activeRequests), "waiting": try u(c.waitingRequests),
                    "kvInUse": try u(c.kvBytesInUse), "kvReserved": try u(c.kvBytesReserved),
                    "backendCapacity": try u(c.kvBytesBackendCapacity), "steps": try u(c.stepsExecuted),
                    "committed": try u(storage.committedBytes), "livePages": try u(storage.livePageBytes),
                    "reservedPages": try u(storage.reservedPageBytes), "poison": try u(storage.poisonBytes),
                    "slack": try u(storage.slackBytes), "allocatorPadding": try u(storage.allocatorPaddingBytes),
                    "allocationFailures": storage.allocationFailures,
                    "admissionRefusals": storage.admissionRefusals, "grantRefusals": storage.grantRefusals,
                    "stageReadBytes": try u(stats?.stageReadBytes ?? 0),
                    "stageConsumptions": try u(stats?.stageConsumptions ?? 0),
                    "consumedPrefixTokens": try u(stats?.consumedPrefixTokens ?? 0),
                    "staging": try u(stats?.stagedBytesInUse ?? 0), "writeHost": try u(stats?.writeHostBytesInUse ?? 0),
                ]))
        }
        let budget = await loop.kvBudgetForTesting()
        let sample = budget.memoryHeadroomSnapshot()
        try ReleaseCoResidencyFixture.require(sample.materializedBytes <= sample.totalOwnedBytes
            && sample.unmaterializedCommittedBytes == sample.totalOwnedBytes - sample.materializedBytes,
            "process commitment/materialization accounting differs")
        try ReleaseCoResidencyFixture.require(sample.ownerCount >= 0 && sample.closingOwnerCount >= 0,
                                              "negative process owner counter")
        let fleet = UnifiedMemoryCap.kvBudgetBytes(residentWeightBytes: weights,
            activationReserveBytes: sample.activationReserveBytes, configReserveBytes: reserveGiB * (1 << 30))
        try ReleaseCoResidencyFixture.require(grants <= fleet, "sum of admitted grants exceeds fleet budget")
        return Self(stage: stage, uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
            fleetBudget: fleet, grantSum: grants, ledger: [
                "physical": sample.totalBytes, "cap": sample.capBytes, "epoch": sample.policyEpoch,
                "reserve": sample.activationReserveBytes, "active": sample.activeBytes, "cache": sample.cacheBytes,
                "systemAvailable": sample.systemAvailableBytes, "owned": sample.totalOwnedBytes,
                "materialized": sample.materializedBytes, "unmaterialized": sample.unmaterializedCommittedBytes,
                "debt": sample.commitmentDebtBytes, "remaining": sample.runtimeRemainingBytes,
                "owners": UInt64(sample.ownerCount), "closingOwners": UInt64(sample.closingOwnerCount),
            ], slots: slots)
    }
}
