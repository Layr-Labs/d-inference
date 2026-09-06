import Foundation
import MLX
import MLXLMCommon
#if RADIX_CANDIDATE
@_spi(Benchmarking) import ProviderCore
#endif

/// Bounded concurrent probes. Each task produces immutable JSON values; the
/// wrapper transfers those values only after the generating task has finished.
enum BenchmarkBatches {
    private struct Row: @unchecked Sendable {
        let index: Int
        let value: [String: Any]
    }

    struct Result {
        let rows: [[String: Any]]
        let summary: [String: Any]
        let completed: Int
    }

    static func run(
        _ loaded: Loaded, input: Input, firstID: UInt64, count: Int, enabled: Bool
    ) async -> Result {
        let started = DispatchTime.now().uptimeNanoseconds
        let sampler = Task { await sample(loaded, started: started) }
        let collected = await withTaskGroup(of: Row.self, returning: [Row].self) { group in
            for index in 0..<count {
                group.addTask {
                    let rowStart = DispatchTime.now().uptimeNanoseconds
                    let copy = Input(name: input.name + "-b\(index)", kind: input.kind,
                                     tokens: input.tokens, maxTokens: input.maxTokens,
                                     promptRenderDate: input.promptRenderDate)
                    var value: [String: Any]
                    do {
                        value = try await RadixBenchmark.generate(
                            loaded, input: copy, id: firstID + UInt64(index), enabled: enabled,
                            observeIdle: false)
                    } catch {
                        // Preserve a refused/failed submission in the report. A
                        // batch cannot silently look faster by losing a row.
                        value = ["id": copy.name, "kind": copy.kind,
                                 "outcome": "failed", "error": String(describing: error),
                                 "prompt_token_ids": copy.tokens,
                                 "elapsed_s": RadixBenchmark.seconds(
                                    DispatchTime.now().uptimeNanoseconds - rowStart)]
                    }
                    value["batch_id"] = input.name
                    value["batch_index"] = index
                    value["batch_start_offset_s"] = RadixBenchmark.seconds(rowStart - started)
                    return Row(index: index, value: value)
                }
            }
            var result: [Row] = []
            for await row in group { result.append(row) }
            return result.sorted { $0.index < $1.index }
        }
        let ended = DispatchTime.now().uptimeNanoseconds
        sampler.cancel()
        var samples = await sampler.value
        await samples.observe(loaded, started: started)
        let elapsed = RadixBenchmark.seconds(ended - started)
        let metricsAfter = await BenchmarkMetrics.idleSnapshot(loaded)
        let rows = collected.map(\.value)
        let completed = rows.filter { $0["outcome"] as? String == "completed" }.count
        let tokens = rows.reduce(0) { $0 + ($1["completion_tokens"] as? Int ?? 0) }
        return Result(rows: rows, summary: [
            "id": input.name, "concurrency_requested": count,
            "completed": completed, "failed": count - completed,
            "elapsed_s": elapsed, "completion_tokens": tokens,
            "aggregate_tokens_per_second": elapsed > 0 ? Double(tokens) / elapsed : 0,
            "capacity_samples": samples.rows, "capacity_sample_interval_ms": 100,
            "capacity_samples_omitted": samples.omitted,
            "peak_active_requests": samples.peakActive,
            "peak_waiting_requests": samples.peakWaiting,
            "peak_kv_reserved_bytes": samples.peakReserved,
            "peak_kv_in_use_bytes": samples.peakInUse,
            "peak_mlx_active_bytes": samples.peakMLXActive,
            "peak_mlx_cache_bytes": samples.peakMLXCache,
            "metrics_after_batch": metricsAfter,
            "idle_observation_error": BenchmarkIdleObservation.failure(metricsAfter) as Any? ?? NSNull(),
        ], completed: completed)
    }

    private struct Samples: @unchecked Sendable {
        var rows: [[String: Any]] = []
        var omitted = 0
        var peakActive = 0
        var peakWaiting = 0
        var peakReserved = 0
        var peakInUse = 0
        var peakMLXActive = 0
        var peakMLXCache = 0

        mutating func observe(_ loaded: Loaded, started: UInt64) async {
            let engine = loaded.engine
            let capacity = engine.capacity()
            let usage = BenchmarkMetrics.mlxMemory()
            let active = usage.active
            let cached = usage.cached
            peakActive = max(peakActive, capacity.activeRequests)
            peakWaiting = max(peakWaiting, capacity.waitingRequests)
            peakReserved = max(peakReserved, capacity.kvBytesReserved)
            peakInUse = max(peakInUse, capacity.kvBytesInUse)
            peakMLXActive = max(peakMLXActive, active)
            peakMLXCache = max(peakMLXCache, cached)
            guard rows.count < 6000 else { omitted += 1; return }
            var row: [String: Any] = [
                "elapsed_s": RadixBenchmark.seconds(DispatchTime.now().uptimeNanoseconds - started),
                "active_requests": capacity.activeRequests, "waiting_requests": capacity.waitingRequests,
                "kv_reserved_bytes": capacity.kvBytesReserved, "kv_in_use_bytes": capacity.kvBytesInUse,
                "kv_capacity_bytes": capacity.kvBytesCapacity,
                "kv_backend_capacity_bytes": capacity.kvBytesBackendCapacity,
                "active_tokens": capacity.activeTokens, "steps_executed": capacity.stepsExecuted,
                "mlx_active_bytes": active, "mlx_cache_bytes": cached,
                "process_rss_bytes": BenchmarkMetrics.processResidentBytes() as Any? ?? NSNull(),
            ]
            if let storage = BenchmarkMetrics.pagedStorage(capacity) {
                row["paged_storage"] = storage
            }
            #if RADIX_CANDIDATE
            if let memory = await loaded.session?.memorySnapshot() {
                row["process_memory"] = BenchmarkMetrics.processMemory(memory)
            }
            #endif
            rows.append(row)
        }
    }

    private static func sample(_ loaded: Loaded, started: UInt64) async -> Samples {
        var result = Samples()
        while !Task.isCancelled {
            await result.observe(loaded, started: started)
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { break }
        }
        return result
    }
}
