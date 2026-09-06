import Foundation
import CryptoKit
import MLX
import MLXLLM
@_spi(Diagnostics) import MLXLMCommon
import MLXVLM
import ProviderCoreFoundation
import enum ProviderCore.JSONValue
#if RADIX_CANDIDATE
@_spi(Benchmarking) import ProviderCore
#else
import ProviderCore
#endif

struct HTTPReport: Decodable {
    struct Row: Decodable {
        struct Case: Decodable { let id: String; let kind: String }
        struct Request: Decodable {
            let model: String
            let max_tokens: Int
            let body: JSONValue

            enum CodingKeys: String, CodingKey { case model, max_tokens }
            init(from decoder: any Decoder) throws {
                body = try JSONValue(from: decoder)
                let fields = try decoder.container(keyedBy: CodingKeys.self)
                model = try fields.decode(String.self, forKey: .model)
                max_tokens = try fields.decode(Int.self, forKey: .max_tokens)
            }
        }
        let `case`: Case
        let request: Request
    }
    let rows: [Row]
}

struct Input: Sendable {
    let name: String
    let kind: String
    let tokens: [Int]
    let maxTokens: Int
    var promptRenderDate: String? = nil
}

// Model ownership moves out of ModelContainer once; one engine serves
// serial or explicitly bounded concurrent requests. Shutdown completes before
// the bundle is released.
struct Loaded: @unchecked Sendable {
    let engine: any CBv2Engine
    let tokenizer: any MLXLMCommon.Tokenizer
    let inputs: [Input]
    let warmup: Input
    let eos: Set<Int>
    let backend: String
    let fallback: String?
    var construction: String {
        #if RADIX_CANDIDATE
        if session != nil {
            return "Production slot factory and SSD staging, then raw engine events; HTTP and bridge request admission measured separately."
        }
        #endif
        return "Direct production factory; slot policy and SSD staging are not exercised."
    }
    var verifiedModelHash: String? = nil
    var gemmaProjection: Data? = nil
    #if RADIX_CANDIDATE
    var session: EngineV2BenchmarkSession? = nil
    #endif
}

@main
enum RadixBenchmark {
    static func main() async throws {
        let options = try BenchmarkOptions(CommandLine.arguments)
        let directory = options.modelDirectory
        let inputData = try Data(contentsOf: options.inputURL)
        let inputSHA256 = SHA256.hash(data: inputData).map { String(format: "%02x", $0) }.joined()
        let report = try JSONDecoder().decode(HTTPReport.self, from: inputData)
        guard let modelID = report.rows.first?.request.model,
              report.rows.allSatisfy({ $0.request.model == modelID }),
              !report.rows.isEmpty else { throw Failure.message("invalid/empty report") }
        if options.nativeKVProbeOnly {
            #if RADIX_CANDIDATE
            try await BenchmarkNativeKVProbe.run(options: options, modelID: modelID)
            return
            #else
            throw Failure.message("native KV inspection requires the candidate artifact")
            #endif
        }
        let cacheEnabled = options.cacheEnabled
        let plannedRows: [[String: Any]] = report.rows.flatMap { row in
            (0..<options.concurrency).map { index in
                ["id": row.case.id + (options.concurrency > 1 ? "-b\(index)" : ""),
                 "kind": row.case.kind, "outcome": "not_run"]
            }
        }
        var result: [String: Any] = [
            "schema": 2, "status": "loading", "model": modelID,
            "model_directory": directory.path,
            "input_sha256": inputSHA256,
            "cache_requested": cacheEnabled, "cache_mode_requested": options.cacheMode,
            "key_mode_requested": options.requirePersistentKey ? "persistent" : "ephemeral",
            "mtp": options.mtpEnabled ? "on; production configured assistant" : "off; no drafter supplied",
            "gemma_mtp_verification_requested": options.gemmaMTPVerification as Any? ?? NSNull(),
            "gemma_projection_tokens_requested": options.gemmaProjectionTokens as Any? ?? NSNull(),
            "requested_backend": options.backend.rawValue,
            "expected_model_sha256": options.expectedModelSHA256 as Any? ?? NSNull(),
            "kv_grant_mode": options.productionKVGrant ? "production_single_slot" : "explicit",
            "kv_budget_bytes": options.productionKVGrant ? (NSNull() as Any) : options.kvBudgetBytes,
            "max_concurrent_requests": options.concurrency,
            "hybrid_cache_requested_budget_bytes": options.cacheMode == "resident" ? 1_073_741_824 : 0,
            "hybrid_cache_requested_max_entries": 32,
            "rows": plannedRows, "batches": [[String: Any]](),
            "warmup": ["outcome": "not_run"], "tenant_checks": [[String: Any]](),
            "cancellation_probe_version": 2,
            "cancel_donor": ["outcome": "not_run"],
            "cancelled": ["outcome": "not_run"], "recovered": ["outcome": "not_run"],
            "decode_tps_definition": "Tokens emitted after the first nonempty delta divided by first-to-last nonempty delta seconds; zero when no later timed delta. First-delta tokens are excluded.",
            "timing_scope": "Cold-path delta includes historical capture; terminal_tail_s includes final donation. Existing capacity step totals are cumulative, not isolated capture timers. Request elapsed/cleanup and batch elapsed exclude idle observation; its elapsed_s is reported in metrics.idle_observation.",
            "unavailable_metrics": ["historical_capture_count", "historical_capture_retirement_ms",
                                    "historical_capture_successor_pause_ms"],
        ]
        if let keys = options.persistentTestKeys {
            result["persistent_test_key_namespace"] = keys.observedProvenance(keyMode: nil)
        }
        try write(result, to: options.outputURL)
        let loaded: Loaded
        do { loaded = try await BenchmarkLoader.load(options: options, report: report, modelID: modelID) }
        catch {
            result["status"] = "failed"
            result["error"] = String(describing: error)
            try write(result, to: options.outputURL)
            throw error
        }
        log("radix-model-ready")
        result["status"] = "running"
        result["resolved_backend"] = loaded.backend
        result["backend_fallback"] = loaded.fallback as Any? ?? NSNull()
        result["construction"] = loaded.construction
        result["verified_model_hash"] = loaded.verifiedModelHash as Any? ?? NSNull()
        let loadedMetrics = await BenchmarkMetrics.snapshot(loaded)
        result["metrics_loaded"] = loadedMetrics
        if let projection = loaded.gemmaProjection {
            result["gemma_projection"] = try JSONSerialization.jsonObject(with: projection)
        }
        if let keys = options.persistentTestKeys {
            result["persistent_test_key_namespace"] = keys.observedProvenance(
                keyMode: loadedMetrics["key_mode"] as? String)
        }
        if let grant = loadedMetrics["production_grant"] as? [String: Any] {
            result["production_grant"] = grant
            result["kv_budget_bytes"] = grant["grant_bytes"]
        }
        #if RADIX_CANDIDATE
        result["runtime_identity"] = EngineV2Factory.benchmarkRuntimeIdentity()
        #endif
        var rows = plannedRows
        var batches: [[String: Any]] = []
        do {
            try write(result, to: options.outputURL)
            try options.persistentTestKeys?.requireObservedMode(
                loadedMetrics["key_mode"] as? String, cacheEnabled: cacheEnabled)
            var requestID: UInt64 = 1
            result["warmup"] = ["outcome": "running"]
            try write(result, to: options.outputURL)
            let warmup = try await generate(loaded, input: loaded.warmup, id: requestID, enabled: false)
            result["warmup"] = warmup
            try write(result, to: options.outputURL)
            try requireCompleted(warmup)
            for (index, input) in loaded.inputs.enumerated() {
                if index == 0 {
                    try BenchmarkLogitDiagnostic.install(options.logitDiagnostic, loaded: loaded)
                    try BenchmarkAttentionMetadata.install(options.attentionMetadata, loaded: loaded)
                    try BenchmarkAttentionPacket.install(options.attentionPacket, loaded: loaded)
                }
                for slot in index * options.concurrency..<(index + 1) * options.concurrency {
                    rows[slot]["outcome"] = "running"
                }
                result["rows"] = rows
                try write(result, to: options.outputURL)
                if options.concurrency > 1 {
                    let batch = await BenchmarkBatches.run(
                        loaded, input: input, firstID: requestID + 1,
                        count: options.concurrency, enabled: cacheEnabled)
                    requestID += UInt64(options.concurrency)
                    rows.replaceSubrange(index * options.concurrency..<(index + 1) * options.concurrency,
                                         with: batch.rows)
                    batches.append(batch.summary)
                    result["rows"] = rows
                    result["batches"] = batches
                    try write(result, to: options.outputURL)
                    log("\(input.name): batch=\(options.concurrency) complete=\(batch.completed)")
                    if let metrics = batch.summary["metrics_after_batch"] as? [String: Any],
                       let failure = BenchmarkIdleObservation.failure(metrics) {
                        throw Failure.message(failure)
                    }
                    guard batch.completed == options.concurrency else {
                        throw Failure.message("incomplete batch \(input.name)")
                    }
                } else {
                    requestID += 1
                    do {
                        rows[index] = try await generate(loaded, input: input, id: requestID, enabled: cacheEnabled)
                    } catch {
                        rows[index] = ["id": input.name, "kind": input.kind, "outcome": "failed",
                                       "error": String(describing: error), "prompt_token_ids": input.tokens]
                    }
                    result["rows"] = rows
                    if index == 0, options.logitDiagnostic != nil {
                        result["logit_diagnostic"] = try BenchmarkLogitDiagnostic.take(loaded: loaded)
                    }
                    if index == 0, options.attentionMetadata != nil {
                        result["attention_metadata"] = try BenchmarkAttentionMetadata.take(loaded: loaded)
                    }
                    if index == 0, options.attentionPacket != nil {
                        result["attention_packet"] = try BenchmarkAttentionPacket.take(
                            loaded: loaded, modelID: modelID, inputSHA256: inputSHA256,
                            directory: options.outputURL.deletingPathExtension().appendingPathExtension("attention-packet"))
                    }
                    try write(result, to: options.outputURL)
                    try requireCompleted(rows[index])
                    log("\(input.name): ttft=\(rows[index]["ttft_s"] ?? "nil") cache=\(rows[index]["cache_outcome"] ?? "nil") saved=\(rows[index]["saved_tokens"] ?? 0)")
                }
            }
            // Fresh isolation scopes cannot reuse an earlier process's donor.
            let longest = loaded.inputs.max(by: { $0.tokens.count < $1.tokens.count })!
            let probeScope = "probe-" + UUID().uuidString
            var checks: [[String: Any]] = []
            for tenant in [probeScope + "-A", probeScope + "-A", probeScope + "-B"] {
                requestID += 1
                result["tenant_checks"] = checks + [["outcome": "running", "scope": tenant]]
                try write(result, to: options.outputURL)
                let row = try await generate(loaded, input: longest, id: requestID,
                                             enabled: cacheEnabled, scope: tenant)
                checks.append(row)
                result["tenant_checks"] = checks
                try write(result, to: options.outputURL)
                try requireCompleted(row)
            }
            // Prime this exact scope in both arms. The paged SSD arm must
            // actually restore it before cancellation; the disabled arm is
            // the matched cold control for donor and recovery token oracles.
            requestID += 1
            result["cancel_donor"] = ["outcome": "running"]
            try write(result, to: options.outputURL)
            let cancelDonor = try await generate(loaded, input: longest, id: requestID,
                enabled: cacheEnabled, scope: probeScope + "-cancel")
            result["cancel_donor"] = cancelDonor
            try write(result, to: options.outputURL)
            try requireCompleted(cancelDonor)
            requestID += 1
            result["cancelled"] = ["outcome": "running"]
            try write(result, to: options.outputURL)
            let cancelled = try await generate(loaded, input: longest, id: requestID,
                enabled: cacheEnabled, scope: probeScope + "-cancel", cancelAfter: 3)
            result["cancelled"] = cancelled
            let observedCancellation = cancelled["outcome"] as? String == "cancelled"
                && cancelled["finish"] as? String == "cancelled"
                && cancelled["cancel_requested"] as? Bool == true
            result["cancellation_probe_outcome"] = observedCancellation ? "observed"
                : cancelled["outcome"] as? String == "completed" ? "not_exercised" : "failed"
            try write(result, to: options.outputURL)
            guard observedCancellation else {
                // A clean fast stop remains a completed generation, but it
                // did not exercise cancellation and cannot pass this probe.
                throw Failure.message("requested cancellation was not observed")
            }
            if cacheEnabled && options.cacheMode == "ssd" && loaded.backend == "paged"
                && !restoredPrefix(cancelled) {
                throw Failure.message("cancellation did not exercise authenticated SSD prefix restoration")
            }
            requestID += 1
            result["recovered"] = ["outcome": "running"]
            try write(result, to: options.outputURL)
            let recovered = try await generate(loaded, input: longest, id: requestID,
                enabled: cacheEnabled, scope: probeScope + "-cancel")
            result["recovered"] = recovered
            try write(result, to: options.outputURL)
            try requireCompleted(recovered)
            let expected = cancelDonor["token_ids"] as? [Int]
            let prefix = cancelled["token_ids"] as? [Int] ?? []
            guard let expected, recovered["token_ids"] as? [Int] == expected,
                  Array(expected.prefix(prefix.count)) == prefix else {
                throw Failure.message("cancellation recovery differs from completed donor tokens")
            }
            #if RADIX_CANDIDATE
            try options.gemmaMTPVerification.flatMap(EngineV2BenchmarkMTPVerification.init(rawValue:))?
                .validateObservedMetrics((loaded.engine as? EngineV2)?.mtpMetricsSnapshot(), requireRounds: true)
            #endif
            await shutdown(loaded)
            let shutdownMetrics = await BenchmarkMetrics.idleSnapshot(loaded, shutdown: true)
            result["metrics_after_shutdown"] = shutdownMetrics
            if let failure = BenchmarkIdleObservation.failure(shutdownMetrics) {
                throw Failure.message(failure)
            }
            result["status"] = "completed"
            try write(result, to: options.outputURL)
        } catch {
            await shutdown(loaded)
            // Keep the original failed observation when shutdown itself timed out.
            if result["metrics_after_shutdown"] == nil {
                result["metrics_after_shutdown"] = await BenchmarkMetrics.idleSnapshot(loaded, shutdown: true)
            }
            result["status"] = "failed"
            result["error"] = String(describing: error)
            // A thrown submission has no stream or token events. Preserve its
            // failed control cell separately from the later unrun cells.
            for key in ["warmup", "cancel_donor", "cancelled", "recovered"] {
                if var row = result[key] as? [String: Any], row["outcome"] as? String == "running" {
                    row["outcome"] = "failed"
                    row["error"] = String(describing: error)
                    result[key] = row
                }
            }
            if var checks = result["tenant_checks"] as? [[String: Any]],
               let last = checks.indices.last, checks[last]["outcome"] as? String == "running" {
                checks[last]["outcome"] = "failed"
                checks[last]["error"] = String(describing: error)
                result["tenant_checks"] = checks
            }
            try write(result, to: options.outputURL)
            throw error
        }
    }

    private static func write(_ result: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: url, options: .atomic)
    }

    private static func requireCompleted(_ row: [String: Any]) throws {
        guard row["outcome"] as? String == "completed" else {
            throw Failure.message("request did not complete: \(row["id"] ?? "unknown") (\(row["finish"] ?? row["error"] ?? "unknown"))")
        }
    }

    static func shutdown(_ loaded: Loaded) async {
        #if RADIX_CANDIDATE
        if let session = loaded.session { await session.shutdown(); return }
        #endif
        await loaded.engine.shutdown()
    }

    static func seconds(_ nanos: UInt64) -> Double { Double(nanos) / 1_000_000_000 }
    static func log(_ message: String) { FileHandle.standardError.write(Data((message + "\n").utf8)) }
    enum Failure: Error { case message(String) }
}
