import Foundation
import MLXLMCommon
import Testing

@testable import ProviderBenchmark
@_spi(Benchmarking) @testable import ProviderCore

@Suite("Runtime-concurrency plan and row validation")
struct RuntimeConcurrencyBenchmarkTests {
    @Test func malformedBatchSizeListsAreRefusedNotFiltered() throws {
        #expect(try RuntimeConcurrencyBenchmark.batchSizes(parsing: "1,2,4,8") == [1, 2, 4, 8])
        #expect(try RuntimeConcurrencyBenchmark.batchSizes(parsing: " 2 , 64") == [2, 64])
        for list in ["1,typo,4", "1,,4", "1,4,", "", " ", "0", "65", "-1", "2.5"] {
            #expect(throws: RuntimeGenerationBenchmark.Failure.invalidArguments, "\(list)") {
                try RuntimeConcurrencyBenchmark.batchSizes(parsing: list)
            }
        }
    }

    @Test func staggeredQuotasAreDistinctOrRefused() {
        func quotas(_ maxTokens: Int, _ batchSize: Int, staggered: Bool = true) -> [Int]? {
            RuntimeConcurrencyBenchmark.rowMaxTokens(
                maxTokens: maxTokens, batchSize: batchSize, staggered: staggered)
        }
        #expect(quotas(64, 4) == [64, 48, 32, 16])
        #expect(quotas(24, 8) == [24, 21, 18, 15, 12, 9, 6, 3])
        #expect(quotas(3, 1) == [3])
        #expect(quotas(5, 3, staggered: false) == [5, 5, 5])
        // A three-token floor would have flattened these to 3,3 and 8,7,6,5,4,3,3,3.
        #expect(quotas(3, 2) == nil)
        #expect(quotas(8, 8) == nil)
        var violations: [String] = []
        for maxTokens in 3 ... 200 {
            for batchSize in 1 ... 64 {
                guard let rows = quotas(maxTokens, batchSize) else {
                    if maxTokens >= 3 * batchSize {
                        violations.append("\(maxTokens)/\(batchSize) refused")
                    }
                    continue
                }
                if rows.count != batchSize || rows.first != maxTokens
                    || !zip(rows, rows.dropFirst()).allSatisfy({ $0 > $1 })
                    || (rows.last ?? 0) < RuntimeConcurrencyBenchmark.minimumStaggeredTokens
                {
                    violations.append("\(maxTokens)/\(batchSize): \(rows)")
                }
            }
        }
        #expect(violations.isEmpty, "\(violations.prefix(3))")
    }

    @Test func flatStaggerIsRefusedBeforeFilesystemOrGPUExecution() async {
        await #expect(throws: RuntimeGenerationBenchmark.Failure.invalidArguments) {
            try await RuntimeConcurrencyBenchmark.run(
                modelID: "qwen3.5-9b", modelDirectory: URL(fileURLWithPath: "/missing-target"),
                prompt: "Public fixture", batchSizes: [1, 2], maxTokens: 3, staggered: true,
                backend: "paged", mtpEnabled: false, renderDate: "2026-10-09")
        }
    }

    @Test func miMoIsRefusedBeforeLoadingOrGPUExecution() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"model_type":"mimo_v2"}"#.utf8)
            .write(to: directory.appendingPathComponent("config.json"))
        await #expect(throws: RuntimeGenerationBenchmark.Failure.unsupportedMiMo) {
            try await RuntimeConcurrencyBenchmark.run(
                modelID: "arbitrary-alias", modelDirectory: directory, prompt: "Public fixture",
                batchSizes: [2], maxTokens: 8, backend: "paged", mtpEnabled: false,
                renderDate: "2026-10-09")
        }
    }

    @Test func rowsMustEndWhereTheirRequestsSay() {
        func failure(
            _ quota: Int, _ tokens: [Int], _ reason: CBv2FinishReason?, staggered: Bool = false
        ) -> String? {
            RuntimeConcurrencyBenchmark.rowFailure(
                quota: quota, tokens: tokens, finishReason: reason, stopTokens: [2],
                staggered: staggered)
        }
        #expect(failure(3, [5, 6, 7], .length) == nil)
        #expect(failure(4, [5, 6, 7], .length) != nil, "a context limit also reports length")
        #expect(failure(4, [5, 6, 2], .stop) == nil)
        #expect(failure(4, [5, 6, 7], .stop) != nil, "stop must end on a configured stop token")
        #expect(failure(2, [5, 6, 2], .stop) != nil, "stop must not overshoot the quota")
        #expect(failure(3, [5, 6, 2], .stop, staggered: true) == nil)
        #expect(
            failure(4, [5, 6, 2], .stop, staggered: true) != nil,
            "an early staggered stop leaves the cohort shape untested")
        #expect(failure(3, [5, 6, 7], .cancelled) != nil)
        #expect(failure(3, [5, 6, 7], nil) != nil)
    }

    @Test func summaryUsesTheTwoSidedMedianAndRecordsRowFailures() throws {
        // Rows decode at 10, 20, 30 and 40 tokens/s: the median is 25, not 30.
        var measured = [10.0, 20, 30, 40].enumerated().map { row, rate in
            RuntimeConcurrencyBenchmark.Measured(
                promptTokens: [1, 2, row], maxTokens: 5, submittedNanos: 0,
                tokens: [7, 7, 7, 7, 7],
                arrivalNanos: (0 ..< 5).map { 1_000_000 + UInt64(Double($0) * 1e9 / rate) },
                finishReason: .length)
        }
        let valid = try RuntimeConcurrencyBenchmark.summarize(
            measured, stopTokens: [], staggered: false)
        let median = try #require(valid.medianRowDecodeTokensPerSecond)
        #expect(abs(median - 25) < 1e-6)
        #expect(valid.failures.isEmpty)
        #expect(valid.rows.map(\.promptTokenCount) == [3, 3, 3, 3])
        #expect(
            valid.rows[0].promptTokensSHA256
                == RuntimeGenerationBenchmark.sha256Hex(Data("[1,2,0]".utf8)))
        #expect(Set(valid.rows.map(\.promptTokensSHA256)).count == 4)
        // Every row is past its first token from 1 ms until the fastest row's
        // last token 100 ms later; 4 + 3 + 2 + 1 tokens arrive in that window.
        #expect(valid.allRowsWindowMs == 100)
        let windowRate = try #require(valid.allRowsDecodeTokensPerSecond)
        #expect(abs(windowRate - 100) < 1e-6)

        measured[2] = RuntimeConcurrencyBenchmark.Measured(
            promptTokens: [1, 2, 2], maxTokens: 5, submittedNanos: 0, tokens: [7, 7, 7],
            arrivalNanos: [1_000_000, 2_000_000, 3_000_000], finishReason: .length)
        let truncated = try RuntimeConcurrencyBenchmark.summarize(
            measured, stopTokens: [], staggered: false)
        #expect(truncated.failures == ["row 2: length after 3 of 5 tokens"])
    }

    @Test func reportCarriesRunAndPerCellProvenance() throws {
        let summary = try RuntimeConcurrencyBenchmark.summarize(
            [
                RuntimeConcurrencyBenchmark.Measured(
                    promptTokens: [1, 2], maxTokens: 1, submittedNanos: 0, tokens: [7],
                    arrivalNanos: [1_000_000], finishReason: .length)
            ], stopTokens: [], staggered: false)
        let cell = RuntimeConcurrencyBenchmark.Cell(
            batchSize: 1, effectiveMaxConcurrentRequests: 1, resolvedBackend: "paged",
            kvQuantization: "native", kvCheckpointQuantization: "balanced",
            checkpointBackendLayout: nil, mtpActive: true,
            assistantIdentity: ["assistant_sha256": "feed"], failures: summary.failures,
            rows: summary.rows, allRowsDecodeTokensPerSecond: nil, allRowsWindowMs: nil,
            medianRowDecodeTokensPerSecond: nil, mtpMetrics: .inactive, chainedSteps: 0)
        let report = RuntimeConcurrencyBenchmark.Report(
            modelID: "qwen3.5-9b", verifiedModelAggregateSHA256: "abc123",
            runtimeIdentity: [:], promptSHA256: "def456", renderDate: "2026-10-09",
            mtpRequested: true, maxTokens: 1, staggered: false, warmupMaxTokens: 32,
            cells: [cell],
            refusedCells: [.init(batchSize: 4, effectiveMaxConcurrentRequests: 1)])
        let json = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(report))
                as? [String: Any])
        #expect(json["verifiedModelAggregateSHA256"] as? String == "abc123")
        #expect(json["promptSHA256"] as? String == "def456")
        #expect(json["renderDate"] as? String == "2026-10-09")
        let cells = try #require(json["cells"] as? [[String: Any]])
        #expect(cells.first?["kvQuantization"] as? String == "native")
        #expect(cells.first?["kvCheckpointQuantization"] as? String == "balanced")
        #expect(cells.first?["assistantIdentity"] as? [String: String] == ["assistant_sha256": "feed"])
        let rows = try #require(cells.first?["rows"] as? [[String: Any]])
        #expect(rows.first?["promptTokensSHA256"] as? String
            == RuntimeGenerationBenchmark.sha256Hex(Data("[1,2]".utf8)))
        let refused = try #require(json["refusedCells"] as? [[String: Any]])
        #expect(refused.first?["effectiveMaxConcurrentRequests"] as? Int == 1)
    }

    @Test func eachRowIsDrainedWhileLaterRowsAreStillSubmitting() async throws {
        let firstRowPulled = PullSignal()
        let requests = (1 ... 2).map {
            CBv2Request(id: CBv2RequestID(UInt64($0)), promptTokens: [1, 2], maxTokens: 1)
        }
        var completed: [CBv2RequestID] = []
        let measured = try await RuntimeConcurrencyBenchmark.runBatch(
            requests,
            submit: { request in
                if request.id == CBv2RequestID(2) {
                    // Submitting every row before draining any times out here,
                    // and row 0's buffered arrivals would be timed late.
                    let pulled = await firstRowPulled.wait(upTo: .seconds(10))
                    #expect(pulled, "row 0 must be drained while row 1 is submitting")
                }
                let isFirst = request.id == CBv2RequestID(1)
                return EngineV2BenchmarkSession.Submission(
                    receiptID: CBv2RequestID(request.id.raw + 100),
                    events: Self.scriptedRow { if isFirst { firstRowPulled.set() } },
                    stageMilliseconds: 0, stageDisposition: "not_attempted")
            },
            complete: { completed.append($0) })
        #expect(measured.map(\.tokens) == [[7], [7]])
        #expect(measured.map(\.finishReason) == [.length, .length])
        #expect(completed == [CBv2RequestID(101), CBv2RequestID(102)])
    }

    /// One token then a length terminal, produced only as the consumer pulls.
    private static func scriptedRow(
        onPull: @escaping @Sendable () -> Void
    ) -> AsyncStream<CBv2Event> {
        let remaining = LockedEvents([
            .delta(text: "x", tokens: [7], logprobs: nil),
            .finished(reason: .length, usage: CBv2Usage(promptTokens: 2, completionTokens: 1)),
        ])
        return AsyncStream(unfolding: {
            onPull()
            return remaining.next()
        })
    }
}

private final class LockedEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [CBv2Event]

    init(_ events: [CBv2Event]) { self.events = events }

    func next() -> CBv2Event? {
        lock.withLock { events.isEmpty ? nil : events.removeFirst() }
    }
}

/// Set once a scripted row's consumer first pulls its stream.
private final class PullSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var pulled = false

    func set() { lock.withLock { pulled = true } }

    func wait(upTo timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !lock.withLock({ pulled }), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return lock.withLock { pulled }
    }
}
