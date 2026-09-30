import Foundation
import MLX
@_spi(Benchmarking) import MLXLMCommon
import Testing

@testable import ProviderCore

@Suite("Dedicated competing-model serving receipts", .serialized)
struct ServingQualificationCompetingModelsTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_SERVING_QUALIFICATION_COMPETING"] == "supervised-v1",
                   "requires supervised exclusive hardware and two verified local artifacts"))
    func collectRealCompetingModelReceipts() async throws {
        let configPath = try #require(ProcessInfo.processInfo.environment["DARKBLOOM_SERVING_QUALIFICATION_JOB"])
        let job = try JSONDecoder().decode(ServingQualificationJob.self,
            from: Data(contentsOf: URL(fileURLWithPath: configPath)))
        let other = try #require(job.competitor)
        try #require(job.width == 1 && job.servingPolicy == true && !job.reused)
        try #require((1...20).contains(job.iterations) && job.promptLengths.count <= 8 && !job.promptLengths.isEmpty)
        try #require(job.schedulerMaxConcurrentRequests.map { (1...16).contains($0) } ?? true)
        try #require(job.promptLengths.allSatisfy { (256...32768).contains($0) })
        try #require((256...8192).contains(other.promptTokens) && (128...16384).contains(other.outputTokens))
        try #require((1...4096).contains(job.outputTokens) && job.staggerMilliseconds == 0)
        try #require(job.firstContentBudgetMilliseconds == nil && job.requireCalibratedAdmission != true,
                     "deadline activation is a separate isolated test; an unqualified contender must fall back")
        let buildIdentity = try ServingQualificationBuildIdentity.capture()
        let hardware = try HardwareDetector.detect()
        let pair = try await ServingQualificationSharedFixture.load(job)
        var trials: [ServingQualificationServingSetTrial] = []
        var cooldowns: [QualificationCooldownReceipt] = []
        do {
            let targetIdentity = await ServingQualificationMemberIdentity.capture(pair.target)
            let competitorIdentity = await ServingQualificationMemberIdentity.capture(pair.competitor)
            func write(complete: Bool) throws {
                let report = ServingQualificationServingSetReport(buildIdentity: buildIdentity, schemaVersion: 1,
                    kind: "competing_models_supplement", job: job, providerVersion: ProviderCore.version,
                    runtimeRevision: ServingPerformanceProfiles.runtimeRevision, chipName: hardware.chipName,
                    gpuCores: Int(hardware.gpuCores), memory: pair.memory,
                    target: targetIdentity, competitor: competitorIdentity, trials: trials, cooldowns: cooldowns, complete: complete,
                    passed: complete && !trials.isEmpty && trials.allSatisfy(\.passed), qualified: false)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                try encoder.encode(report).write(to: URL(fileURLWithPath: job.outputPath), options: .atomic)
            }
            try write(complete: false)
            for fixture in [pair.target, pair.competitor] {
                let warm = try fixture.request(targetTokens: fixture.job.toolHistory ? 2048 : 256,
                    nonce: (job.corpusSeed ?? job.runID) + "-warm-" + fixture.job.modelID)
                var warmRequest = warm.0
                warmRequest.maxTokens = 16
                let row = await fixture.collect(request: warmRequest, tokens: warm.1, id: "warmup")
                try #require(row.failure == nil && row.firstContentMs != nil)
                _ = try await fixture.waitForIdle()
            }
            for (index, prompt) in job.promptLengths.enumerated() {
                for iteration in 0..<job.iterations {
                    let ordinal = index * job.iterations + iteration
                    let cooldown = try await QualificationPostureGate.waitForNominal()
                    cooldowns.append(cooldown)
                    try write(complete: false)
                    try #require(cooldown.passed, "record recovery failure and stop before GPU work")
                    let monitor = QualificationPostureMonitor()
                    var trial: ServingQualificationServingSetTrial
                    do {
                        trial = try await pair.collectTrial(job: job, prompt: prompt, ordinal: ordinal)
                    } catch {
                        _ = await monitor.finish()
                        throw error
                    }
                    let posture = await monitor.finish()
                    trial.posture = posture
                    trial.passed = trial.passed && posture.isNominal
                    trials.append(trial)
                    try write(complete: false)
                    try #require(posture.isNominal, "a nonnominal trial invalidates and stops this whole cohort")
                    #expect(trial.passed, "retain failed overlap/accounting observations; never synthesize competing work")
                    print("SERVING_QUALIFICATION_COMPETING prompt=\(prompt) iteration=\(ordinal) overlap=\(trial.overlapProven) retired=\(trial.retired)")
                }
            }
            try write(complete: true)
            await pair.retire()
        } catch {
            await pair.retire()
            throw error
        }
    }
}

private extension ServingQualificationSharedFixture {
    func collectTrial(job: ServingQualificationJob, prompt: Int, ordinal: Int) async throws -> ServingQualificationServingSetTrial {
        guard let targetEngine = await target.bundle.bridge.ownedEngine as? EngineV2,
              let competitorEngine = await competitor.bundle.bridge.ownedEngine as? EngineV2 else {
            throw QualificationFailure.unsupportedEngine
        }
        let seed = job.corpusSeed ?? job.runID
        let targetRequest = try target.request(targetTokens: prompt, nonce: "\(seed)-\(prompt)-\(ordinal)-target")
        let competitorRequest = try competitor.request(targetTokens: competitor.job.promptLengths[0],
            nonce: "\(seed)-\(prompt)-\(ordinal)-competitor")
        _ = try targetEngine.beginForwardShapeObservation()
        _ = try competitorEngine.beginForwardShapeObservation()
        MLX.Memory.peakMemory = 0
        let anchor = ContinuousClock.now
        var checkpoints: [ServingQualificationServingSetCheckpoint] = []
        let idle = await ServingQualificationServingSetCheckpoint.capture(self, phase: "before_contender", anchor: anchor)
        checkpoints.append(idle)
        let competitorProgress = QualificationStreamProgress()
        let competitorTask = Task { await competitor.collect(request: competitorRequest.0, tokens: competitorRequest.1,
            id: "\(job.runID)-\(ordinal)-competitor", progress: competitorProgress) }
        var ready = false
        // A real content frame plus a completed decode row proves execution;
        // a submitted future or held request flag cannot satisfy this gate.
        for _ in 0..<3000 {
            let capacity = await competitor.bundle.bridge.capacitySnapshot()
            if competitorProgress.contentSeen && !competitorProgress.finished && capacity.activeRequests > 0
                && capacity.decodeRowsTotal > idle.competitor.decodeRowsTotal {
                ready = true
                break
            }
            if competitorProgress.finished || Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let beforeTarget = await ServingQualificationServingSetCheckpoint.capture(self, phase: "before_target", anchor: anchor)
        checkpoints.append(beforeTarget)
        let targetProgress = QualificationStreamProgress()
        let targetTask = Task { await target.collect(request: targetRequest.0, tokens: targetRequest.1,
            id: "\(job.runID)-\(ordinal)-target", progress: targetProgress) }
        var overlap = false
        // Observe the production prefill receipt while the other model is
        // still advancing real decode work. Samples use one shared activity
        // tracker; only the target submission can produce this new sample.
        for _ in 0..<6000 {
            let targetSlot = await target.bundle.bridge.backendSlotCapacity()
            let otherCapacity = await competitor.bundle.bridge.capacitySnapshot()
            let otherSamples = targetSlot.performanceMeasurements?.workloadBuckets
                .filter { $0.phase == "prefill" && $0.otherModelActivity }
                .reduce(Int64(0)) { $0 + $1.observation.sampleCount } ?? 0
            if ready && targetSlot.performanceMeasurements?.epoch == beforeTarget.target.performanceMeasurements?.epoch
                && otherSamples > beforeTarget.target.otherModelPrefillSamples
                && otherCapacity.activeRequests > 0 && !competitorProgress.finished
                && otherCapacity.decodeRowsTotal > beforeTarget.competitor.decodeRowsTotal {
                overlap = true
                break
            }
            if targetProgress.finished || competitorProgress.finished || Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        checkpoints.append(await ServingQualificationServingSetCheckpoint.capture(self, phase: "target_prefill_boundary", anchor: anchor))
        // No fabricated busy owner: cancellation goes through the real stream
        // and the budget remains held until both generations actually retire.
        competitorTask.cancel()
        if !overlap || Task.isCancelled { targetTask.cancel() }
        let competitorRow = await competitorTask.value
        let targetRow = await targetTask.value
        _ = try await competitor.waitForIdle()
        _ = try await target.waitForIdle()
        let final = await ServingQualificationServingSetCheckpoint.capture(self, phase: "after_retirement", anchor: anchor)
        checkpoints.append(final)
        let targetShapes = targetEngine.forwardShapeSnapshot()
        let competitorShapes = competitorEngine.forwardShapeSnapshot()
        let cancelled = competitorRow.failure == "cancelled"
        let completeTiming = targetShapes.droppedTokenTimings == 0 && targetShapes.droppedStepTimings == 0
            && competitorShapes.droppedTokenTimings == 0 && competitorShapes.droppedStepTimings == 0
        let nominal = ProcessInfo.processInfo.thermalState == .nominal && !ProcessInfo.processInfo.isLowPowerModeEnabled
        return .init(iteration: ordinal, promptTarget: prompt, target: targetRow, competitor: competitorRow,
            checkpoints: checkpoints, targetForwardShapes: targetShapes, competitorForwardShapes: competitorShapes,
            overlapProven: overlap, competitorCancelled: cancelled, retired: final.retired,
            peakMemoryBytes: MLX.Memory.peakMemory, thermalState: ProcessInfo.processInfo.thermalState.rawValue,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            passed: idle.retired && overlap && cancelled && final.retired && completeTiming && nominal
                && targetRow.failure == nil && targetRow.firstContentMs != nil)
    }
}
