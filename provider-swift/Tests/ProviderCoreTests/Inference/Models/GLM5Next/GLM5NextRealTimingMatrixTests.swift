import Foundation
import MLX
@_spi(Benchmarking) @_spi(Diagnostics) import MLXLMCommon
import Testing

@_spi(Benchmarking) @testable import ProviderCore

/// Same-process, repetition-interleaved protocol matrix.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_TEST_GLM5_REAL_TIMING_MATRIX"] == "1"))
struct GLM5NextRealTimingMatrixTests {
    private struct Cell {
        let context: Int
        let output: Int
        let contentClass: String
        let prompt: [Int]
        var records: [[String: Any]] = []
        var expected: [Int]?
        var stopped = false
    }

    /// MTP-on (the only served GLM mode). Prefill at 512/2048/4096 prompts,
    /// decode with acceptance per content class, TTFT, plus a near-bound
    /// feasibility probe. Production EOS set; provider default effort.
    @Test func realCheckpointInterleavedMatrix() async throws {
        let env = ProcessInfo.processInfo.environment
        try #require(env["DARKBLOOM_TEST_GLM5_REAL_BASELINE_PASSED"] == "1")
        // -Onone throughput is not a measurement of the runtime.
        try #require(!_isDebugAssertConfiguration(), "timing requires an optimized (-c release) build")
        let nonce = try #require(env["DARKBLOOM_TEST_GLM5_REAL_RUN_NONCE"])
        try await GLM5NextRealModelHarness.withLoaded { harness in
            let session = try #require(harness.session)
            let engine = session.rawEngine
            var cells: [Cell] = []
            for (context, output, contentClass) in GLM5NextRealTimingBudget.cells {
                cells.append(.init(context: context, output: output, contentClass: contentClass,
                    prompt: try await harness.exactPrompt(count: context, contentClass: contentClass, nonce: nonce)))
            }
            #if DEBUG
                let debug = true
            #else
                let debug = false
            #endif
            func persist(_ cell: Cell) throws {
                try harness.write("timing-on-\(cell.context)-\(cell.output)-\(cell.contentClass)",
                    ["schema": 1, "qualified": false, "debugConditionDefined": debug,
                     "swiftOptimized": !_isDebugAssertConfiguration(), "ordering": "interleaved_rotating_repetitions",
                     "cellWatchdogSeconds": GLM5NextRealTimingBudget.seconds(context: cell.context, output: cell.output),
                     "aggregateSHA256": harness.plan.weights.manifest.aggregateSHA256,
                     "templateSHA256": GLM5NextRealModelHarness.templateSHA256,
                     "maximumContext": harness.maximumContext, "promptTokens": cell.prompt.count,
                     "promptSHA256": GLM5NextRealModelHarness.tokenHash(cell.prompt), "outputBudget": cell.output,
                     "mtp": true, "contentClass": cell.contentClass, "loadColdSeconds": harness.loadSeconds,
                     "fileCachePurged": false, "soloPrefillStripe": 0, "records": cell.records,
                     "memoryAfterLoad": harness.memoryAfterLoad, "reasoningEffort": "provider_default",
                     "outcome": cell.records.isEmpty ? "not_started" : cell.stopped ? "stopped" : "partial_or_completed",
                     "thermalState": String(describing: ProcessInfo.processInfo.thermalState),
                     "tf32": env["MLX_ENABLE_TF32"] ?? "unset"])
            }
            for cell in cells { try persist(cell) }
            var requestID: UInt64 = 500
            // C1 is one request per process, not one per shape. A long-context
            // initial request is also its feasibility probe. Warm-ups are retained
            // but excluded from throughput summaries.
            for repetition in -2..<GLM5NextRealTimingBudget.warmRepetitions {
                let rotation = max(0, repetition) % cells.count
                let order = Array(cells.indices.dropFirst(rotation)) + Array(cells.indices.prefix(rotation))
                for index in order {
                    if repetition == -2 && index != 0 { continue }
                    if cells[index].stopped || (GLM5NextRealTimingBudget.isLong(cells[index].context) && repetition >= GLM5NextRealTimingBudget.longWarmRepetitions) { continue }
                    let phase = repetition == -2 ? "first_request_cold" : repetition == -1
                        ? (GLM5NextRealTimingBudget.isLong(cells[index].context) ? "feasibility_probe_discarded_warmup" : "discarded_warmup") : "warm"
                    try await Task.sleep(for: .seconds(20))
                    guard ProcessInfo.processInfo.thermalState == .nominal else {
                        cells[index].records.append(["phase": phase, "outcome": "thermal_not_nominal"])
                        cells[index].stopped = true; try persist(cells[index]); continue
                    }
                    cells[index].records.append(["phase": phase, "rep": repetition, "outcome": "in_progress"])
                    try persist(cells[index])
                    let memoryBefore = await session.memorySnapshot()
                    let thermalBefore = String(describing: ProcessInfo.processInfo.thermalState)
                    _ = try engine.beginForwardShapeObservation()
                    requestID += 1
                    let id = requestID
                    let ceiling = GLM5NextRealTimingBudget.seconds(context: cells[index].context, output: cells[index].output)
                    let watchdog = Task {
                        try await Task.sleep(for: .seconds(ceiling))
                        engine.cancel(.init(id))
                        return true
                    }
                    do {
                        let run = try await harness.run(cells[index].prompt, id: requestID, output: cells[index].output)
                        watchdog.cancel()
                        let watchdogFired = (try? await watchdog.value) == true
                        var record = try harness.timingRecord(run)
                        // Natural EOS is a completed measurement; its token
                        // count is recorded and must repeat across reps.
                        let completed = !watchdogFired && run.tokens.count > 1
                            && (run.reason == .length || run.reason == .stop)
                        record["cellWatchdogFired"] = watchdogFired
                        record["phase"] = phase; record["rep"] = repetition
                        record["outcome"] = completed ? "completed"
                            : watchdogFired ? "cell_watchdog_cancelled" : "engine_guardrail_or_incomplete"
                        record["memoryBefore"] = try GLM5NextRealModelHarness.json(memoryBefore)
                        record["memoryAfter"] = try GLM5NextRealModelHarness.json(await session.memorySnapshot())
                        record["mlxPeakMemoryBytesProcessCumulative"] = Memory.peakMemory
                        record["thermalBefore"] = thermalBefore
                        record["thermalAfter"] = String(describing: ProcessInfo.processInfo.thermalState)
                        let cache = await session.cacheSnapshot()
                        record["memoryCapacity"] = ["engineKVCapacityBytes": UInt64(cache.engineKVCapacityBytes),
                            "activationReserveBytes": cache.activationReserveBytes,
                            "postLoadMaximumKVBytes": cache.postLoadMaximumKVBytes,
                            "postBuildHeadroomBytes": cache.postBuildHeadroomBytes ?? 0]
                        let shapes = engine.forwardShapeSnapshot()
                        record["forwardShapes"] = try GLM5NextRealModelHarness.json(shapes)
                        #expect(shapes.droppedStepTimings == 0)
                        record["residentMemory"] = GLM5NextRealModelHarness.residentMemory()
                        if completed {
                            #expect((run.mtp?.rounds ?? 0) > 0, "every completed GLM request must run MTP rounds")
                        }
                        if completed {
                            if let expected = cells[index].expected { #expect(run.tokens == expected) }
                            else { cells[index].expected = run.tokens }
                        } else { cells[index].stopped = true }
                        cells[index].records[cells[index].records.count - 1] = record
                        try persist(cells[index])
                    } catch {
                        watchdog.cancel()
                        cells[index].records[cells[index].records.count - 1]["outcome"] = "submission_or_native_failure"
                        cells[index].records[cells[index].records.count - 1]["errorType"] = String(describing: type(of: error))
                        try persist(cells[index]); throw error
                    }
                }
            }
        }
    }
}
