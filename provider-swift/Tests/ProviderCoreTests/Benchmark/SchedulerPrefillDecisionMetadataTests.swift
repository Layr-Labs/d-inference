// Partial-prefill evidence metadata and scenario rules: error text, the
// bounded active-decode budget, workload ordering, model identity checks,
// run metadata, live result assembly, and the refusals that happen before
// any model loads.

import Foundation
import MLXLMCommon
import Testing

@testable import ProviderBenchmark
@testable import ProviderCore

@Suite("Qwen partial-prefill metadata and scenarios")
struct SchedulerPrefillDecisionMetadataTests {
    private typealias Workload = SchedulerPrefillDecisionReport.Workload
    private typealias WorkloadRow = SchedulerPrefillDecisionReport.WorkloadRow

    private func configuration(chunk: Int = 512) -> SchedulerPrefillDecisionReport.Configuration {
        SchedulerPrefillDecisionReport.Configuration(
            maxConcurrentRequests: 4, maxBatchedTokensPerStep: 2048, prefillChunkTokens: chunk,
            soloPrefillStripeTokens: 0, modeledPromptTokensPerSecond: nil, timingBasis: "test")
    }

    private func budgetFailure(
        _ workload: Workload,
        chunk: Int = 512
    ) -> String? {
        do {
            _ = try SchedulerPrefillDecisionActiveDecodeBudget.maxTokens(
                workload: workload, schedulerSteps: nil, configuration: configuration(chunk: chunk))
            return nil
        } catch SchedulerPrefillDecisionError.activeDecodeBudgetUnavailable(_, let reason) {
            return reason
        } catch {
            return "unexpected: \(error)"
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("prefill-metadata-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeConfig(_ json: String, to directory: URL) throws {
        try Data(json.utf8).write(to: directory.appendingPathComponent("config.json"))
    }

    // MARK: - Errors

    @Test("every decision error describes its cause in plain words")
    func errorDescriptions() {
        typealias Failure = SchedulerPrefillDecisionError
        let cases: [(Failure, String)] = [
            (.invalidPromptTokensPerSecond(0),
             "prompt token rate must be finite and positive, got 0.0"),
            (.invalidModelConfig, "selected checkpoint has no readable JSON config"),
            (.invalidModelIdentifier,
             "model identifier must be a registry label, not a local path"),
            (.unexpectedModelType("llama"),
             "selected checkpoint model_type must be qwen3_5_moe; got llama"),
            (.modelHashUnavailable, "selected checkpoint config or aggregate hash is unavailable"),
            (.modelHashMismatch(expected: "aa", actual: "bb"),
             "selected checkpoint aggregate hash mismatch: expected aa, got bb"),
            (.executableHashUnavailable, "evaluation executable SHA-256 is unavailable"),
            (.invalidLivePosture("on battery"),
             "live policy evaluation requires controlled power/thermal posture: on battery"),
            (.activeDecodeBudgetUnavailable(workload: "w", reason: "r"),
             "w: cannot derive bounded active-decode evidence budget: r"),
            (.activeDecodeCapacityInsufficient(
                workload: "w", maxTokens: 9, kvBytesCapacity: 10, kvBytesReserved: 2, reason: "r"),
             "w: host cannot admit the minimum active-decode evidence budget of 9 tokens "
                + "(kv_capacity=10, kv_reserved=2): r"),
            (.activeDecodeEndedEarly(workload: "w", maxTokens: 9, generatedTokens: 4, reason: "r"),
             "w: active-decode sentinel ended before measurement completion after 4/9 tokens: r"),
            (.activeDecodeBootstrapFailed("w"), "w: failed to establish a decode-ready row"),
            (.schedulerStalled("w"), "w: scheduler made no prompt progress"),
            (.missingFirstToken(workload: "w", row: 2), "w: row 2 never reached first token"),
            (.liveRowProducedNoToken(workload: "w", row: 1), "w: live row 1 produced no token"),
            (.liveRowFailed(workload: "w", row: 3, reason: "r"), "w: live row 3 failed: r"),
            (.activeDecodeFailed(workload: "w", reason: "r"),
             "w: could not establish active decode: r"),
        ]
        for (error, text) in cases {
            #expect(error.description == text)
        }
    }

    // MARK: - Active-decode budget

    @Test("the active-decode budget counts prompt chunks plus slack and startup headroom")
    func activeDecodeBudget() throws {
        let workload = Workload(name: "active", activeDecode: true, rows: [
            WorkloadRow(promptTokens: 1000, arrivalMs: 0),
            WorkloadRow(promptTokens: 24, arrivalMs: 0),
        ])
        let startup = CBv2EngineLoopConfig().eventBufferCapacity + 4
        // 2 + 1 chunks; slack is max(8, 3 / 2).
        #expect(try SchedulerPrefillDecisionActiveDecodeBudget.maxTokens(
            workload: workload, schedulerSteps: nil, configuration: configuration())
            == startup + 3 + 2 + 8)
        // The simulator's step count wins when larger; slack is half of it.
        #expect(try SchedulerPrefillDecisionActiveDecodeBudget.maxTokens(
            workload: workload, schedulerSteps: 40, configuration: configuration())
            == startup + 40 + 2 + 20)
        #expect(try SchedulerPrefillDecisionActiveDecodeBudget.maxTokens(
            workload: workload, schedulerSteps: -5, configuration: configuration())
            == startup + 3 + 2 + 8)
    }

    @Test("the active-decode budget refuses shapes it cannot bound")
    func activeDecodeBudgetRefusals() {
        let zeroArrival = [WorkloadRow(promptTokens: 4, arrivalMs: 0)]
        #expect(budgetFailure(Workload(name: "plain", rows: zeroArrival))
            == "active workload and positive prefill chunk size required")
        #expect(budgetFailure(Workload(name: "a", activeDecode: true, rows: zeroArrival), chunk: 0)
            == "active workload and positive prefill chunk size required")
        #expect(budgetFailure(Workload(name: "a", activeDecode: true, rows: [
            WorkloadRow(promptTokens: 4, arrivalMs: 10),
        ])) == "active-decode join currently requires zero-arrival rows")
        #expect(budgetFailure(Workload(name: "a", activeDecode: true, rows: [
            WorkloadRow(promptTokens: 0, arrivalMs: 0),
        ])) == "prompt rows must be positive")
        #expect(budgetFailure(Workload(name: "a", activeDecode: true, rows: [
            WorkloadRow(promptTokens: Int.max, arrivalMs: 0),
        ])) == "prompt chunk count overflow")
        #expect(budgetFailure(Workload(name: "a", activeDecode: true, rows: [
            WorkloadRow(promptTokens: Int.max, arrivalMs: 0),
            WorkloadRow(promptTokens: 1, arrivalMs: 0),
        ]), chunk: 1) == "aggregate prompt chunk count overflow")
        #expect(budgetFailure(Workload(name: "a", activeDecode: true, rows: [
            WorkloadRow(promptTokens: Int.max, arrivalMs: 0),
        ]), chunk: 1) == "decode token budget overflow")
    }

    // MARK: - Scenarios

    @Test("rows order by arrival and then by index, and prompt tokens add up")
    func workloadOrdering() {
        let workload = Workload(name: "w", rows: [
            WorkloadRow(promptTokens: 8, arrivalMs: 2000),
            WorkloadRow(promptTokens: 4, arrivalMs: 0),
            WorkloadRow(promptTokens: 2, arrivalMs: 2000),
            WorkloadRow(promptTokens: 1, arrivalMs: 0),
        ])
        #expect(workload.orderedRows.map(\.index) == [1, 3, 0, 2])
        #expect(workload.orderedRows.map(\.input.promptTokens) == [4, 1, 8, 2])
        #expect(workload.totalPromptTokens == 15)
        #expect(Workload(name: "empty", rows: []).totalPromptTokens == 0)
    }

    @Test("a cell is keyed by workload name and partial-prefill cap")
    func cellIdentity() throws {
        let report = try SchedulerPrefillBenchmark.deterministicQwenPolicyEvaluation()
        let result = try #require(report.results.first)
        let fromResult = SchedulerPrefillDecisionCell(result: result)
        let fromWorkload = SchedulerPrefillDecisionCell(
            workload: result.workload,
            maxConcurrentPartialPrefills: result.maxConcurrentPartialPrefills)
        #expect(fromResult == fromWorkload)
        #expect(fromResult.workloadName == result.workload.name)
        #expect(fromResult != SchedulerPrefillDecisionCell(
            workload: result.workload,
            maxConcurrentPartialPrefills: result.maxConcurrentPartialPrefills + 1))
        #expect(Set(report.results.map(SchedulerPrefillDecisionCell.init(result:))).count
            == report.results.count)
    }

    @Test("the scenario configuration uses production scheduler sizes")
    func scenarioConfiguration() {
        let config = SchedulerPrefillDecisionScenarios.configuration(
            modeledPromptTokensPerSecond: 99, timingBasis: "basis")
        #expect(config.maxConcurrentRequests == Int(BackendSettings.defaultEngineV2MaxConcurrent))
        #expect(config.maxBatchedTokensPerStep == 2048)
        #expect(config.prefillChunkTokens == 512)
        #expect(config.soloPrefillStripeTokens == EngineV2Factory.defaultSoloPrefillStripeTokens)
        #expect(config.modeledPromptTokensPerSecond == 99)
        #expect(config.timingBasis == "basis")
        #expect(SchedulerPrefillDecisionScenarios.partialPrefillCaps == [0, 1])
        #expect(SchedulerPrefillDecisionScenarios.qwenReleaseWorkloads.map(\.name)
            == SchedulerPrefillDecisionScenarios.qwenEvaluationWorkloads.map(\.name))
        #expect(SchedulerPrefillBenchmark.qwenReleaseDecisionWorkloads.count == 5)
    }

    @Test("the simulator refuses a non-positive or non-finite prompt rate")
    func simulatorRateValidation() {
        for rate in [0, -1, Double.nan, Double.infinity] {
            do {
                _ = try SchedulerPrefillBenchmark.deterministicQwenPolicyEvaluation(
                    promptTokensPerSecond: rate)
                Issue.record("rate \(rate) was accepted")
            } catch SchedulerPrefillDecisionError.invalidPromptTokensPerSecond(let value) {
                #expect(value == rate || (value.isNaN && rate.isNaN))
            } catch {
                Issue.record("unexpected error: \(error)")
            }
        }
    }

    @Test("a faster modeled prompt rate scales every simulated TTFT down")
    func simulatorRateScaling() throws {
        let base = try SchedulerPrefillBenchmark.deterministicQwenPolicyEvaluation(
            promptTokensPerSecond: 1000)
        let fast = try SchedulerPrefillBenchmark.deterministicQwenPolicyEvaluation(
            promptTokensPerSecond: 2000)
        #expect(fast.configuration.modeledPromptTokensPerSecond == 2000)
        #expect(base.results.count == fast.results.count)
        // Only zero-arrival workloads: a timed arrival changes which rows the
        // scheduler sees at each step, so its clock does not scale linearly.
        let pairs = zip(base.results, fast.results).filter { pair in
            pair.0.workload.rows.allSatisfy { $0.arrivalMs == 0 }
        }
        #expect(pairs.count == 8)
        for (slow, quick) in pairs {
            #expect(slow.workload.name == quick.workload.name)
            #expect(slow.schedulerSteps == quick.schedulerSteps)
            for (slowRow, quickRow) in zip(slow.rows, quick.rows) {
                #expect(abs(quickRow.firstTokenAtMs * 2 - slowRow.firstTokenAtMs) < 1e-6)
            }
            #expect(abs(quick.aggregatePromptTokensPerSecond
                - 2 * slow.aggregatePromptTokensPerSecond) < 1e-6)
        }
    }

    // MARK: - Model identity

    @Test("model inspection refuses a path label, a missing config and a wrong model type")
    func inspectModelRefusals() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        func failure(_ modelID: String = "EigenLabs/Qwen3.6-35B") -> SchedulerPrefillDecisionError? {
            do {
                _ = try SchedulerPrefillDecisionMetadata.inspectModel(
                    operatorModelID: modelID, modelDirectory: directory,
                    expectedSnapshotAggregateSHA256: String(repeating: "0", count: 64))
                return nil
            } catch {
                return error as? SchedulerPrefillDecisionError
            }
        }

        guard case .invalidModelIdentifier? = failure("/models/qwen") else {
            Issue.record("a path label was accepted")
            return
        }
        #expect(!SchedulerPrefillDecisionMetadata.isReportSafeModelID("~/qwen"))
        #expect(SchedulerPrefillDecisionMetadata.isReportSafeModelID("EigenLabs/Qwen3.6-35B"))

        guard case .invalidModelConfig? = failure() else {
            Issue.record("a missing config was accepted")
            return
        }
        try writeConfig("[1, 2]", to: directory)
        guard case .invalidModelConfig? = failure() else {
            Issue.record("a non-object config was accepted")
            return
        }
        try writeConfig(#"{"model_type": "llama"}"#, to: directory)
        guard case .unexpectedModelType("llama")? = failure() else {
            Issue.record("a llama config was accepted")
            return
        }
        try writeConfig("{}", to: directory)
        guard case .unexpectedModelType("missing")? = failure() else {
            Issue.record("a config with no model type was accepted")
            return
        }
        // The config file alone is hashed, so a nested Qwen type reaches the
        // hash comparison and fails it.
        try writeConfig(#"{"text_config": {"model_type": "qwen3_5_moe"}}"#, to: directory)
        guard case .modelHashMismatch(let expected, _)? = failure() else {
            Issue.record("a checkpoint with the wrong hash was accepted")
            return
        }
        #expect(expected == String(repeating: "0", count: 64))
    }

    @Test("model inspection reads the text tower and compares hashes without case")
    func inspectModelIdentity() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeConfig(
            #"{"text_config": {"model_type": "QWEN3_5_MOE", "architectures": ["Zeta", "Alpha"]}}"#,
            to: directory)
        try Data("weights".utf8).write(to: directory.appendingPathComponent("model.safetensors"))
        let actual = try #require(WeightHasher.computeHash(snapshotDir: directory, modelID: "fixture"))

        let identity = try SchedulerPrefillDecisionMetadata.inspectModel(
            operatorModelID: "EigenLabs/Qwen3.6-35B", modelDirectory: directory,
            expectedSnapshotAggregateSHA256: actual.uppercased())
        #expect(identity.operatorModelID == "EigenLabs/Qwen3.6-35B")
        #expect(identity.modelType == "qwen3_5_moe")
        #expect(identity.architectures == ["Alpha", "Zeta"])
        #expect(identity.snapshotAggregateSHA256 == actual.lowercased())
        #expect(identity.configSHA256.count == 64)
        #expect(identity.configSHA256 == identity.configSHA256.lowercased())

        do {
            _ = try SchedulerPrefillDecisionMetadata.inspectModel(
                operatorModelID: "EigenLabs/Qwen3.6-35B", modelDirectory: directory,
                expectedSnapshotAggregateSHA256: "ABC")
            Issue.record("a wrong hash was accepted")
        } catch SchedulerPrefillDecisionError.modelHashMismatch(let expected, let observed) {
            #expect(expected == "abc")
            #expect(observed == actual.lowercased())
        }
    }

    // MARK: - Run metadata

    @Test("run metadata records the source, version, binary hash and posture")
    func runMetadata() throws {
        let start = SchedulerPrefillDecisionMetadata.start()
        #expect(["ac", "battery", "unknown"].contains(start.posture.powerSource))
        #expect(["nominal", "fair", "serious", "critical", "unknown"]
            .contains(start.posture.thermalState))
        if let percent = start.posture.batteryPercent {
            #expect((0 ... 100).contains(percent))
        }
        #expect(start.uptimeNanoseconds > 0)

        let metadata = try SchedulerPrefillDecisionMetadata.finish(start, sourceSHA: "abc123")
        #expect(metadata.sourceSHA == "abc123")
        #expect(metadata.providerVersion == ProviderCore.version)
        #expect(["debug", "release"].contains(metadata.buildConfiguration))
        #expect(metadata.executableSHA256.count == 64)
        #expect(metadata.postureAtStart == start.posture)
        #expect(metadata.elapsedSeconds >= 0)
        #expect(metadata.operatingSystem == ProcessInfo.processInfo.operatingSystemVersionString)
        #expect(!metadata.executableName.isEmpty)
        #expect(metadata.hardware.memoryGB > 0)
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let started = try #require(parser.date(from: metadata.startedAtUTC))
        let finished = try #require(parser.date(from: metadata.finishedAtUTC))
        #expect(finished >= started)
    }

    // MARK: - Live harness

    @Test("the live evaluation refuses a path label or an uncontrolled host before loading")
    func liveEvaluationRefusesEarly() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("prefill-live-missing-\(UUID().uuidString)")
        do {
            _ = try await SchedulerPrefillBenchmark.liveQwenPolicyEvaluation(
                modelID: "/models/qwen", modelDirectory: missing,
                expectedSnapshotAggregateSHA256: String(repeating: "0", count: 64),
                sourceSHA: nil, iterations: 1)
            Issue.record("the live evaluation accepted a path label")
        } catch let error as SchedulerPrefillDecisionError {
            switch error {
            case .invalidModelIdentifier, .invalidLivePosture:
                break
            default:
                Issue.record("unexpected error: \(error)")
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test("a live result keeps scheduler eligibility and adds measured packed execution")
    func liveResultAssembly() throws {
        let source = try SchedulerPrefillBenchmark.deterministicQwenPolicyEvaluation()
        let evidence = try #require(source.results.first {
            $0.workload.name == "burst-4x4k" && $0.maxConcurrentPartialPrefills == 0
        })
        let row = SchedulerPrefillDecisionReport.Row(
            row: 0, promptTokens: 4096, scheduledArrivalMs: 0, submittedAtMs: 0.5,
            firstTokenAtMs: 250, ttftMs: 249.5)
        let measurement = SchedulerPrefillDecisionLiveMeasurement(
            rows: [row], makespanMs: 250, aggregatePromptTokensPerSecond: 64,
            packedActivity: CBv2PackedPrefillActivity(
                isSupported: true, rowsExecuted: 4, groupsExecuted: 2))
        let result = SchedulerPrefillDecisionLiveHarness.makeResult(
            workload: evidence.workload, iteration: 3, cap: 0, schedulerEvidence: evidence,
            measurement: measurement, resolvedBackend: "paged")

        #expect(result.workload == evidence.workload)
        #expect(result.iteration == 3)
        #expect(result.maxConcurrentPartialPrefills == 0)
        #expect(result.rows.map(\.ttftMs) == [249.5])
        #expect(result.totalPromptTokens == evidence.totalPromptTokens)
        #expect(result.makespanMs == 250)
        #expect(result.aggregatePromptTokensPerSecond == 64)
        #expect(result.schedulerSteps == nil)
        #expect(result.packedPrefill.schedulerEligible == evidence.packedPrefill.schedulerEligible)
        #expect(result.packedPrefill.eligibleGroups == evidence.packedPrefill.eligibleGroups)
        #expect(result.packedPrefill.eligibleRows == evidence.packedPrefill.eligibleRows)
        #expect(result.packedPrefill.modelAndCacheSupported == true)
        #expect(result.packedPrefill.executed == true)
        #expect(result.packedPrefill.executedGroups == 2)
        #expect(result.packedPrefill.executedRows == 4)
        #expect(result.resolvedKVBackend == "paged")
    }
}
