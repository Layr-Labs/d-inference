// The live partial-prefill runner, driven through a scripted engine. These
// tests check arrival order, row timing, packed-prefill counter deltas, row
// validation, and every way the resident active-decode sentinel can fail.

import Foundation
import MLXLMCommon
import Testing

@testable import ProviderBenchmark
@testable import ProviderCore

@Suite("Qwen partial-prefill live runner with a scripted engine")
struct SchedulerPrefillDecisionLiveRunnerTests {
    private typealias Runner = SchedulerPrefillDecisionLiveRunner
    private typealias Workload = SchedulerPrefillDecisionReport.Workload
    private typealias WorkloadRow = SchedulerPrefillDecisionReport.WorkloadRow

    private let baseTokens = [3, 1, 4, 1, 5, 9, 2, 6]

    private func oneTokenEngine(
        packedActivity: [CBv2PackedPrefillActivity] = []
    ) -> ScriptedBenchmarkEngine {
        ScriptedBenchmarkEngine(packedActivity: packedActivity) { _ in
            .events([scriptedDelta([11]), scriptedFinish(.length)], gap: .milliseconds(1))
        }
    }

    private func activeWorkload() -> Workload {
        Workload(
            name: "active", activeDecode: true,
            rows: [WorkloadRow(promptTokens: 4, arrivalMs: 0),
                   WorkloadRow(promptTokens: 4, arrivalMs: 0)])
    }

    /// The sentinel stays open. Each measurement row is answered at once and
    /// pushes one more sentinel token, which is the decode progress the
    /// runner waits for.
    private func sentinelEngine(
        cancelReason: CBv2FinishReason?,
        sentinelID: UInt64
    ) -> ScriptedBenchmarkEngine {
        let engine = ScriptedBenchmarkEngine(cancelReason: cancelReason) { request in
            request.maxTokens > 1
                ? .open([scriptedDelta([7])])
                : .events([scriptedDelta([11]), scriptedFinish(.length)], gap: .zero)
        }
        engine.onSubmit { [weak engine] request in
            guard request.maxTokens == 1 else { return }
            engine?.emit(scriptedDelta([7]), to: CBv2RequestID(sentinelID))
        }
        return engine
    }

    private func measureError(
        engine: ScriptedBenchmarkEngine,
        workload: Workload,
        maxTokens: Int?,
        timeout: Duration = .seconds(5)
    ) async -> Error? {
        do {
            _ = try await Runner.measure(
                engine: engine, workload: workload, baseTokens: baseTokens,
                requestIDBase: 700, activeDecodeMaxTokens: maxTokens,
                activeDecodeProgressTimeout: timeout)
            return nil
        } catch {
            return error
        }
    }

    // MARK: - Rows without active decode

    @Test("rows submit in arrival order and report submission-relative TTFT")
    func arrivalOrderAndTiming() async throws {
        let engine = oneTokenEngine(packedActivity: [
            CBv2PackedPrefillActivity(isSupported: true, rowsExecuted: 2, groupsExecuted: 1),
            CBv2PackedPrefillActivity(isSupported: true, rowsExecuted: 6, groupsExecuted: 2),
        ])
        let workload = Workload(name: "mixed", rows: [
            WorkloadRow(promptTokens: 4, arrivalMs: 0),
            WorkloadRow(promptTokens: 6, arrivalMs: 20),
            WorkloadRow(promptTokens: 5, arrivalMs: 0),
        ])
        let measurement = try await Runner.measure(
            engine: engine, workload: workload, baseTokens: baseTokens, requestIDBase: 500)

        let rows = measurement.rows
        #expect(rows.map(\.row) == [0, 1, 2])
        #expect(rows.map(\.promptTokens) == [4, 6, 5])
        #expect(rows.map(\.scheduledArrivalMs) == [0, 20, 0])
        #expect(rows[1].submittedAtMs >= 19)
        for row in rows {
            #expect(row.ttftMs > 0)
            #expect(abs(row.ttftMs - (row.firstTokenAtMs - row.submittedAtMs)) < 1e-6)
        }
        let lastFirstToken = try #require(rows.map(\.firstTokenAtMs).max())
        #expect(measurement.makespanMs == lastFirstToken)
        #expect(measurement.aggregatePromptTokensPerSecond
            == 15 / (measurement.makespanMs / 1000))
        #expect(measurement.packedActivity == CBv2PackedPrefillActivity(
            isSupported: true, rowsExecuted: 4, groupsExecuted: 1))

        let requests = engine.requests
        #expect(requests.map(\.id.raw) == [500, 502, 501])
        #expect(requests.allSatisfy { $0.maxTokens == 1 && $0.stopTokens.isEmpty })
        for request in requests {
            let row = Int(request.id.raw - 500)
            #expect(request.promptTokens == ThroughputSweep.tile(
                baseTokens, to: workload.rows[row].promptTokens, offset: row * 17 + 1))
        }
        #expect(engine.cancelledIDs.isEmpty)
    }

    @Test("packed counters that move backwards clamp to zero")
    func packedCountersClamp() async throws {
        let engine = oneTokenEngine(packedActivity: [
            .init(isSupported: true, rowsExecuted: 5, groupsExecuted: 3),
            .init(isSupported: false, rowsExecuted: 1, groupsExecuted: 1),
        ])
        let workload = Workload(name: "solo", rows: [WorkloadRow(promptTokens: 2, arrivalMs: 0)])
        let measurement = try await Runner.measure(
            engine: engine, workload: workload, baseTokens: baseTokens, requestIDBase: 1)
        #expect(measurement.packedActivity == CBv2PackedPrefillActivity(
            isSupported: false, rowsExecuted: 0, groupsExecuted: 0))
        #expect(!measurement.packedActivity.didExecute)
    }

    @Test("a row with no token, a wrong terminal or a refused submit fails the cell")
    func rowFailures() async {
        let workload = Workload(name: "one", rows: [WorkloadRow(promptTokens: 3, arrivalMs: 0)])
        func failure(_ reply: ScriptedBenchmarkReply) async -> Error? {
            await measureError(
                engine: ScriptedBenchmarkEngine { _ in reply }, workload: workload, maxTokens: nil)
        }

        let cancelled = await failure(.events([scriptedFinish(.cancelled)], gap: .zero))
        guard case .liveRowFailed("one", 0, let cancelReason)? =
            cancelled as? SchedulerPrefillDecisionError
        else {
            Issue.record("expected liveRowFailed, got \(String(describing: cancelled))")
            return
        }
        #expect(cancelReason == String(describing: CBv2FinishReason.cancelled))

        let silent = await failure(.events([], gap: .zero))
        guard case .liveRowProducedNoToken("one", 0)? = silent as? SchedulerPrefillDecisionError
        else {
            Issue.record("expected liveRowProducedNoToken, got \(String(describing: silent))")
            return
        }

        let stopped = await failure(.events([scriptedDelta([1]), scriptedFinish(.stop)], gap: .zero))
        guard case .liveRowFailed("one", 0, let stopReason)? =
            stopped as? SchedulerPrefillDecisionError
        else {
            Issue.record("expected liveRowFailed, got \(String(describing: stopped))")
            return
        }
        #expect(stopReason.contains("stop"))

        let refused = await failure(.refuse("queue full"))
        #expect((refused as? ScriptedBenchmarkRefusal)?.message == "queue full")
    }

    // MARK: - Active decode sentinel

    @Test("active decode needs a token budget above one")
    func activeDecodeNeedsBudget() async {
        for budget in [nil, 1] as [Int?] {
            let engine = oneTokenEngine()
            let error = await measureError(
                engine: engine, workload: activeWorkload(), maxTokens: budget)
            guard case .activeDecodeBudgetUnavailable("active", let reason)? =
                error as? SchedulerPrefillDecisionError
            else {
                Issue.record("expected budget refusal, got \(String(describing: error))")
                continue
            }
            #expect(reason == "runner received no usable token budget")
            #expect(engine.requests.isEmpty)
        }
    }

    @Test("a sentinel refused for a non-capacity reason passes the error through")
    func sentinelRefusal() async {
        let engine = ScriptedBenchmarkEngine { _ in .refuse("engine stopped") }
        let error = await measureError(engine: engine, workload: activeWorkload(), maxTokens: 64)
        #expect((error as? ScriptedBenchmarkRefusal)?.message == "engine stopped")
    }

    @Test("a sentinel that ends before its first token fails active decode")
    func sentinelEndsEarly() async {
        let erroring = ScriptedBenchmarkEngine { _ in
            .events([scriptedFinish(.error("boom"))], gap: .zero)
        }
        let finished = await measureError(
            engine: erroring, workload: activeWorkload(), maxTokens: 64)
        guard case .activeDecodeFailed("active", let reason)? =
            finished as? SchedulerPrefillDecisionError
        else {
            Issue.record("expected activeDecodeFailed, got \(String(describing: finished))")
            return
        }
        #expect(reason == String(describing: CBv2FinishReason.error("boom")))
        #expect(erroring.cancelledIDs.map(\.raw) == [790])

        let empty = ScriptedBenchmarkEngine { _ in .events([], gap: .zero) }
        let ended = await measureError(engine: empty, workload: activeWorkload(), maxTokens: 64)
        guard case .activeDecodeFailed("active", let endReason)? =
            ended as? SchedulerPrefillDecisionError
        else {
            Issue.record("expected activeDecodeFailed, got \(String(describing: ended))")
            return
        }
        #expect(endReason == "stream ended before first token")
    }

    @Test("rows that cannot join the resident decode fail active decode")
    func rowsCannotJoin() async {
        let engine = ScriptedBenchmarkEngine { request in
            request.maxTokens > 1 ? .open([scriptedDelta([7])]) : .refuse("row refused")
        }
        let error = await measureError(engine: engine, workload: activeWorkload(), maxTokens: 64)
        guard case .activeDecodeFailed("active", let reason)? =
            error as? SchedulerPrefillDecisionError
        else {
            Issue.record("expected activeDecodeFailed, got \(String(describing: error))")
            return
        }
        #expect(reason == "could not join measurement rows to resident decode: row refused")
        #expect(engine.cancelledIDs.map(\.raw) == [790])
    }

    @Test("the sentinel is cancelled after the rows and the cell is measured")
    func sentinelCancelledCleanly() async throws {
        let engine = sentinelEngine(cancelReason: .cancelled, sentinelID: 790)
        let measurement = try await Runner.measure(
            engine: engine, workload: activeWorkload(), baseTokens: baseTokens,
            requestIDBase: 700, activeDecodeMaxTokens: 64)
        #expect(measurement.rows.map(\.row) == [0, 1])
        #expect(measurement.rows.allSatisfy { $0.ttftMs >= 0 })
        #expect(engine.cancelledIDs.map(\.raw) == [790])
        let sentinel = try #require(engine.requests.first)
        #expect(sentinel.id.raw == 790)
        #expect(sentinel.maxTokens == 64)
        #expect(sentinel.promptTokens == ThroughputSweep.tile(baseTokens, to: 16))
        #expect(engine.requests.dropFirst().map(\.id.raw) == [700, 701])
    }

    @Test("a sentinel that ends with a terminal other than cancellation is refused")
    func sentinelWrongTerminal() async {
        let engine = sentinelEngine(cancelReason: .length, sentinelID: 790)
        let error = await measureError(engine: engine, workload: activeWorkload(), maxTokens: 64)
        guard case .activeDecodeEndedEarly("active", 64, let generated, let reason)? =
            error as? SchedulerPrefillDecisionError
        else {
            Issue.record("expected activeDecodeEndedEarly, got \(String(describing: error))")
            return
        }
        #expect(generated == 3)
        #expect(reason == "sentinel terminated as length, not cancellation")
    }

    @Test("a sentinel that sends no terminal after cancel is refused")
    func sentinelSilentCancel() async {
        let engine = sentinelEngine(cancelReason: nil, sentinelID: 790)
        let error = await measureError(
            engine: engine, workload: activeWorkload(), maxTokens: 64,
            timeout: .milliseconds(50))
        guard case .activeDecodeEndedEarly("active", 64, let generated, let reason)? =
            error as? SchedulerPrefillDecisionError
        else {
            Issue.record("expected activeDecodeEndedEarly, got \(String(describing: error))")
            return
        }
        #expect(generated == 3)
        #expect(reason == "sentinel cancellation produced no terminal event")
    }
}
