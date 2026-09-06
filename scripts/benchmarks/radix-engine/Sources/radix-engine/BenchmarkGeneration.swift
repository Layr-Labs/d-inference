import Foundation
import MLXLMCommon
#if RADIX_CANDIDATE
@_spi(Benchmarking) import ProviderCore
#endif

extension RadixBenchmark {
    /// Require terminal adoption evidence and a fresh authenticated SSD read.
    static func restoredPrefix(_ row: [String: Any]) -> Bool {
        guard row["cache_outcome"] as? String == "hit",
              row["ssd_stage_disposition"] as? String == "staged",
              let matched = row["matched_tokens"] as? NSNumber, matched.int64Value > 0,
              let saved = row["saved_tokens"] as? NSNumber, saved.int64Value > 0,
              let before = row["metrics_before"] as? [String: Any],
              let after = row["metrics_after"] as? [String: Any],
              let beforeSSD = before["ssd_cache"] as? [String: Any],
              let afterSSD = after["ssd_cache"] as? [String: Any],
              let beforeRead = beforeSSD["stage_read_bytes"] as? NSNumber,
              let afterRead = afterSSD["stage_read_bytes"] as? NSNumber else { return false }
        return afterRead.uint64Value > beforeRead.uint64Value
    }

    static func generate(
        _ loaded: Loaded, input: Input, id: UInt64, enabled: Bool,
        scope: String = "tenant-A", cancelAfter: Int? = nil, observeIdle: Bool = true
    ) async throws -> [String: Any] {
        let metricsBefore = await BenchmarkMetrics.snapshot(loaded)
        let start = DispatchTime.now().uptimeNanoseconds
        let requestID = CBv2RequestID(id)
        let request = CBv2Request(
            id: requestID, promptTokens: input.tokens,
            sampling: CBv2SamplingParams(temperature: 0), maxTokens: input.maxTokens,
            stopTokens: loaded.eos, cacheSalt: scope, prefixCacheEnabled: enabled)
        let stream: AsyncStream<CBv2Event>
        var stageMilliseconds = 0.0
        var stageDisposition = "not_attempted"
        #if RADIX_CANDIDATE
        var receipt: CBv2RequestID?
        if let session = loaded.session {
            let submission = try await session.submit(request)
            receipt = submission.receiptID
            stream = submission.events
            stageMilliseconds = submission.stageMilliseconds
            stageDisposition = submission.stageDisposition
        } else { stream = try loaded.engine.submit(request) }
        #else
        stream = try loaded.engine.submit(request)
        #endif
        var tokens: [Int] = []
        var first: UInt64?
        var firstDeltaTokenCount = 0
        var last: UInt64?
        var chunks: [[String: Any]] = []
        var terminal: CBv2Usage?
        var finish = "unterminated"
        var cancelled = false
        for await event in stream {
            let now = DispatchTime.now().uptimeNanoseconds
            switch event {
            case .delta(_, let emitted, _):
                guard !emitted.isEmpty else { continue }
                if first == nil {
                    first = now
                    firstDeltaTokenCount = emitted.count
                }
                last = now
                tokens += emitted
                chunks.append(["elapsed_s": seconds(now - start), "tokens": emitted])
                if let cancelAfter, tokens.count >= cancelAfter, !cancelled {
                    cancelled = true
                    loaded.engine.cancel(requestID)
                }
            case .finished(let reason, let usage):
                finish = String(describing: reason)
                terminal = usage
            }
        }
        let ended = DispatchTime.now().uptimeNanoseconds
        #if RADIX_CANDIDATE
        if let receipt { await loaded.session?.complete(receiptID: receipt) }
        #endif
        let cleanupEnded = DispatchTime.now().uptimeNanoseconds
        let completed = terminal != nil && first != nil && ["stop", "length"].contains(finish)
        let outcome = completed ? "completed" : (finish == "cancelled" && cancelled ? "cancelled" : "failed")
        let duration = first.flatMap { f in last.map { seconds($0 - f) } } ?? 0
        // All serving/cleanup timestamps end before observation. Concurrent
        // rows must not wait for other rows; their enclosing batch observes idle.
        let metricsAfter = observeIdle ? await BenchmarkMetrics.idleSnapshot(loaded)
            : await BenchmarkMetrics.snapshot(loaded)
        var row: [String: Any] = ["id": input.name, "kind": input.kind, "scope": scope, "outcome": outcome,
                "prompt_render_date": input.promptRenderDate as Any? ?? NSNull(),
                "prompt_token_ids": input.tokens, "token_ids": tokens,
                "text": loaded.tokenizer.decode(tokenIds: tokens), "finish": finish,
                "cancel_requested": cancelled, "chunks": chunks,
                "ttft_s": first.map { seconds($0 - start) } as Any? ?? NSNull(),
                "elapsed_s": seconds(ended - start),
                "terminal_tail_s": last.map { seconds(ended - $0) } as Any? ?? NSNull(),
                "completion_cleanup_s": seconds(cleanupEnded - ended),
                "metrics_before": metricsBefore, "metrics_after": metricsAfter,
                "ssd_stage_ms": stageMilliseconds, "ssd_stage_disposition": stageDisposition,
                "first_delta_token_count": firstDeltaTokenCount,
                "decode_tokens_after_first_delta": tokens.count - firstDeltaTokenCount,
                "decode_tps": duration > 0 ? Double(tokens.count - firstDeltaTokenCount) / duration : 0,
                "prompt_tokens": terminal?.promptTokens as Any? ?? NSNull(),
                "completion_tokens": terminal?.completionTokens as Any? ?? NSNull(),
                "cache_outcome": terminal.map { String(describing: $0.prefixCacheOutcome) } as Any? ?? NSNull(),
                "matched_tokens": terminal?.prefixCacheMatchedTokens as Any? ?? NSNull(),
                "saved_tokens": terminal?.prefixCachePrefillTokensSaved as Any? ?? NSNull(),
                "replay_tokens": terminal?.prefixCacheReplayTokens as Any? ?? NSNull(),
                "strategy": terminal?.prefixCacheStrategy.map { String(describing: $0) } as Any? ?? NSNull(),
                "prefill_chunks": terminal?.timing.prefillChunks as Any? ?? NSNull(),
                "prefill_chunk_tokens_max": terminal?.timing.prefillChunkTokensMax as Any? ?? NSNull(),
                "decode_steps": terminal?.timing.decodeSteps as Any? ?? NSNull()]
        if let failure = BenchmarkIdleObservation.failure(metricsAfter) {
            row["outcome"] = "failed"
            row["error"] = failure
        }
        return row
    }

}
