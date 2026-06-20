import Foundation
import Testing
@testable import ProviderCore

/// Tests that the KV-quant threshold evaluator FAILS CLOSED: a threshold file
/// that cannot be enforced (unreadable, malformed, no rules, or no matching
/// metric) must produce a failing threshold report rather than silently passing.
@Suite("KV-quant threshold evaluator strictness")
struct KVQuantThresholdEvaluatorTests {

    // MARK: - Helpers

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kvq-threshold-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeThresholds(_ contents: String, in dir: URL) -> URL {
        let url = dir.appendingPathComponent("thresholds.json")
        try? contents.data(using: .utf8)!.write(to: url)
        return url
    }

    /// Build a minimal gate report whose logits suite carries `metrics`
    /// (dotted-key → mean value), which is exactly what `reportMetricValues`
    /// reads back for threshold matching.
    private func makeReport(metrics: [String: Double]) throws -> KVQuantGateReport {
        let config = try KVQuantGateConfig(
            modelID: "test/model",
            reference: .fp16KV,
            candidate: .k8v8g128,
            suites: [.logits],
            contexts: [128],
            decodeTokens: 1,
            iterations: 1,
            dataDirectory: nil,
            allowMissingData: false
        )
        let summaries = metrics.mapValues { KVQuantMetricSummary(unit: "rate", samples: [$0]) }
        let quality = KVQuantQualityReport(
            suite: .logits,
            metricName: "generation_fidelity",
            dataDirectory: nil,
            metrics: summaries,
            passFail: .passed(),
            todos: []
        )
        let suite = KVQuantSuiteReport(
            suite: .logits,
            modelID: config.modelID,
            modelPath: nil,
            reference: config.reference,
            candidate: config.candidate,
            contexts: config.contexts,
            iterationCount: config.iterations,
            startedAt: Date(),
            endedAt: Date(),
            performance: nil,
            quality: quality,
            passFail: .passed(),
            failures: [],
            skipped: [],
            todos: []
        )
        let model = KVQuantModelReport(modelID: config.modelID, modelPath: nil, suites: [suite])
        return KVQuantGateReport(
            generatedAt: Date(), config: config, hardware: nil, models: [model])
    }

    // MARK: - Fail-closed cases

    @Test("malformed threshold JSON produces a failing report, not a silent pass")
    func malformedThresholdsFailClosed() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = writeThresholds("{ this is not valid json", in: dir)
        let report = try makeReport(metrics: ["top_token.greedy_match_rate": 0.99])

        let result = KVQuantThresholdEvaluator.evaluate(
            report: report, thresholdsURL: url, hardware: nil)

        let threshold = try #require(result, "malformed thresholds must yield a report, not nil")
        #expect(!threshold.passFail.passed,
            "malformed threshold file must fail the gate")
        #expect(!threshold.failures.isEmpty)
    }

    @Test("threshold file with no min/max rules fails closed")
    func emptyRulesFailClosed() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = writeThresholds("{}", in: dir)
        let report = try makeReport(metrics: ["top_token.greedy_match_rate": 0.99])

        let result = KVQuantThresholdEvaluator.evaluate(
            report: report, thresholdsURL: url, hardware: nil)

        let threshold = try #require(result)
        #expect(!threshold.passFail.passed,
            "a threshold file that defines no rules must fail rather than pass")
    }

    @Test("thresholds referencing only absent metrics fail closed")
    func absentMetricFailsClosed() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Report has only top_token; threshold gates a metric the report lacks.
        let url = writeThresholds(
            #"{"default":{"perf":{"decode_tps_ratio":{"min":0.9}}}}"#, in: dir)
        let report = try makeReport(metrics: ["top_token.greedy_match_rate": 0.99])

        let result = KVQuantThresholdEvaluator.evaluate(
            report: report, thresholdsURL: url, hardware: nil)

        let threshold = try #require(result)
        #expect(!threshold.passFail.passed,
            "a threshold file whose metrics are all absent from the report must fail")
    }

    // MARK: - Normal enforcement still works

    @Test("a present metric within bounds passes")
    func presentMetricWithinBoundsPasses() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = writeThresholds(
            #"{"default":{"top_token":{"greedy_match_rate":{"min":0.9}}}}"#, in: dir)
        let report = try makeReport(metrics: ["top_token.greedy_match_rate": 0.98])

        let result = KVQuantThresholdEvaluator.evaluate(
            report: report, thresholdsURL: url, hardware: nil)

        let threshold = try #require(result)
        #expect(threshold.passFail.passed,
            "a present metric satisfying its bound must pass")
        #expect(threshold.failures.isEmpty)
    }

    @Test("a present metric below its min fails")
    func presentMetricBelowMinFails() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = writeThresholds(
            #"{"default":{"top_token":{"greedy_match_rate":{"min":0.99}}}}"#, in: dir)
        let report = try makeReport(metrics: ["top_token.greedy_match_rate": 0.98])

        let result = KVQuantThresholdEvaluator.evaluate(
            report: report, thresholdsURL: url, hardware: nil)

        let threshold = try #require(result)
        #expect(!threshold.passFail.passed,
            "a present metric violating its bound must fail")
        #expect(!threshold.failures.isEmpty)
    }
}
