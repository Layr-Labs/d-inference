import Foundation
import MLXLLM
import MLXLMCommon
import MLXVLM
import ProviderCore

extension SchedulerPrefillBenchmark {
    /// Opt-in real-model companion to `deterministicQwenPolicyEvaluation`.
    ///
    /// Every scenario/cap cell gets a fresh production engine. The complete
    /// workload runs once unreported to compile its exact topology, followed
    /// by the requested measured iterations on that same engine. The result is
    /// local policy evidence, never signed-candidate certification.
    public static func liveQwenPolicyEvaluation(
        modelID: String,
        modelDirectory: URL,
        expectedSnapshotAggregateSHA256: String,
        sourceSHA: String?,
        iterations: Int = 10,
        kvBackend: EngineV2KVBackendSelection = .auto
    ) async throws -> SchedulerPrefillDecisionReport {
        try await SchedulerPrefillDecisionLiveHarness.run(
            modelID: modelID,
            modelDirectory: modelDirectory,
            expectedSnapshotAggregateSHA256: expectedSnapshotAggregateSHA256,
            sourceSHA: sourceSHA,
            iterations: iterations,
            kvBackend: kvBackend,
            signedIdentity: nil)
    }

    /// Signed model-family evidence captured by the packaged main executable.
    ///
    /// The unforgeable `Verified` value is issued only by ProviderCore's
    /// designated-requirement/hash/version preflight.
    public static func signedQwenPolicyEvaluation(
        modelID: String,
        modelDirectory: URL,
        expectedSnapshotAggregateSHA256: String,
        sourceSHA: String,
        iterations: Int = 10,
        kvBackend: EngineV2KVBackendSelection = .auto,
        signedIdentity: SignedReleaseIdentity.Verified
    ) async throws -> SchedulerPrefillDecisionReport {
        try await SchedulerPrefillDecisionLiveHarness.run(
            modelID: modelID,
            modelDirectory: modelDirectory,
            expectedSnapshotAggregateSHA256: expectedSnapshotAggregateSHA256,
            sourceSHA: sourceSHA,
            iterations: iterations,
            kvBackend: kvBackend,
            signedIdentity: signedIdentity)
    }
}

enum SchedulerPrefillDecisionLiveHarness {
    private struct ModelFacts: Sendable {
        let baseTokens: [Int]
        let weightBytes: Int
    }

    static func run(
        modelID: String,
        modelDirectory: URL,
        expectedSnapshotAggregateSHA256: String,
        sourceSHA: String?,
        iterations: Int,
        kvBackend: EngineV2KVBackendSelection,
        signedIdentity: SignedReleaseIdentity.Verified?
    ) async throws -> SchedulerPrefillDecisionReport {
        let started = SchedulerPrefillDecisionMetadata.start()
        guard started.posture.powerSource == "ac" else {
            throw SchedulerPrefillDecisionError.invalidLivePosture(
                "AC power required; observed \(started.posture.powerSource)")
        }
        guard !started.posture.lowPowerModeEnabled else {
            throw SchedulerPrefillDecisionError.invalidLivePosture(
                "Low Power Mode must be disabled")
        }
        guard !["serious", "critical"].contains(
            started.posture.thermalState)
        else {
            throw SchedulerPrefillDecisionError.invalidLivePosture(
                "thermal state is \(started.posture.thermalState)")
        }
        let modelIdentity = try SchedulerPrefillDecisionMetadata.inspectModel(
            operatorModelID: modelID,
            modelDirectory: modelDirectory,
            expectedSnapshotAggregateSHA256:
                expectedSnapshotAggregateSHA256)
        let iterations = max(1, iterations)
        let isVLM = ThroughputSweep.readHasVisionConfig(
            modelDirectory: modelDirectory)
        let container: ModelContainer
        if isVLM {
            container = try await VLMModelFactory.shared.loadContainer(
                from: modelDirectory,
                using: LocalTokenizerLoader())
        } else {
            container = try await LLMModelFactory.shared.loadContainer(
                from: modelDirectory,
                using: LocalTokenizerLoader())
        }
        let facts = await container.perform { context -> ModelFacts in
            let encoded = context.tokenizer.encode(
                text: ThroughputSweep.seedText,
                addSpecialTokens: false)
            let bytes = context.model.parameters().flattened().reduce(0) {
                $0 + $1.1.nbytes
            }
            return ModelFacts(
                baseTokens: encoded.isEmpty ? [0] : encoded,
                weightBytes: bytes)
        }

        let configuration = SchedulerPrefillDecisionScenarios.configuration(
            modeledPromptTokensPerSecond: nil,
            timingBasis: "production CBv2 engine wall clock after one complete "
                + "same-cell warm-up")
        let deterministic = try SchedulerPrefillDecisionSimulator.report(
            promptTokensPerSecond:
                SchedulerPrefillDecisionScenarios.qwenModeledPromptTokensPerSecond)
        let schedulerEvidence = Dictionary(uniqueKeysWithValues:
            deterministic.results.map {
                (SchedulerPrefillDecisionCell(result: $0), $0)
            })

        var results: [SchedulerPrefillDecisionReport.Result] = []
        var resolvedBackends: [String] = []
        var nextRequestID: UInt64 = 10_000

        for workload in SchedulerPrefillDecisionScenarios.qwenEvaluationWorkloads {
            for cap in SchedulerPrefillDecisionScenarios.partialPrefillCaps {
                let cell = SchedulerPrefillDecisionCell(
                    workload: workload,
                    maxConcurrentPartialPrefills: cap)
                guard let evidence = schedulerEvidence[cell] else {
                    throw SchedulerPrefillDecisionError.schedulerStalled(
                        workload.name)
                }
                let activeDecodeMaxTokens = workload.activeDecode
                    ? try SchedulerPrefillDecisionActiveDecodeBudget.maxTokens(
                        workload: workload,
                        schedulerSteps: evidence.schedulerSteps,
                        configuration: configuration)
                    : nil
                let parts = try await SchedulerPrefillDecisionLiveRunner.makeEngine(
                    container: container,
                    modelID: modelID,
                    isVLM: isVLM,
                    modelDirectory: modelDirectory,
                    weightBytes: facts.weightBytes,
                    configuration: configuration,
                    cap: cap,
                    kvBackend: kvBackend)
                if !resolvedBackends.contains(parts.resolvedBackend) {
                    resolvedBackends.append(parts.resolvedBackend)
                }

                do {
                    // Warm this exact topology; a short proxy misses packed,
                    // striped, or mixed decode+prefill kernels.
                    _ = try await SchedulerPrefillDecisionLiveRunner.measure(
                        engine: parts.engine,
                        workload: workload,
                        baseTokens: facts.baseTokens,
                        requestIDBase: nextRequestID,
                        activeDecodeMaxTokens: activeDecodeMaxTokens)
                    nextRequestID += 100

                    for iteration in 1 ... iterations {
                        let measurement =
                            try await SchedulerPrefillDecisionLiveRunner.measure(
                                engine: parts.engine,
                                workload: workload,
                                baseTokens: facts.baseTokens,
                                requestIDBase: nextRequestID,
                                activeDecodeMaxTokens: activeDecodeMaxTokens)
                        nextRequestID += 100
                        results.append(makeResult(
                            workload: workload,
                            iteration: iteration,
                            cap: cap,
                            schedulerEvidence: evidence,
                            measurement: measurement,
                            resolvedBackend: parts.resolvedBackend))
                    }
                } catch {
                    await SchedulerPrefillBenchmark.stopAndReclaim(parts.engine)
                    throw error
                }
                await SchedulerPrefillBenchmark.stopAndReclaim(parts.engine)
            }
        }

        let reproducibility = try SchedulerPrefillDecisionMetadata.finish(
            started,
            sourceSHA: sourceSHA,
            signedIdentity: signedIdentity)
        let evidenceClass: SchedulerPrefillDecisionReport.EvidenceClass =
            signedIdentity == nil ? .unsignedLocalHarness : .signedCandidateModelFamily
        let signedArtifactIdentity = signedIdentity.map {
            SchedulerPrefillDecisionReport.SignedArtifactIdentity(
                identifier: $0.identifier,
                teamID: $0.teamID,
                expectedProviderVersion: $0.expectedVersion,
                observedProviderVersion: $0.providerVersion,
                expectedRegisteredBinarySHA256: $0.expectedExecutableSHA256,
                observedExecutableSHA256: $0.executableSHA256)
        }
        let evaluation = SchedulerPrefillDecisionEvaluator.evaluate(
            mode: .liveModel,
            results: results,
            modelIdentity: modelIdentity,
            reproducibility: reproducibility,
            evidenceClass: evidenceClass,
            signedArtifactIdentity: signedArtifactIdentity)
        return SchedulerPrefillDecisionReport(
            schemaVersion: SchedulerPrefillDecisionReport.currentSchemaVersion,
            mode: .liveModel,
            evidenceClass: evidenceClass,
            signedArtifactIdentity: signedArtifactIdentity,
            modelIdentity: modelIdentity,
            reproducibility: reproducibility,
            configuration: configuration,
            kvBackend: BenchmarkKVBackend(
                selection: kvBackend.rawValue,
                resolved: resolvedBackends),
            results: results,
            evaluation: evaluation)
    }

    private static func makeResult(
        workload: SchedulerPrefillDecisionReport.Workload,
        iteration: Int,
        cap: Int,
        schedulerEvidence: SchedulerPrefillDecisionReport.Result,
        measurement: SchedulerPrefillDecisionLiveMeasurement,
        resolvedBackend: String
    ) -> SchedulerPrefillDecisionReport.Result {
        SchedulerPrefillDecisionReport.Result(
            workload: workload,
            iteration: iteration,
            maxConcurrentPartialPrefills: cap,
            rows: measurement.rows,
            totalPromptTokens: schedulerEvidence.totalPromptTokens,
            makespanMs: measurement.makespanMs,
            aggregatePromptTokensPerSecond:
                measurement.aggregatePromptTokensPerSecond,
            schedulerSteps: nil,
            packedPrefill: .init(
                schedulerEligible:
                    schedulerEvidence.packedPrefill.schedulerEligible,
                modelAndCacheSupported:
                    measurement.packedActivity.isSupported,
                executed: measurement.packedActivity.didExecute,
                eligibleGroups:
                    schedulerEvidence.packedPrefill.eligibleGroups,
                eligibleRows:
                    schedulerEvidence.packedPrefill.eligibleRows,
                executedGroups:
                    measurement.packedActivity.groupsExecuted,
                executedRows:
                    measurement.packedActivity.rowsExecuted),
            resolvedKVBackend: resolvedBackend)
    }
}
