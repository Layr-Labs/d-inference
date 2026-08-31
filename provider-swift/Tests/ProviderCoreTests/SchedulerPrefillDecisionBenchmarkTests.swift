import Foundation
import MLXLMCommon
import Testing

@testable import ProviderBenchmark
@testable import ProviderCore

private final class ConstrainedDecisionEngine: CBv2Engine, @unchecked Sendable {
    private let lock = NSLock()
    private let tokenCapacity: Int
    private let measurementRows: Int
    private let exhaustSentinel: Bool
    private var sentinelContinuation: AsyncStream<CBv2Event>.Continuation?
    private var _sentinelMaxTokens: Int?
    private var _sentinelGeneratedTokens = 0
    private var submittedMeasurementRows = 0
    private var _sentinelCancelled = false

    init(
        tokenCapacity: Int,
        measurementRows: Int = 4,
        exhaustSentinel: Bool = false
    ) {
        self.tokenCapacity = tokenCapacity
        self.measurementRows = measurementRows
        self.exhaustSentinel = exhaustSentinel
    }

    var sentinelMaxTokens: Int? {
        lock.withLock { _sentinelMaxTokens }
    }

    var sentinelCancelled: Bool {
        lock.withLock { _sentinelCancelled }
    }

    var sentinelGeneratedTokens: Int {
        lock.withLock { _sentinelGeneratedTokens }
    }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        if request.maxTokens > 1 {
            guard request.maxTokens <= tokenCapacity else {
                throw CBv2KVError.capacityExhausted(
                    needed: request.maxTokens,
                    available: tokenCapacity)
            }
            let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
            lock.withLock {
                _sentinelMaxTokens = request.maxTokens
                _sentinelGeneratedTokens = 1
                sentinelContinuation = continuation
            }
            continuation.yield(.delta(text: "", tokens: [7], logprobs: nil))
            return stream
        }

        return AsyncStream { continuation in
            Task {
                try? await Task.sleep(for: .milliseconds(5))
                self.emitSentinelMeasurementProgress()
                continuation.yield(.delta(text: "", tokens: [11], logprobs: nil))
                continuation.yield(.finished(
                    reason: .length,
                    usage: CBv2Usage(
                        promptTokens: request.promptTokens.count,
                        completionTokens: 1)))
                continuation.finish()
            }
        }
    }

    private func emitSentinelMeasurementProgress() {
        lock.withLock {
            guard let continuation = sentinelContinuation,
                let maxTokens = _sentinelMaxTokens,
                measurementRows > 0
            else { return }
            submittedMeasurementRows += 1
            let completedRows = min(submittedMeasurementRows, measurementRows)
            let consumableTokens = max(0, maxTokens - (exhaustSentinel ? 1 : 2))
            let target = 1 + consumableTokens * completedRows / measurementRows
            let count = max(0, target - _sentinelGeneratedTokens)
            _sentinelGeneratedTokens = target
            let exhausted = target >= maxTokens
            if exhausted {
                sentinelContinuation = nil
            }
            if count > 0 {
                continuation.yield(.delta(
                    text: "",
                    tokens: Array(repeating: 7, count: count),
                    logprobs: nil))
            }
            if exhausted {
                continuation.yield(.finished(
                    reason: .length,
                    usage: CBv2Usage(
                        promptTokens: 16,
                        completionTokens: target)))
                continuation.finish()
            }
        }
    }

    func cancel(_: CBv2RequestID) {
        let continuation = lock.withLock {
            _sentinelCancelled = true
            defer { sentinelContinuation = nil }
            return sentinelContinuation
        }
        continuation?.yield(.finished(
            reason: .cancelled,
            usage: CBv2Usage(promptTokens: 16, completionTokens: 1)))
        continuation?.finish()
    }

    func capacity() -> CBv2CapacitySnapshot {
        let active = lock.withLock { sentinelContinuation != nil }
        return CBv2CapacitySnapshot(
            activeRequests: active ? 1 : 0,
            waitingRequests: 0,
            kvBytesInUse: 0,
            kvBytesCapacity: tokenCapacity * 1024,
            kvBytesReserved: 0,
            activeTokens: 0)
    }

    func shutdown() async {
        cancel(CBv2RequestID(0))
    }
}

@Suite("Qwen partial-prefill policy simulation")
struct SchedulerPrefillDecisionBenchmarkTests {
    private let tolerance = 1e-6

    private func report() throws -> SchedulerPrefillDecisionReport {
        try SchedulerPrefillBenchmark.deterministicQwenPolicyEvaluation()
    }

    private func result(
        _ report: SchedulerPrefillDecisionReport,
        workload: String,
        cap: Int
    ) throws -> SchedulerPrefillDecisionReport.Result {
        try #require(report.results.first {
            $0.workload.name == workload
                && $0.maxConcurrentPartialPrefills == cap
        })
    }

    @Test("simulation covers every workload under cap zero and one")
    func matrixCoverage() throws {
        let report = try report()
        #expect(report.mode == .deterministicScheduler)
        #expect(report.evidenceClass == .schedulerSimulation)
        #expect(report.modelIdentity == nil)
        #expect(report.reproducibility == nil)
        #expect(report.evaluation.outcome == .insufficientEvidence)
        #expect(!report.evaluation.releaseCandidateCertified)
        #expect(
            report.configuration.maxConcurrentRequests
                == Int(BackendSettings.defaultEngineV2MaxConcurrent))
        #expect(report.results.count == 10)
        #expect(Set(report.results.map(\.maxConcurrentPartialPrefills)) == [0, 1])
        #expect(Set(report.results.map(\.workload.name)) == [
            "burst-4x4k",
            "burst-4x8k",
            "stagger-t0-tplus2-4x8k",
            "mixed-long-first",
            "active-decode-plus-4x4k",
        ])
    }

    @Test("burst policy changes makespan TTFT into an FCFS staircase")
    func burstTTFTShape() throws {
        let report = try report()
        for workload in ["burst-4x4k", "burst-4x8k"] {
            let unlimited = try result(report, workload: workload, cap: 0)
            let fcfs = try result(report, workload: workload, cap: 1)

            let unlimitedTTFT = unlimited.rows.map(\.ttftMs)
            #expect(unlimitedTTFT.allSatisfy {
                abs($0 - unlimitedTTFT[0]) < tolerance
            })

            let fcfsTTFT = fcfs.rows.map(\.ttftMs)
            #expect(zip(fcfsTTFT, fcfsTTFT.dropFirst()).allSatisfy(<))
            #expect(abs(
                try #require(fcfsTTFT.last)
                    - (try #require(unlimitedTTFT.last))
            ) < tolerance)
            #expect(abs(
                unlimited.aggregatePromptTokensPerSecond
                    - SchedulerPrefillBenchmark.qwenReleaseModeledPromptTPS
            ) < tolerance)
            #expect(abs(
                fcfs.aggregatePromptTokensPerSecond
                    - SchedulerPrefillBenchmark.qwenReleaseModeledPromptTPS
            ) < tolerance)
            #expect(unlimited.totalPromptTokens == fcfs.totalPromptTokens)
        }
    }

    @Test("cap one removes packed cohorts unless decode forces plain chunks")
    func packedPrefillOpportunity() throws {
        let report = try report()
        for workload in [
            "burst-4x4k",
            "burst-4x8k",
            "stagger-t0-tplus2-4x8k",
            "mixed-long-first",
        ] {
            let unlimited = try result(report, workload: workload, cap: 0)
            let fcfs = try result(report, workload: workload, cap: 1)
            #expect(unlimited.packedPrefill.schedulerEligible)
            #expect(unlimited.packedPrefill.eligibleGroups > 0)
            #expect(!fcfs.packedPrefill.schedulerEligible)
            #expect(fcfs.packedPrefill.eligibleGroups == 0)
            #expect(unlimited.packedPrefill.modelAndCacheSupported == nil)
            #expect(unlimited.packedPrefill.executed == nil)
        }
    }

    @Test("staggered arrivals preserve submission-relative TTFT")
    func staggeredArrivals() throws {
        let report = try report()
        for cap in [0, 1] {
            let stagger = try result(
                report, workload: "stagger-t0-tplus2-4x8k", cap: cap)
            #expect(stagger.rows.map(\.submittedAtMs) == [0, 0, 2000, 2000])
            #expect(stagger.rows.allSatisfy {
                abs($0.ttftMs - ($0.firstTokenAtMs - $0.submittedAtMs))
                    < tolerance
            })
            #expect(stagger.totalPromptTokens == 4 * 8192)
        }
    }

    @Test("mixed long-first prompts expose head-of-line cost")
    func mixedPromptHeadOfLine() throws {
        let report = try report()
        let unlimited = try result(report, workload: "mixed-long-first", cap: 0)
        let fcfs = try result(report, workload: "mixed-long-first", cap: 1)
        let shortUnlimited = try #require(
            unlimited.rows.first { $0.promptTokens == 1024 })
        let shortFCFS = try #require(
            fcfs.rows.first { $0.promptTokens == 1024 })

        #expect(shortFCFS.ttftMs > shortUnlimited.ttftMs)
        #expect(unlimited.totalPromptTokens == 15_360)
        #expect(fcfs.totalPromptTokens == unlimited.totalPromptTokens)
        #expect(abs(
            fcfs.aggregatePromptTokensPerSecond
                - unlimited.aggregatePromptTokensPerSecond
        ) < tolerance)
    }

    @Test("bounded active decode survives a constrained host measurement")
    func boundedActiveDecodeOnConstrainedHost() async throws {
        let source = try report()
        let evidence = try result(
            source,
            workload: "active-decode-plus-4x4k",
            cap: 1)
        let budget = try SchedulerPrefillDecisionActiveDecodeBudget.maxTokens(
            workload: evidence.workload,
            schedulerSteps: evidence.schedulerSteps,
            configuration: source.configuration)
        let engine = ConstrainedDecisionEngine(tokenCapacity: 512)

        #expect(budget <= 512)
        #expect(1_000_000 > 512)
        let measurement = try await SchedulerPrefillDecisionLiveRunner.measure(
            engine: engine,
            workload: evidence.workload,
            baseTokens: [1, 2, 3],
            requestIDBase: 9000,
            activeDecodeMaxTokens: budget)

        #expect(measurement.rows.count == evidence.workload.rows.count)
        #expect(engine.sentinelMaxTokens == budget)
        #expect(engine.sentinelGeneratedTokens == budget - 1)
        #expect(engine.sentinelCancelled)

        let exhausted = ConstrainedDecisionEngine(
            tokenCapacity: 512,
            exhaustSentinel: true)
        do {
            _ = try await SchedulerPrefillDecisionLiveRunner.measure(
                engine: exhausted,
                workload: evidence.workload,
                baseTokens: [1, 2, 3],
                requestIDBase: 9025,
                activeDecodeMaxTokens: budget,
                activeDecodeProgressTimeout: .milliseconds(100))
            Issue.record("expected exhausted sentinel evidence refusal")
        } catch let error as SchedulerPrefillDecisionError {
            guard case .activeDecodeEndedEarly(_, _, let generated, let reason) = error else {
                Issue.record("unexpected exhausted-sentinel error: \(error)")
                return
            }
            #expect(generated == budget)
            #expect(reason.contains("length"))
        } catch {
            Issue.record("unexpected exhausted-sentinel error: \(error)")
        }

        let stalled = ConstrainedDecisionEngine(
            tokenCapacity: 512,
            measurementRows: 0)
        do {
            _ = try await SchedulerPrefillDecisionLiveRunner.measure(
                engine: stalled,
                workload: evidence.workload,
                baseTokens: [1, 2, 3],
                requestIDBase: 9050,
                activeDecodeMaxTokens: budget,
                activeDecodeProgressTimeout: .milliseconds(10))
            Issue.record("expected stalled sentinel evidence refusal")
        } catch let error as SchedulerPrefillDecisionError {
            guard case .activeDecodeEndedEarly(_, _, let generated, let reason) = error else {
                Issue.record("unexpected stalled-sentinel error: \(error)")
                return
            }
            #expect(generated == 1)
            #expect(reason.contains("no decode progress"))
            #expect(stalled.sentinelCancelled)
        } catch {
            Issue.record("unexpected stalled-sentinel error: \(error)")
        }

        let insufficient = ConstrainedDecisionEngine(tokenCapacity: budget - 1)
        do {
            _ = try await SchedulerPrefillDecisionLiveRunner.measure(
                engine: insufficient,
                workload: evidence.workload,
                baseTokens: [1, 2, 3],
                requestIDBase: 9100,
                activeDecodeMaxTokens: budget)
            Issue.record("expected constrained host evidence refusal")
        } catch let error as SchedulerPrefillDecisionError {
            guard case .activeDecodeCapacityInsufficient(
                let workload,
                let requested,
                let kvCapacity,
                _,
                _
            ) = error else {
                Issue.record("unexpected evidence error: \(error)")
                return
            }
            #expect(workload == evidence.workload.name)
            #expect(requested == budget)
            #expect(kvCapacity == (budget - 1) * 1024)
        } catch {
            Issue.record("unexpected constrained-host error: \(error)")
        }
    }

    @Test("simulation JSON is explicitly non-certifying and path-free")
    func jsonContract() throws {
        let source = try report()
        let json = try source.jsonString()
        let decoded = try JSONDecoder().decode(
            SchedulerPrefillDecisionReport.self,
            from: Data(json.utf8))

        #expect(decoded.schemaVersion == SchedulerPrefillDecisionReport.currentSchemaVersion)
        #expect(decoded.results.count == source.results.count)
        #expect(decoded.results.allSatisfy { !$0.rows.isEmpty })
        #expect(!decoded.evaluation.releaseCandidateCertified)
        #expect(!json.contains("\"modelPath\""))
        #expect(!json.contains(FileManager.default.currentDirectoryPath))
    }
}

@Suite("Qwen partial-prefill policy evaluator")
struct SchedulerPrefillDecisionEvaluatorTests {
    private func modelIdentity(
        operatorModelID: String = "EigenLabs/Qwen3.6-35B"
    ) -> SchedulerPrefillDecisionReport.ModelIdentity {
        .init(
            operatorModelID: operatorModelID,
            modelType: "qwen3_5_moe",
            architectures: ["Qwen3_5MoeForConditionalGeneration"],
            configSHA256: String(repeating: "a", count: 64),
            snapshotAggregateSHA256: String(repeating: "b", count: 64))
    }

    private func reproducibility(
        sourceSHA: String? = String(repeating: "c", count: 40),
        powerSource: String = "ac"
    ) -> SchedulerPrefillDecisionReport.Reproducibility {
        let posture = SchedulerPrefillDecisionReport.PowerThermalPosture(
            powerSource: powerSource,
            batteryPercent: powerSource == "battery" ? 80 : nil,
            lowPowerModeEnabled: false,
            thermalState: "nominal")
        return .init(
            startedAtUTC: "2026-08-24T20:00:00.000Z",
            finishedAtUTC: "2026-08-24T20:10:00.000Z",
            elapsedSeconds: 600,
            sourceSHA: sourceSHA,
            providerVersion: "0.8.10",
            executableName: "ProviderCorePackageTests",
            executableSHA256: String(repeating: "d", count: 64),
            buildConfiguration: "debug",
            operatingSystem: "macOS 26.5",
            hardware: .init(
                machineModel: "Mac16,5",
                chipName: "Apple M4 Max",
                memoryGB: 128,
                gpuCores: 40),
            postureAtStart: posture,
            postureAtEnd: posture)
    }

    private func signedArtifact(
        _ metadata: SchedulerPrefillDecisionReport.Reproducibility
    ) -> SchedulerPrefillDecisionReport.SignedArtifactIdentity {
        .init(
            identifier: SignedReleaseIdentity.identifier,
            teamID: SignedReleaseIdentity.teamID,
            expectedProviderVersion: metadata.providerVersion,
            observedProviderVersion: metadata.providerVersion,
            expectedRegisteredBinarySHA256: metadata.executableSHA256,
            observedExecutableSHA256: metadata.executableSHA256)
    }

    private func results(
        iterations: Int = 10,
        throughputRatio: Double = 0.97
    ) -> [SchedulerPrefillDecisionReport.Result] {
        SchedulerPrefillDecisionScenarios.qwenEvaluationWorkloads.flatMap {
            workload in
            (1 ... iterations).flatMap { iteration in
                [0, 1].map { cap in
                    makeResult(
                        workload: workload,
                        iteration: iteration,
                        cap: cap,
                        throughputRatio: throughputRatio)
                }
            }
        }
    }

    private func makeResult(
        workload: SchedulerPrefillDecisionReport.Workload,
        iteration: Int,
        cap: Int,
        throughputRatio: Double
    ) -> SchedulerPrefillDecisionReport.Result {
        let ttft: [Double]
        switch (workload.name, cap) {
        case ("burst-4x4k", 0):
            ttft = [12_000, 12_000, 12_000, 12_000]
        case ("burst-4x4k", 1):
            ttft = [2_500, 5_000, 7_500, 10_000]
        case ("burst-4x8k", 0):
            ttft = [21_000, 21_000, 21_000, 21_000]
        case ("burst-4x8k", 1):
            ttft = [5_000, 10_000, 15_000, 20_000]
        case ("mixed-long-first", 0):
            ttft = [10_000, 10_000, 10_000, 10_000]
        case ("mixed-long-first", 1):
            ttft = [5_000, 6_000, 8_500, 10_000]
        case (_, 0):
            ttft = [18_000, 18_000, 18_000, 18_000]
        default:
            ttft = [4_000, 8_000, 12_000, 16_000]
        }
        let rows = workload.rows.indices.map { row in
            SchedulerPrefillDecisionReport.Row(
                row: row,
                promptTokens: workload.rows[row].promptTokens,
                scheduledArrivalMs: workload.rows[row].arrivalMs,
                submittedAtMs: workload.rows[row].arrivalMs,
                firstTokenAtMs: workload.rows[row].arrivalMs + ttft[row],
                ttftMs: ttft[row])
        }
        let throughput = cap == 0 ? 1_000 : 1_000 * throughputRatio
        return .init(
            workload: workload,
            iteration: iteration,
            maxConcurrentPartialPrefills: cap,
            rows: rows,
            totalPromptTokens: workload.totalPromptTokens,
            makespanMs: ttft.max() ?? 0,
            aggregatePromptTokensPerSecond: throughput,
            schedulerSteps: nil,
            packedPrefill: .init(
                schedulerEligible: cap == 0,
                modelAndCacheSupported: true,
                executed: cap == 0,
                eligibleGroups: cap == 0 ? 1 : 0,
                eligibleRows: cap == 0 ? 4 : 0,
                executedGroups: cap == 0 ? 1 : 0,
                executedRows: cap == 0 ? 4 : 0),
            resolvedKVBackend: "contiguous")
    }

    @Test("complete cap comparison passes measurement criteria but never certifies release")
    func passingComparison() {
        let evaluation = SchedulerPrefillDecisionEvaluator.evaluate(
            mode: .liveModel,
            results: results(),
            modelIdentity: modelIdentity(),
            reproducibility: reproducibility())

        #expect(evaluation.outcome == .pass)
        #expect(!evaluation.releaseCandidateCertified)
        #expect(evaluation.comparisons.count == 5)
        #expect(evaluation.checks.allSatisfy { $0.passed })
    }

    @Test("greater than five percent throughput loss fails")
    func throughputRegressionFails() throws {
        let evaluation = SchedulerPrefillDecisionEvaluator.evaluate(
            mode: .liveModel,
            results: results(throughputRatio: 0.949),
            modelIdentity: modelIdentity(),
            reproducibility: reproducibility())

        #expect(evaluation.outcome == .fail)
        let check = try #require(
            evaluation.checks.first { $0.name == "throughput_burst-4x8k" })
        #expect(!check.passed)
    }

    @Test("missing iterations, source, or safe model identity is insufficient")
    func missingPrerequisitesAreInsufficient() {
        let tooFew = SchedulerPrefillDecisionEvaluator.evaluate(
            mode: .liveModel,
            results: results(iterations: 1),
            modelIdentity: modelIdentity(),
            reproducibility: reproducibility())
        let noSource = SchedulerPrefillDecisionEvaluator.evaluate(
            mode: .liveModel,
            results: results(),
            modelIdentity: modelIdentity(),
            reproducibility: reproducibility(sourceSHA: nil))
        let pathIdentity = SchedulerPrefillDecisionEvaluator.evaluate(
            mode: .liveModel,
            results: results(),
            modelIdentity: modelIdentity(
                operatorModelID: "/Users/private/models/qwen"),
            reproducibility: reproducibility())

        #expect(tooFew.outcome == .insufficientEvidence)
        #expect(noSource.outcome == .insufficientEvidence)
        #expect(pathIdentity.outcome == .insufficientEvidence)
    }

    @Test("battery posture cannot pass the controlled comparison")
    func batteryPostureFails() throws {
        let evaluation = SchedulerPrefillDecisionEvaluator.evaluate(
            mode: .liveModel,
            results: results(),
            modelIdentity: modelIdentity(),
            reproducibility: reproducibility(powerSource: "battery"))

        #expect(evaluation.outcome == .fail)
        let check = try #require(
            evaluation.checks.first { $0.name == "power_thermal_posture" })
        #expect(!check.passed)
    }

    @Test("only bound signed metadata can claim model-family evidence")
    func signedEvidenceBinding() {
        let metadata = reproducibility()
        let artifact = signedArtifact(metadata)
        let signed = SchedulerPrefillDecisionEvaluator.evaluate(
            mode: .liveModel,
            results: results(),
            modelIdentity: modelIdentity(),
            reproducibility: metadata,
            evidenceClass: .signedCandidateModelFamily,
            signedArtifactIdentity: artifact)
        let forgedUnsigned = SchedulerPrefillDecisionEvaluator.evaluate(
            mode: .liveModel,
            results: results(),
            modelIdentity: modelIdentity(),
            reproducibility: metadata,
            evidenceClass: .unsignedLocalHarness,
            signedArtifactIdentity: artifact)
        let missingIdentity = SchedulerPrefillDecisionEvaluator.evaluate(
            mode: .liveModel,
            results: results(),
            modelIdentity: modelIdentity(),
            reproducibility: metadata,
            evidenceClass: .signedCandidateModelFamily,
            signedArtifactIdentity: nil)

        #expect(signed.outcome == .pass)
        #expect(!signed.releaseCandidateCertified)
        #expect(signed.limitation.contains("non-Qwen"))
        #expect(forgedUnsigned.outcome == .insufficientEvidence)
        #expect(missingIdentity.outcome == .insufficientEvidence)
    }

    @Test("live-shaped JSON never serializes the selected model directory")
    func reportPrivacy() throws {
        let secretPath = "/Users/private/models/qwen-release-candidate"
        let environment = [
            SchedulerPrefillDecisionCLI.modelPathKey: secretPath,
            SchedulerPrefillDecisionCLI.modelIDKey: "EigenLabs/Qwen3.6-35B",
            SchedulerPrefillDecisionCLI.expectedModelHashKey:
                String(repeating: "a", count: 64),
            SchedulerPrefillDecisionCLI.sourceSHAKey:
                String(repeating: "b", count: 40),
        ]
        let options = try SchedulerPrefillDecisionCLI.liveOptions(
            environment: environment)
        var pathAsIdentifier = environment
        pathAsIdentifier[SchedulerPrefillDecisionCLI.modelIDKey] = secretPath
        #expect(throws: SchedulerPrefillDecisionCLIError.self) {
            _ = try SchedulerPrefillDecisionCLI.liveOptions(
                environment: pathAsIdentifier)
        }
        let values = results()
        let metadata = reproducibility()
        let identity = modelIdentity()
        let evaluation = SchedulerPrefillDecisionEvaluator.evaluate(
            mode: .liveModel,
            results: values,
            modelIdentity: identity,
            reproducibility: metadata)
        let report = SchedulerPrefillDecisionReport(
            schemaVersion: SchedulerPrefillDecisionReport.currentSchemaVersion,
            mode: .liveModel,
            evidenceClass: .unsignedLocalHarness,
            signedArtifactIdentity: nil,
            modelIdentity: identity,
            reproducibility: metadata,
            configuration: SchedulerPrefillDecisionScenarios.configuration(
                modeledPromptTokensPerSecond: nil,
                timingBasis: "test"),
            kvBackend: nil,
            results: values,
            evaluation: evaluation)
        let json = try report.jsonString()
        let artifact = signedArtifact(metadata)
        let signedEvaluation = SchedulerPrefillDecisionEvaluator.evaluate(
            mode: .liveModel,
            results: values,
            modelIdentity: identity,
            reproducibility: metadata,
            evidenceClass: .signedCandidateModelFamily,
            signedArtifactIdentity: artifact)
        let signedReport = SchedulerPrefillDecisionReport(
            schemaVersion: SchedulerPrefillDecisionReport.currentSchemaVersion,
            mode: .liveModel,
            evidenceClass: .signedCandidateModelFamily,
            signedArtifactIdentity: artifact,
            modelIdentity: identity,
            reproducibility: metadata,
            configuration: SchedulerPrefillDecisionScenarios.configuration(
                modeledPromptTokensPerSecond: nil,
                timingBasis: "test"),
            kvBackend: nil,
            results: values,
            evaluation: signedEvaluation)
        let signedJSON = try signedReport.jsonString()

        #expect(options.modelDirectory.path == secretPath)
        #expect(!json.contains(secretPath))
        #expect(!signedJSON.contains(secretPath))
        #expect(!json.contains("\"modelPath\""))
        #expect(!signedJSON.contains("\"modelPath\""))
        #expect(json.contains("\"snapshotAggregateSHA256\""))
        #expect(json.contains("\"executableSHA256\""))
        #expect(signedJSON.contains("\"signed_candidate_model_family\""))
    }

    @Test("registry model IDs reject every local-path ambiguity")
    func canonicalModelIDs() {
        for valid in [
            "gpt-oss-20b",
            "EigenLabs/Qwen3.6-35B",
            "mlx-community/gemma_4-26B-A4B-it-4bit",
        ] {
            #expect(SchedulerPrefillDecisionModelID.isCanonical(valid))
        }
        for invalid in [
            "", ".", "..", "../Qwen", "org/../Qwen", "Users/alice",
            "home/alice", #"C:\models\qwen"#, "file:///tmp/qwen",
            "/tmp/qwen", "~/qwen", "org//model", "org/model/extra",
            " org/model", "org/model ", "org/model\nnext", "org/model\u{0000}",
        ] {
            #expect(!SchedulerPrefillDecisionModelID.isCanonical(invalid))
        }
    }

    @Test("model identity requires Qwen config and the expected aggregate hash")
    func modelIdentityBinding() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(
            """
            {
              "model_type": "qwen3_5_moe",
              "architectures": ["Qwen3_5MoeForConditionalGeneration"]
            }
            """.utf8
        ).write(to: directory.appendingPathComponent("config.json"))
        try Data("weights".utf8).write(
            to: directory.appendingPathComponent("model.safetensors"))
        let expected = try #require(WeightHasher.computeHash(
            snapshotDir: directory,
            modelID: "fixture"))
        #expect(throws: SchedulerPrefillDecisionError.self) {
            _ = try SchedulerPrefillDecisionMetadata.inspectModel(
                operatorModelID: directory.path,
                modelDirectory: directory,
                expectedSnapshotAggregateSHA256: expected)
        }

        let identity = try SchedulerPrefillDecisionMetadata.inspectModel(
            operatorModelID: "EigenLabs/Qwen3.6-35B",
            modelDirectory: directory,
            expectedSnapshotAggregateSHA256: expected)
        #expect(identity.modelType == "qwen3_5_moe")
        #expect(identity.snapshotAggregateSHA256 == expected)
        #expect(identity.configSHA256.count == 64)

        #expect(throws: SchedulerPrefillDecisionError.self) {
            _ = try SchedulerPrefillDecisionMetadata.inspectModel(
                operatorModelID: "EigenLabs/Qwen3.6-35B",
                modelDirectory: directory,
                expectedSnapshotAggregateSHA256: String(repeating: "0", count: 64))
        }

        try Data(
            """
            {
              "model_type": "gemma4_text",
              "architectures": ["Gemma4ForCausalLM"]
            }
            """.utf8
        ).write(to: directory.appendingPathComponent("config.json"))
        let mislabeledHash = try #require(WeightHasher.computeHash(
            snapshotDir: directory,
            modelID: "fixture-mislabeled"))
        #expect(throws: SchedulerPrefillDecisionError.self) {
            _ = try SchedulerPrefillDecisionMetadata.inspectModel(
                operatorModelID: "EigenLabs/Qwen3.6-35B",
                modelDirectory: directory,
                expectedSnapshotAggregateSHA256: mislabeledHash)
        }

        // Qwen3-VL has a shorter upstream first-content SLA than this
        // qwen3_5_moe-only evaluator. Keep it outside the evidence set until
        // the evaluator also selects model-specific deadline thresholds.
        try Data(
            """
            {
              "model_type": "qwen3_vl_moe",
              "architectures": ["Qwen3VLMoeForConditionalGeneration"]
            }
            """.utf8
        ).write(to: directory.appendingPathComponent("config.json"))
        let qwenVLHash = try #require(WeightHasher.computeHash(
            snapshotDir: directory,
            modelID: "fixture-qwen3-vl"))
        #expect(throws: SchedulerPrefillDecisionError.self) {
            _ = try SchedulerPrefillDecisionMetadata.inspectModel(
                operatorModelID: "qwen3-vl-30b-a3b-instruct",
                modelDirectory: directory,
                expectedSnapshotAggregateSHA256: qwenVLHash)
        }
    }
}
