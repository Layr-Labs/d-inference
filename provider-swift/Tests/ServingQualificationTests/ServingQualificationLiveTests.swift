import Foundation
import MLX
@_spi(Benchmarking) import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

/// Invoked only by the external process-group supervisor. Uses the production
/// model, assistant, template, scheduler bridge, and OpenAI streaming paths.
@Suite("Dedicated serving qualification receipts", .serialized)
struct ServingQualificationLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_SERVING_QUALIFICATION"] == "supervised-v1",
                   "requires scripts/run-serving-qualification.py and an exclusive dedicated GPU lease"))
    func collectDedicatedReceipts() async throws {
        let configPath = try #require(ProcessInfo.processInfo.environment["DARKBLOOM_SERVING_QUALIFICATION_JOB"])
        let job = try JSONDecoder().decode(ServingQualificationJob.self, from: Data(contentsOf: URL(fileURLWithPath: configPath)))
        try #require((1...16).contains(job.width) && (1...1000).contains(job.iterations))
        try #require(job.schedulerMaxConcurrentRequests.map { (job.width...16).contains($0) } ?? true)
        try #require(job.promptLengths.allSatisfy { $0 > 0 } && !job.promptLengths.isEmpty)
        try #require(job.mixedPrefillTokenCap == nil || [128, 256, 512].contains(job.mixedPrefillTokenCap!))
        try #require(job.outputTokens > 0 && job.staggerMilliseconds >= 0)
        try #require(job.competitor == nil, "use the separate competing-model test")
        try #require(job.firstContentBudgetMilliseconds.map { (1...3_600_000).contains($0) } ?? true)
        try #require(job.requireCalibratedAdmission != true || job.firstContentBudgetMilliseconds != nil)
        let buildIdentity = try ServingQualificationBuildIdentity.capture()
        let fixture = try await ServingQualificationFixture.load(job)
        let hardware = try HardwareDetector.detect()
        let backend = await fixture.bundle.bridge.kvBackendKind.rawValue
        guard let concrete = await fixture.bundle.bridge.ownedEngine as? EngineV2 else {
            await fixture.retire()
            throw QualificationFailure.unsupportedEngine
        }
        var trials: [ServingQualificationTrial] = []
        var cooldowns: [QualificationCooldownReceipt] = []
        var preparationCooldowns: [QualificationCooldownReceipt] = []
        func write(complete: Bool) throws {
            let report = ServingQualificationRun(buildIdentity: buildIdentity, schemaVersion: 1, job: job,
                providerVersion: ProviderCore.version, runtimeRevision: ServingPerformanceProfiles.runtimeRevision,
                promptContractID: fixture.promptContractID, actualKVBackend: backend,
                deadlineRuntimeConfiguration: fixture.bundle.bridge.deadlineRuntimeConfiguration,
                configuredContextTokens: fixture.sizing.maxContextLength, chipName: hardware.chipName,
                gpuCores: Int(hardware.gpuCores), memoryBytes: ProcessInfo.processInfo.physicalMemory,
                mtp: fixture.mtp, trials: trials, complete: complete, qualified: false, cooldowns: cooldowns, preparationCooldowns: preparationCooldowns)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(report).write(to: URL(fileURLWithPath: job.outputPath), options: .atomic)
        }
        do {
            // A real qualified-rate warmup must begin within a known posture
            // epoch. Empty-catalog collection reads raw timing independently.
            let preparation = try await QualificationPostureGate.waitForNominal()
            preparationCooldowns.append(preparation)
            try write(complete: false)
            guard preparation.passed else { throw QualificationPostureFailure.recoveryTimedOut }
            if fixture.bundle.bridge.deadlineProfile != nil {
                try #require(fixture.budget.serviceBudget.currentDeadlineRateEpoch() != nil,
                    "qualified warmup must begin after the real posture monitor establishes an eligible epoch")
            }
            // Exclude compilation/first-allocation warmup from measured trials.
            let (warmup, warmTokens) = try fixture.request(targetTokens: job.toolHistory ? 2048 : 256,
                                                         nonce: (job.corpusSeed ?? job.runID) + "-warmup")
            _ = await fixture.collect(request: warmup, tokens: warmTokens, id: "warmup")
            _ = try await fixture.waitForIdle()
            for (promptIndex, prompt) in job.promptLengths.enumerated() {
                for iteration in 0..<job.iterations {
                    let trialOrdinal = promptIndex * job.iterations + iteration
                    let requests = try (0..<job.width).map { row in
                        try fixture.request(targetTokens: prompt, nonce: "\(job.corpusSeed ?? job.runID)-\(prompt)-\(trialOrdinal)-\(row)")
                    }
                    if job.reused {
                        for (request, tokens) in requests {
                            var warm = request
                            warm.maxTokens = 1
                            _ = await fixture.collect(request: warm, tokens: tokens, id: "cache-prime")
                        }
                        _ = try await fixture.waitForIdle()
                    }
                    let cooldown = try await QualificationPostureGate.waitForNominal()
                    cooldowns.append(cooldown)
                    try write(complete: false)
                    guard cooldown.passed else { throw QualificationPostureFailure.recoveryTimedOut }
                    let postureMonitor = QualificationPostureMonitor()
                    _ = try concrete.beginForwardShapeObservation()
                    let beforeMTP = await fixture.bundle.bridge.mtpStatusSnapshot()
                    MLX.Memory.peakMemory = 0
                    let rows = await withTaskGroup(of: (Int, ServingQualificationRow).self) { group in
                        for (row, item) in requests.enumerated() {
                            group.addTask {
                                if row > 0, job.staggerMilliseconds > 0 {
                                    try? await Task.sleep(for: .milliseconds(row * job.staggerMilliseconds))
                                }
                                return (row, await fixture.collect(request: item.0, tokens: item.1,
                                    id: "\(job.runID)-\(prompt)-\(trialOrdinal)-\(row)"))
                            }
                        }
                        var values: [(Int, ServingQualificationRow)] = []
                        for await result in group { values.append(result) }
                        return values.sorted { $0.0 < $1.0 }.map(\.1)
                    }
                    let capacity = try await fixture.waitForIdle()
                    let afterMTP = await fixture.bundle.bridge.mtpStatusSnapshot()
                    let posture = await postureMonitor.finish()
                    trials.append(ServingQualificationTrial(iteration: trialOrdinal, promptTarget: prompt, rows: rows,
                        forwardShapes: concrete.forwardShapeSnapshot(), mtpActive: afterMTP.active,
                        mtpRounds: afterMTP.rounds - beforeMTP.rounds,
                        mtpProposed: afterMTP.proposedTokens - beforeMTP.proposedTokens,
                        mtpAccepted: afterMTP.acceptedDraftTokens - beforeMTP.acceptedDraftTokens,
                        peakMemoryBytes: MLX.Memory.peakMemory, activeMemoryBytes: MLX.Memory.activeMemory,
                        thermalState: posture.worstThermalState, lowPowerMode: posture.lowPowerObserved,
                        retired: capacity.activeRequests == 0 && capacity.kvBytesReserved == 0, posture: posture))
                    try write(complete: false)
                    guard posture.isNominal else { throw QualificationPostureFailure.nonNominalMeasurement }
                    if job.requireCalibratedAdmission == true {
                        #expect(rows.allSatisfy { $0.failure == nil
                            && $0.deadlineEvidence?.calibratedPathProven == true
                            && $0.deadlineEvidence?.legacyWouldReject == true
                            && $0.deadlineEvidence?.deliveredWithinBudget == true },
                            "retain failures: reviewed calibration must actually admit and deliver within the original budget")
                    }
                    print("SERVING_QUALIFICATION prompt=\(prompt) iteration=\(iteration) width=\(job.width) mtp_rounds=\(afterMTP.rounds - beforeMTP.rounds)")
                }
            }
            try write(complete: true)
            await fixture.retire()
        } catch {
            try? write(complete: false)
            await fixture.retire()
            throw error
        }
    }
}
