import Foundation
import MLX
import MLXLMCommon
import ProviderCoreFoundation
import Testing

@testable import ProviderCore

struct ServingQualificationCompetitor: Codable, Sendable {
    let modelID: String
    let modelPath: String
    let artifactSHA256: String
    let promptTokens: Int
    let outputTokens: Int
    let requireInlineMTP: Bool
}

/// Both real production factories share one physical-memory ledger and one
/// service allowance. Each grant is a disjoint part of the combined budget;
/// loading the second engine never duplicates the first engine's headroom.
final class ServingQualificationSharedFixture: @unchecked Sendable {
    let target: ServingQualificationFixture
    let competitor: ServingQualificationFixture
    let budget: GlobalKVCacheBudget
    let memory: ServingQualificationMemoryEnvelope

    private init(target: ServingQualificationFixture, competitor: ServingQualificationFixture,
                 budget: GlobalKVCacheBudget, memory: ServingQualificationMemoryEnvelope) {
        self.target = target; self.competitor = competitor; self.budget = budget; self.memory = memory
    }

    static func load(_ job: ServingQualificationJob) async throws -> Self {
        let other = try #require(job.competitor)
        try #require(job.modelID != other.modelID && job.modelPath != other.modelPath)
        let competitorJob = ServingQualificationJob(modelID: other.modelID, modelPath: other.modelPath,
            artifactSHA256: other.artifactSHA256, outputPath: job.outputPath,
            promptLengths: [other.promptTokens], outputTokens: other.outputTokens, width: 1,
            schedulerMaxConcurrentRequests: job.schedulerMaxConcurrentRequests ?? 4,
            servingPolicy: true, iterations: job.iterations, mixedPrefillTokenCap: nil,
            staggerMilliseconds: 0, reused: false, toolHistory: false,
            partition: job.partition, runID: job.runID + "-competitor", kvBackend: job.kvBackend)
        func completeLoadEstimate(_ item: ServingQualificationJob) throws -> UInt64 {
            let info = try #require(ModelScanner.parseModelInfo(
                snapshotDir: URL(fileURLWithPath: item.modelPath), modelName: item.modelID))
            let estimate = ProviderLoop.pendingLoadReservationBytes(
                estimatedWeightsGb: info.estimatedMemoryGb, extraWeightBytes: 0)
            try #require(estimate > 0 && estimate < UInt64.max)
            return estimate
        }
        let targetLoad = try completeLoadEstimate(job)
        let competitorLoad = try completeLoadEstimate(competitorJob)
        let (combinedLoad, overflow) = targetLoad.addingReportingOverflow(competitorLoad)
        try #require(!overflow)
        let reserve = UnifiedMemoryCap.resolvedActivationReserveBytes(modelIDs: [job.modelID, other.modelID])
        let combinedKV = UnifiedMemoryCap.kvBudgetBytes(residentWeightBytes: combinedLoad,
            activationReserveBytes: reserve, configReserveBytes: 0)
        // A bounded supplemental workload needs no full-device per-engine
        // pool. The shared runtime ledger still applies every real load/KV gate.
        let perEngineGrant = min(combinedKV / 2, 8 * 1_073_741_824)
        try #require(perEngineGrant >= UnifiedMemoryCap.minimumLoadKVBytes)
        let budget = GlobalKVCacheBudget(activationReserveBytes: reserve)
        let target = try await loadMember(job, budget: budget, loadBytes: targetLoad,
            grant: perEngineGrant, reserve: reserve, requireInlineMTP: true)
        do {
            let competitor = try await loadMember(competitorJob, budget: budget, loadBytes: competitorLoad,
                grant: perEngineGrant, reserve: reserve, requireInlineMTP: other.requireInlineMTP)
            // Runtime registration normally installs this shared interval
            // tracker. Direct production factory construction must do the
            // same before either engine submits its first warmup request.
            let activity = EngineMeasurementActivity()
            await target.bundle.bridge.setMeasurementActivity(activity)
            await competitor.bundle.bridge.setMeasurementActivity(activity)
            let envelope = ServingQualificationMemoryEnvelope(
                physicalBytes: ProcessInfo.processInfo.physicalMemory,
                hardCapBytes: UnifiedMemoryCap.hardCapBytes(), activationReserveBytes: reserve,
                targetCompleteLoadBytes: targetLoad, competitorCompleteLoadBytes: competitorLoad,
                combinedKVUpperBoundBytes: combinedKV, perEngineKVGrantUpperBoundBytes: perEngineGrant,
                liveKVHeadroomBytes: KVHeadroomProbe.measuredLiveKVHeadroomBytes(activationReserveBytes: reserve))
            return Self(target: target, competitor: competitor, budget: budget, memory: envelope)
        } catch {
            await target.retire()
            throw error
        }
    }

    private static func loadMember(_ job: ServingQualificationJob, budget: GlobalKVCacheBudget,
                                   loadBytes: UInt64, grant: UInt64, reserve: UInt64,
                                   requireInlineMTP: Bool) async throws -> ServingQualificationFixture {
        let preparation = budget.serviceBudget.beginUnboundedActivity()
        defer { preparation.finish() }
        let lease = try #require(await budget.claimPendingLoad(
            requestID: "qualification-load-" + UUID().uuidString, weightBytes: loadBytes))
        var fixture: ServingQualificationFixture?
        do {
            try #require(await budget.recheckPendingLoad(lease))
            let loaded = try await ServingQualificationFixture.load(job, sharedBudget: budget,
                kvGrantUpperBound: grant, activationReserveBytes: reserve, requireInlineMTP: requireInlineMTP)
            fixture = loaded
            MLX.Stream().synchronize()
            MLX.Memory.clearCache()
            let backendKind = await loaded.bundle.bridge.kvBackendKind
            let poolBytes = await loaded.bundle.bridge.kvBackendPoolBytes()
            try #require(KVHeadroomProbe.postBuildServeable(
                kvBackendKind: backendKind, pagedPoolBytes: poolBytes, activationReserveBytes: reserve))
            try #require(await budget.finishPendingLoad(lease))
            return loaded
        } catch {
            if let fixture { await fixture.retire() }
            MLX.Stream().synchronize()
            MLX.Memory.clearCache()
            _ = await budget.finishPendingLoad(lease)
            throw error
        }
    }

    func retire() async {
        await competitor.retire()
        await target.retire()
    }
}

struct ServingQualificationMemoryEnvelope: Codable, Sendable {
    let physicalBytes: UInt64
    let hardCapBytes: UInt64
    let activationReserveBytes: UInt64
    let targetCompleteLoadBytes: UInt64
    let competitorCompleteLoadBytes: UInt64
    let combinedKVUpperBoundBytes: UInt64
    let perEngineKVGrantUpperBoundBytes: UInt64
    let liveKVHeadroomBytes: UInt64
}
