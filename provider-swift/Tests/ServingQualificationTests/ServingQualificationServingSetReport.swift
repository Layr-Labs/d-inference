import Foundation
import MLXLMCommon

@testable import ProviderCore

struct ServingQualificationMemberIdentity: Codable, Sendable {
    let modelID: String
    let artifactSHA256: String
    let promptContractID: String
    let actualKVBackend: String
    let runtime: DeadlineRuntimeConfiguration?
    let mtp: ServingMTPConfiguration?
    let reviewedDeadlineProfileID: String?

    static func capture(_ fixture: ServingQualificationFixture) async -> Self {
        .init(modelID: fixture.job.modelID, artifactSHA256: fixture.job.artifactSHA256,
            promptContractID: fixture.promptContractID,
            actualKVBackend: await fixture.bundle.bridge.kvBackendKind.rawValue,
            runtime: fixture.bundle.bridge.deadlineRuntimeConfiguration, mtp: fixture.mtp,
            reviewedDeadlineProfileID: fixture.bundle.bridge.deadlineProfile?.id)
    }
}

struct ServingQualificationEngineCheckpoint: Codable, Sendable {
    let activeRequests: Int
    let waitingRequests: Int
    let activeTokens: Int
    let kvBytesReserved: Int
    let kvBytesCapacity: Int
    let stepsExecuted: Int
    let decodeRowsTotal: UInt64
    let performanceMeasurements: PerformanceMeasurements?

    static func capture(_ fixture: ServingQualificationFixture) async -> Self {
        let capacity = await fixture.bundle.bridge.capacitySnapshot()
        let measurements = await fixture.bundle.bridge.backendSlotCapacity().performanceMeasurements
        return .init(activeRequests: capacity.activeRequests, waitingRequests: capacity.waitingRequests,
            activeTokens: capacity.activeTokens, kvBytesReserved: capacity.kvBytesReserved,
            kvBytesCapacity: capacity.kvBytesCapacity, stepsExecuted: capacity.stepsExecuted,
            decodeRowsTotal: capacity.decodeRowsTotal, performanceMeasurements: measurements)
    }
    var retired: Bool { activeRequests == 0 && waitingRequests == 0 && activeTokens == 0 && kvBytesReserved == 0 }
    var otherModelPrefillSamples: Int64 {
        performanceMeasurements?.workloadBuckets.filter { $0.phase == "prefill" && $0.otherModelActivity }
            .reduce(0) { $0 + $1.observation.sampleCount } ?? 0
    }
}

/// Engine counters are asynchronous observations, not an invented cross-engine
/// atomic snapshot. Ledger fractions/work are captured together under its lock.
/// Common host-clock offsets bracket every observation to expose that interval.
struct ServingQualificationServingSetCheckpoint: Codable, Sendable {
    let phase: String
    let startedMs: Double
    let finishedMs: Double
    let target: ServingQualificationEngineCheckpoint
    let competitor: ServingQualificationEngineCheckpoint
    let serviceUsedFraction: Double
    let targetWork: DeadlineWork?
    let competitorWork: DeadlineWork?
    let reservedMemoryBytes: UInt64

    static func capture(_ pair: ServingQualificationSharedFixture, phase: String,
                        anchor: ContinuousClock.Instant) async -> Self {
        let start = ServingQualificationFixture.milliseconds(anchor.duration(to: .now))
        let target = await ServingQualificationEngineCheckpoint.capture(pair.target)
        let competitor = await ServingQualificationEngineCheckpoint.capture(pair.competitor)
        let ledger = pair.budget.serviceBudget.snapshot(slotEpochs: [
            pair.target.job.modelID: target.performanceMeasurements?.epoch ?? "unknown",
            pair.competitor.job.modelID: competitor.performanceMeasurements?.epoch ?? "unknown"])
        let reserved = await pair.budget.outstandingReservedBytes()
        return .init(phase: phase, startedMs: start,
            finishedMs: ServingQualificationFixture.milliseconds(anchor.duration(to: .now)),
            target: target, competitor: competitor, serviceUsedFraction: ledger.usedFraction,
            targetWork: ledger.deadlineWorkByModel[pair.target.job.modelID],
            competitorWork: ledger.deadlineWorkByModel[pair.competitor.job.modelID], reservedMemoryBytes: reserved)
    }
    var retired: Bool {
        target.retired && competitor.retired && serviceUsedFraction == 0 && reservedMemoryBytes == 0
            && targetWork?.requestCount == 0 && competitorWork?.requestCount == 0
    }
}

struct ServingQualificationServingSetTrial: Codable, Sendable {
    let iteration: Int
    let promptTarget: Int
    let target: ServingQualificationRow
    let competitor: ServingQualificationRow
    let checkpoints: [ServingQualificationServingSetCheckpoint]
    let targetForwardShapes: CBv2ForwardShapeSnapshot
    let competitorForwardShapes: CBv2ForwardShapeSnapshot
    let overlapProven: Bool
    let competitorCancelled: Bool
    let retired: Bool
    let peakMemoryBytes: Int
    let thermalState: Int
    let lowPowerMode: Bool
    var passed: Bool
    var posture: QualificationTrialPostureReceipt? = nil
}

struct ServingQualificationServingSetReport: Codable, Sendable {
    let buildIdentity: ServingQualificationBuildIdentity
    let schemaVersion: Int
    let kind: String
    let job: ServingQualificationJob
    let providerVersion: String
    let runtimeRevision: String
    let chipName: String
    let gpuCores: Int
    let memory: ServingQualificationMemoryEnvelope
    let target: ServingQualificationMemberIdentity
    let competitor: ServingQualificationMemberIdentity
    let trials: [ServingQualificationServingSetTrial]
    let cooldowns: [QualificationCooldownReceipt]
    let complete: Bool
    let passed: Bool
    // Supplemental evidence never becomes an other_model calibration merely
    // because two engines ran. Both identities and bounded work need review.
    let qualified: Bool
}
