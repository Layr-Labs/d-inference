// Arrival-invariance measurement without a model. A scripted engine stands
// in for the production CBv2 engine, so these tests check the arrival
// topologies, the tolerance and retry rule, the per-row validation, the
// sample arithmetic, and the token checksum.

import Foundation
import MLXLMCommon
import Testing

@testable import ProviderBenchmark
@testable import ProviderCore

@Suite("arrival invariance: measurement without a model")
struct ArrivalInvarianceMeasurementTests {
    private typealias Benchmark = ArrivalInvarianceBenchmark

    private let facts = ArrivalInvarianceBenchmark.ModelFacts(
        baseTokens: [10, 11, 12, 13, 14], weightBytes: 0)

    /// Each request gets tokens derived from its id, in two deltas, then a
    /// `.length` terminal.
    private func countingEngine(gap: Duration = .milliseconds(1)) -> ScriptedBenchmarkEngine {
        ScriptedBenchmarkEngine { request in
            let base = Int(request.id.raw) * 10
            return .events([
                scriptedDelta([base, base + 1]),
                scriptedDelta([base + 2]),
                scriptedFinish(.length),
            ], gap: gap)
        }
    }

    private func measuredRow(
        row: Int, generated: Int, first: UInt64, last: UInt64, finished: UInt64,
        tokens: [Int]
    ) -> ArrivalInvarianceBenchmark.MeasuredRow {
        ArrivalInvarianceBenchmark.MeasuredRow(
            report: ArrivalInvarianceBenchmarkReport.Row(
                row: row, promptTokens: 4, tokenArrivalTimesMs: [], scheduledDelayMs: 0,
                submittedAtMs: 0, arrivalErrorMs: 0, ttftMs: 0, decodeTokensPerSecond: 0,
                generatedTokens: generated, completedAtMs: 0,
                tokenChecksum: ArrivalInvarianceBenchmark.checksum(tokens)),
            tokenIDs: tokens,
            firstTokenAt: first,
            lastTokenAt: last,
            finishedAt: finished)
    }

    // MARK: - Topologies and tolerance

    @Test("patterns are burst, two staggers and a rolling arrival, one delay per row")
    func patternDefinitions() {
        let patterns = Benchmark.patterns(width: 3)
        #expect(patterns.map(\.name) == ["burst", "stagger-25ms", "stagger-100ms", "rolling-250ms"])
        #expect(patterns.map(\.delaysMs) == [[0, 0, 0], [0, 25, 50], [0, 100, 200], [0, 250, 500]])
        #expect(Benchmark.patterns(width: 1).allSatisfy { $0.delaysMs == [0] })
    }

    @Test("default tolerance is one fifth of the tightest arrival gap")
    func defaultTolerance() {
        #expect(Benchmark.minimumArrivalGapMs == 25)
        #expect(Benchmark.defaultArrivalToleranceMs == 5)
        #expect(Benchmark.arrivalToleranceEnvKey == "DARKBLOOM_ARRIVAL_TOLERANCE_MS")
    }

    @Test("an explicit positive tolerance wins and a bad one is ignored")
    func toleranceResolution() {
        #expect(Benchmark.resolvedToleranceMs(explicit: 7.5) == 7.5)
        let ambient = ProcessInfo.processInfo.environment[Benchmark.arrivalToleranceEnvKey]
        for invalid in [0.0, -1.0, Double.nan, Double.infinity, nil] {
            let resolved = Benchmark.resolvedToleranceMs(explicit: invalid)
            if ambient == nil {
                #expect(resolved == Benchmark.defaultArrivalToleranceMs)
            } else {
                #expect(resolved.isFinite && resolved > 0)
            }
        }
    }

    // MARK: - Statistics

    @Test("median is the middle value or the mean of the two middle values")
    func medianValues() {
        #expect(Benchmark.median([]) == 0)
        #expect(Benchmark.median([4]) == 4)
        #expect(Benchmark.median([9, 1, 5]) == 5)
        #expect(Benchmark.median([8, 2, 4, 6]) == 5)
    }

    @Test("checksum is FNV-1a over the eight little-endian bytes of each token")
    func checksumValues() {
        #expect(Benchmark.checksum([]) == "cbf29ce484222325")
        #expect(Benchmark.checksum([0]) == "a8c7f832281a39c5")
        #expect(Benchmark.checksum([1, 2, 3]) == "da2bfb225e0d1f05")
        #expect(Benchmark.checksum([-1]) == "8cf51a8bfca3883d")
        #expect(Benchmark.checksum([1, 2, 3]) != Benchmark.checksum([3, 2, 1]))
    }

    @Test("a sample divides decode intervals by the shared first-to-last token window")
    func sampleArithmetic() {
        let start: UInt64 = 1_000_000_000
        let rows = [
            measuredRow(
                row: 0, generated: 4, first: start + 10_000_000, last: start + 40_000_000,
                finished: start + 50_000_000, tokens: [1, 2, 3, 4]),
            measuredRow(
                row: 1, generated: 3, first: start + 20_000_000, last: start + 60_000_000,
                finished: start + 80_000_000, tokens: [5, 6, 7]),
        ]
        let sample = Benchmark.makeSample(
            rows: rows, iteration: 3, scenarioStartedAt: start,
            maxArrivalErrorMs: 1.25, discardedAttempts: 2)

        // (4 - 1) + (3 - 1) = 5 intervals over 50 ms.
        #expect(abs(sample.report.aggregateDecodeTokensPerSecond - 100) < 1e-9)
        // 7 tokens over an 80 ms makespan.
        #expect(abs(sample.report.endToEndTokensPerSecond - 87.5) < 1e-9)
        #expect(abs(sample.report.makespanMs - 80) < 1e-9)
        #expect(sample.report.iteration == 3)
        #expect(sample.report.maxArrivalErrorMs == 1.25)
        #expect(sample.report.discardedAttempts == 2)
        #expect(sample.report.rows.map(\.row) == [0, 1])
        #expect(sample.outputs == [[1, 2, 3, 4], [5, 6, 7]])
    }

    @Test("an empty sample reports zero rates instead of dividing by zero")
    func emptySample() {
        let sample = Benchmark.makeSample(
            rows: [], iteration: 1, scenarioStartedAt: 42,
            maxArrivalErrorMs: 0, discardedAttempts: 0)
        #expect(sample.report.aggregateDecodeTokensPerSecond == 0)
        #expect(sample.report.endToEndTokensPerSecond == 0)
        #expect(sample.report.makespanMs == 0)
        #expect(sample.report.rows.isEmpty)
        #expect(sample.outputs.isEmpty)
    }

    // MARK: - Measurement through a scripted engine

    @Test("one topology submits tiled prompts at their offsets and records every row")
    func measureTopology() async throws {
        let engine = countingEngine()
        let pattern = ArrivalInvarianceBenchmark.PatternDefinition(
            name: "pair", delaysMs: [0, 5])
        let sample = try await Benchmark.measure(
            engine: engine, facts: facts, pattern: pattern, promptLengths: [3, 4],
            decodeTokens: 3, iteration: 2, requestIDBase: 40, toleranceMs: 1_000_000,
            maxAttempts: 2, enforceTolerance: true)

        #expect(sample.outputs == [[400, 401, 402], [410, 411, 412]])
        #expect(sample.report.iteration == 2)
        #expect(sample.report.discardedAttempts == 0)
        let rows = sample.report.rows
        #expect(rows.map(\.row) == [0, 1])
        #expect(rows.map(\.promptTokens) == [3, 4])
        #expect(rows.map(\.scheduledDelayMs) == [0, 5])
        #expect(rows.map(\.generatedTokens) == [3, 3])
        #expect(rows.map(\.tokenChecksum) == sample.outputs.map { Benchmark.checksum($0) })
        for row in rows {
            #expect(row.arrivalErrorMs == row.submittedAtMs - Double(row.scheduledDelayMs))
            #expect(row.tokenArrivalTimesMs.count == 3)
            #expect(row.ttftMs > 0)
            #expect(row.decodeTokensPerSecond > 0)
            #expect(row.completedAtMs >= (row.tokenArrivalTimesMs.last ?? .infinity))
        }
        // The second row sleeps to an absolute 5 ms deadline before submit.
        #expect(rows[1].submittedAtMs >= 4)
        #expect(sample.report.maxArrivalErrorMs == rows.map { abs($0.arrivalErrorMs) }.max())

        let requests = engine.requests.sorted { $0.id.raw < $1.id.raw }
        #expect(requests.map(\.id.raw) == [40, 41])
        #expect(requests[0].promptTokens == ThroughputSweep.tile(facts.baseTokens, to: 3, offset: 1))
        #expect(requests[1].promptTokens == ThroughputSweep.tile(facts.baseTokens, to: 4, offset: 18))
        #expect(requests.allSatisfy { $0.maxTokens == 3 && $0.stopTokens.isEmpty })
        #expect(requests.allSatisfy { $0.sampling.temperature == 0 })
    }

    @Test("a topology that misses tolerance on every attempt fails with fresh request ids")
    func measureOutOfTolerance() async throws {
        let engine = countingEngine(gap: .zero)
        let pattern = ArrivalInvarianceBenchmark.PatternDefinition(
            name: "tight", delaysMs: [0, 0])
        do {
            _ = try await Benchmark.measure(
                engine: engine, facts: facts, pattern: pattern, promptLengths: [2, 2],
                decodeTokens: 3, iteration: 1, requestIDBase: 100, toleranceMs: 1e-9,
                maxAttempts: 2, enforceTolerance: true)
            Issue.record("expected an arrival tolerance failure")
        } catch let error as ArrivalInvarianceBenchmark.BenchmarkError {
            guard case .arrivalOutOfTolerance(
                let name, let iteration, let observed, let tolerance, let attempts) = error
            else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(name == "tight")
            #expect(iteration == 1)
            #expect(observed > tolerance)
            #expect(tolerance == 1e-9)
            #expect(attempts == 2)
        }
        #expect(engine.requests.map(\.id.raw).sorted() == [100, 101, 102, 103])
    }

    @Test("without enforcement the first attempt is kept even when arrivals are late")
    func measureWithoutEnforcement() async throws {
        let engine = countingEngine(gap: .zero)
        let pattern = ArrivalInvarianceBenchmark.PatternDefinition(name: "warm", delaysMs: [0])
        let sample = try await Benchmark.measure(
            engine: engine, facts: facts, pattern: pattern, promptLengths: [2],
            decodeTokens: 3, iteration: 0, requestIDBase: 7, toleranceMs: 1e-9,
            maxAttempts: 1, enforceTolerance: false)
        #expect(sample.outputs == [[70, 71, 72]])
        #expect(sample.report.discardedAttempts == 0)
        #expect(engine.requests.count == 1)
    }

    private func singleRowFailure(
        decodeTokens: Int,
        _ events: [CBv2Event]
    ) async -> Error? {
        let engine = ScriptedBenchmarkEngine { _ in .events(events, gap: .zero) }
        let pattern = ArrivalInvarianceBenchmark.PatternDefinition(name: "one", delaysMs: [0])
        do {
            _ = try await Benchmark.measure(
                engine: engine, facts: facts, pattern: pattern, promptLengths: [2],
                decodeTokens: decodeTokens, iteration: 1, requestIDBase: 1, toleranceMs: 1e9,
                maxAttempts: 1, enforceTolerance: true)
            return nil
        } catch {
            return error
        }
    }

    @Test("a row with no tokens, a wrong terminal or a short stream is refused")
    func rowValidation() async throws {
        let noTokens = await singleRowFailure(decodeTokens: 2, [scriptedFinish(.length)])
        guard case .noTokens(0)? = noTokens as? ArrivalInvarianceBenchmark.BenchmarkError else {
            Issue.record("expected noTokens, got \(String(describing: noTokens))")
            return
        }

        let stopped = await singleRowFailure(
            decodeTokens: 2, [scriptedDelta([1, 2]), scriptedFinish(.stop)])
        guard case .unexpectedFinish(0, let stopReason)? =
            stopped as? ArrivalInvarianceBenchmark.BenchmarkError
        else {
            Issue.record("expected unexpectedFinish, got \(String(describing: stopped))")
            return
        }
        #expect(stopReason.contains("stop"))

        let unterminated = await singleRowFailure(decodeTokens: 2, [scriptedDelta([1, 2])])
        guard case .unexpectedFinish(0, let missingReason)? =
            unterminated as? ArrivalInvarianceBenchmark.BenchmarkError
        else {
            Issue.record("expected unexpectedFinish, got \(String(describing: unterminated))")
            return
        }
        #expect(missingReason == "nil")

        let short = await singleRowFailure(
            decodeTokens: 3, [scriptedDelta([1, 2]), scriptedFinish(.length)])
        guard case .unexpectedTokenCount(0, 3, 2)? =
            short as? ArrivalInvarianceBenchmark.BenchmarkError
        else {
            Issue.record("expected unexpectedTokenCount, got \(String(describing: short))")
            return
        }
    }

    @Test("a submit refusal from the engine is passed through unchanged")
    func submitRefusal() async {
        let engine = ScriptedBenchmarkEngine { _ in .refuse("pool full") }
        let pattern = ArrivalInvarianceBenchmark.PatternDefinition(name: "one", delaysMs: [0])
        do {
            _ = try await Benchmark.measure(
                engine: engine, facts: facts, pattern: pattern, promptLengths: [2],
                decodeTokens: 2, iteration: 1, requestIDBase: 1, toleranceMs: 1e9,
                maxAttempts: 1, enforceTolerance: true)
            Issue.record("expected the engine refusal")
        } catch {
            #expect((error as? ScriptedBenchmarkRefusal)?.message == "pool full")
        }
    }

    // MARK: - Errors and entry-point validation

    @Test("every benchmark error names the row, the counts or the topology")
    func errorDescriptions() {
        typealias Failure = ArrivalInvarianceBenchmark.BenchmarkError
        #expect(Failure.invalidPromptLengths.description
            == "arrival width must be 1...16 and prompt lengths must contain that many integers >= 2")
        #expect(Failure.noTokens(3).description == "row 3 produced no tokens")
        #expect(Failure.unexpectedFinish(row: 1, reason: "stop").description
            == "row 1 finished unexpectedly: stop")
        #expect(Failure.unexpectedTokenCount(row: 2, expected: 8, actual: 5).description
            == "row 2 produced 5 tokens, expected 8")
        #expect(Failure.arrivalOutOfTolerance(
            pattern: "burst", iteration: 2, observedMs: 12.5, toleranceMs: 5, attempts: 3
        ).description
            == "arrival topology burst iteration 2 could not be delivered within 5.00 ms in "
            + "3 attempt(s) (worst arrival error 12.50 ms); host scheduling is too noisy "
            + "for this measurement")
    }

    @Test("an invalid width or prompt-length list fails before the model is read")
    func runValidation() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("arrival-missing-\(UUID().uuidString)")
        let cases: [(width: Int, lengths: [Int]?)] = [
            (0, nil), (17, nil), (2, [4]), (2, [4, 1]),
        ]
        for (width, lengths) in cases {
            do {
                _ = try await ArrivalInvarianceBenchmark.run(
                    modelID: "fixture", modelDirectory: missing, promptLengths: lengths,
                    width: width, gemmaOptimizations: GemmaOptimizationSettings())
                Issue.record("width \(width) with \(String(describing: lengths)) was accepted")
            } catch let error as ArrivalInvarianceBenchmark.BenchmarkError {
                guard case .invalidPromptLengths = error else {
                    Issue.record("unexpected error: \(error)")
                    continue
                }
            } catch {
                Issue.record("unexpected error: \(error)")
            }
        }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test("the report JSON keeps the measured rows and the backend block")
    func reportJSON() throws {
        let start: UInt64 = 5_000_000
        let sample = Benchmark.makeSample(
            rows: [measuredRow(
                row: 0, generated: 2, first: start + 1_000_000, last: start + 2_000_000,
                finished: start + 3_000_000, tokens: [8, 9])],
            iteration: 1, scenarioStartedAt: start, maxArrivalErrorMs: 0.5,
            discardedAttempts: 1)
        let pattern = ArrivalInvarianceBenchmarkReport.Pattern(
            name: "burst", arrivalDelaysMs: [0], samples: [sample.report],
            medianTTFTMs: 1, medianPerRequestDecodeTokensPerSecond: 2,
            medianAggregateDecodeTokensPerSecond: 3, medianMakespanMs: 4,
            outputsStableAcrossIterations: true, outputsMatchBurst: true,
            measuredArrivalOffsetsMs: [0.1], maxArrivalErrorMs: 0.5,
            arrivalWithinTolerance: true)
        let report = ArrivalInvarianceBenchmarkReport(
            schemaVersion: ArrivalInvarianceBenchmarkReport.currentSchemaVersion,
            modelID: "fixture", modelPath: "/fixture", promptTokensPerRequest: 4,
            promptLengthsPerRequest: [4], decodeTokensPerRequest: 2, iterations: 1,
            effectiveMaxConcurrentRequests: 1,
            gemmaOptimizations: BenchmarkGemmaOptimizations(
                settings: GemmaOptimizationSettings(), getenv: { _ in nil }),
            arrivalToleranceMs: 5, arrivalMaxAttemptsPerSample: 3,
            kvBackend: BenchmarkKVBackend(selection: "auto", resolved: ["contiguous"]),
            patterns: [pattern])

        let json = try report.jsonString()
        let decoded = try JSONDecoder().decode(
            ArrivalInvarianceBenchmarkReport.self, from: Data(json.utf8))
        #expect(decoded.schemaVersion == 6)
        #expect(decoded.kvBackend.resolved == ["contiguous"])
        #expect(decoded.patterns.first?.samples.first?.discardedAttempts == 1)
        #expect(decoded.patterns.first?.samples.first?.rows.first?.tokenChecksum
            == Benchmark.checksum([8, 9]))
        #expect(json.contains("\"arrivalMaxAttemptsPerSample\" : 3"))
    }
}
