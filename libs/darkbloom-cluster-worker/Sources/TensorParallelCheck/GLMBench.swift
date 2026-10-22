import DarkbloomClusterRuntime
import Darwin
import Foundation
import MLX

// darkbloom-cluster-tp-check glm --mode full|shard|tp --model-dir DIR --report FILE
//     [--prompt-tokens N | --prompt-file TOKENS.json] [--output-count N] [--chunk N] [--repeats N]
//     [--shard-rank R] [--partials float32|stored] [--pipelined yes|no] [--census yes|no]
//     [--reduction native|sealed] [--cache-limit-mb N] [--micro-batches N] [--mtp-depth 0...3]
//     [--mtp-check none|keep-first|one-token] [--mtp-early none|proposals|layers] [--mtp-vocab-split yes|no] [--prefill-schedule chunked|product|merged]
//     [--merged-tokens N] [--keep-prefix yes|no] [--micro-batch-tokens N] [--perplexity yes|no]
//     [--lanes N (with --mtp-depth) [--lanes-batched yes|no] [--lanes-split-eval yes|no]]
//     [--kv paged|contiguous]
//     [--sequence-parallel yes|no] [--prefix-grid chunk|bulk] [--pin-selections yes|no] [--micro-batch-rule half|all] [--prefill-ops N] [--divergence N [--divergence-rows R] [--divergence-start K[,K2...]]]
// darkbloom-cluster-tp-check glm allsum | sealprobe   (link and crypto costs alone)
// GLM-5.3-Flash tensor-parallel measurement (GLM5NextTensorParallelBench): the
// unsharded model, one rank's shard with no peer, or one rank of a JACCL pair.
// The prompt is a fixed pseudo-random token sequence (same on every Mac and run).
enum GLMBench {
    static func run(_ arguments: [String]) throws {
        if arguments.first == "sealprobe" {
            GLM5NextTensorParallelBench.sealProbe(bytes: [16_384, 16 << 20, 32 << 20], repeats: 20, log: { note($0) })
            return
        }
        if arguments.first == "gemm" {
            // Local diagnostic: achievable matmul TFLOPS at GLM prefill shapes.
            func measure(_ label: String, flops: Double, _ body: () -> MLXArray) {
                for _ in 0 ..< 3 { eval(body()) }
                let start = Date()
                let n = 20
                for _ in 0 ..< n { eval(body()) }
                let s = Date().timeIntervalSince(start) / Double(n)
                note(String(format: "gemm %@: %.3f ms, %.1f TFLOPS", label, s * 1000, flops / s / 1e12))
            }
            for (m, k, n) in [(2048, 4096, 4096), (4096, 4096, 4096), (8192, 8192, 8192), (2048, 4096, 1024), (16384, 4096, 1024)] {
                let x = MLXRandom.normal([m, k]).asType(.bfloat16), w = MLXRandom.normal([n, k]).asType(.bfloat16) * 0.02
                eval(x, w)
                measure("bf16 \(m)x\(k)x\(n)", flops: 2.0 * Double(m * k * n)) { matmul(x, w.T) }
                let q = quantized(w, groupSize: 16, bits: 4, mode: .nvfp4)
                eval(q.wq, q.scales)
                measure("nvfp4 \(m)x\(k)x\(n)", flops: 2.0 * Double(m * k * n)) {
                    quantizedMM(x, q.wq, scales: q.scales, biases: q.biases, transpose: true, groupSize: 16, bits: 4, mode: .nvfp4)
                }
                let a = quantized(w, groupSize: 64, bits: 4, mode: .affine)
                eval(a.wq, a.scales)
                measure("affine4 \(m)x\(k)x\(n)", flops: 2.0 * Double(m * k * n)) {
                    quantizedMM(x, a.wq, scales: a.scales, biases: a.biases, transpose: true, groupSize: 64, bits: 4, mode: .affine)
                }
            }
            return
        }
        if arguments.first == "sealedcheck" {
            // The sealed reduce-scatter and all-gather against the sealed all-sum, bit for bit.
            guard let backend = QwenTensorParallelGroup.Backend(rawValue: arguments.dropFirst().first ?? "jaccl") else {
                throw Failure("glm sealedcheck takes jaccl, ring or socket")
            }
            try GLM5NextTensorParallelBench.sealedCollectivesCheck(backend: backend, log: { note($0) })
            return
        }
        if arguments.first == "allsum" {
            let shapes = [[1, 1, 4096], [1, 4, 4096], [1, 2048, 4096]]
            try GLM5NextTensorParallelBench.allSumProbe(shapes: shapes, count: 90, log: { note($0) })
            return
        }
        var fields: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            guard arguments[index].hasPrefix("--"), index + 1 < arguments.count else {
                throw Failure("glm: arguments are --name value pairs")
            }
            fields[arguments[index]] = arguments[index + 1]; index += 2
        }
        guard let modeName = fields["--mode"], let mode = GLM5NextTensorParallelBench.Mode(rawValue: modeName),
              let directory = fields["--model-dir"], directory.hasPrefix("/"),
              let report = fields["--report"], report.hasPrefix("/") else {
            throw Failure("usage: glm --mode full|shard|tp --model-dir /ABS --report /ABS [--prompt-tokens N | --prompt-file /ABS] [--output-count N] [--chunk N] [--repeats N] [--shard-rank R] [--partials float32|stored] [--pipelined yes|no] [--census yes|no] [--reduction native|sealed] [--cache-limit-mb N] [--micro-batches N] [--mtp-depth 0...3] [--mtp-check none|keep-first|one-token] [--mtp-early none|proposals|layers] [--mtp-vocab-split yes|no] [--prefill-schedule chunked|product|merged] [--merged-tokens N] [--keep-prefix yes|no] [--micro-batch-tokens N] [--perplexity yes|no] [--lanes N [--lanes-batched yes|no] [--lanes-split-eval yes|no]] [--kv paged|contiguous] [--sequence-parallel yes|no] [--prefix-grid chunk|bulk] [--pin-selections yes|no] [--micro-batch-rule half|all] [--divergence N [--divergence-rows R] [--divergence-start K[,K2...]]] [--prefill-ops N]")
        }
        let promptCount = Int(fields["--prompt-tokens"] ?? "4096") ?? 4096
        var prompt: [Int]
        if let file = fields["--prompt-file"] {
            // A JSON array of token IDs (e.g. real text through the artifact's tokenizer);
            // with --prompt-tokens, its first N (a prompt-length sweep from one real text).
            prompt = try JSONDecoder().decode([Int].self, from: Data(contentsOf: URL(fileURLWithPath: file)))
            if let value = fields["--prompt-tokens"] {
                guard let count = Int(value), (1 ... prompt.count).contains(count) else {
                    throw Failure("glm: --prompt-tokens with --prompt-file takes 1 through the file's \(prompt.count)")
                }
                prompt = Array(prompt.prefix(count))
            }
        } else {
            var state: UInt64 = 0x2545_F491_4F6C_DD1D
            prompt = (0 ..< promptCount).map { _ -> Int in
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return 1000 + Int((state >> 33) % 120_000)
            }
        }
        var options = GLM5NextTensorParallelBench.Options(modelDirectory: URL(fileURLWithPath: directory), mode: mode,
            shardRank: Int(fields["--shard-rank"] ?? "0") ?? 0, promptTokenIDs: prompt,
            chunkSize: Int(fields["--chunk"] ?? "2048") ?? 2048, outputCount: Int(fields["--output-count"] ?? "64") ?? 64,
            repeats: Int(fields["--repeats"] ?? "2") ?? 2, float32Partials: (fields["--partials"] ?? "float32") == "float32")
        options.pipelinedDecode = (fields["--pipelined"] ?? "no") == "yes"
        options.census = (fields["--census"] ?? "no") == "yes"
        options.sealed = (fields["--reduction"] ?? "native") == "sealed"
        options.cacheLimitBytes = fields["--cache-limit-mb"].flatMap(Int.init).map { $0 << 20 }
        options.microBatches = Int(fields["--micro-batches"] ?? "1") ?? 1
        // NextN proposals per greedy round, as the product's tensor-parallel decode (0: one token per step).
        guard let depth = Int(fields["--mtp-depth"] ?? "0"), (0...3).contains(depth) else {
            throw Failure("glm: --mtp-depth takes 0 through 3")
        }
        options.mtpDepth = depth
        // Speculative decode's arithmetic alone: every proposal rejected, or one-token windows.
        guard let check = GLM5NextTensorParallelBench.Options.MTPCheck(rawValue: fields["--mtp-check"] ?? "none"),
              check == .none || depth > 0 else {
            throw Failure("glm: --mtp-check takes none, keep-first or one-token, with --mtp-depth 1...3")
        }
        options.mtpCheck = check
        options.mtpEarly = fields["--mtp-early"] ?? "proposals"
        options.mtpVocabularySplit = (fields["--mtp-vocab-split"] ?? "yes") == "yes"
        // The product's prefill chunks (`product`), run together as the runtime does (`merged`).
        guard let schedule = GLM5NextTensorParallelBench.Options.PrefillSchedule(
                rawValue: fields["--prefill-schedule"] ?? "chunked"),
              let merged = Int(fields["--merged-tokens"] ?? String(options.mergedTokens)), merged >= 0 else {
            throw Failure("glm: --prefill-schedule takes chunked, product or merged; --merged-tokens a count")
        }
        options.prefillSchedule = schedule
        options.mergedTokens = merged
        options.keepsPrefix = (fields["--keep-prefix"] ?? "yes") == "yes"
        // Micro-batches of at most N rows where the plan's rules allow (rows keep their product
        // selections, so the same tokens); 0: the product's two per chunk.
        if let tokens = fields["--micro-batch-tokens"] {
            guard let value = Int(tokens), value >= 0 else { throw Failure("glm: --micro-batch-tokens takes a count") }
            options.microBatchTokens = value == 0 ? nil : value
        }
        // The prompt's perplexity and greedy next tokens, after the run (the reordering gate).
        options.perplexity = (fields["--perplexity"] ?? "no") == "yes"
        // Prefixes on the bulk grid, the rest as one chunk (an owner decision; changes the tail's bits).
        if let value = fields["--prefix-grid"] {
            guard ["chunk", "bulk"].contains(value) else { throw Failure("glm: --prefix-grid takes chunk or bulk") }
            options.prefixOnBulkGrid = value == "bulk"
        }
        // Re-cut prefills and the probe's other cut keep the product's DSA selections (default yes).
        if let value = fields["--pin-selections"] {
            guard ["yes", "no"].contains(value) else { throw Failure("glm: --pin-selections takes yes or no") }
            options.pinsSelections = value == "yes"
        }
        // Re-cut micro-batches only where each holds at most half its graph's rows (default), or everywhere.
        if let value = fields["--micro-batch-rule"] {
            guard ["half", "all"].contains(value) else { throw Failure("glm: --micro-batch-rule takes half or all") }
            options.hidesSums = value == "half"
        }
        // Prefill frames' command buffers commit after N operations (a thread override; default: the process's).
        if let value = fields["--prefill-ops"] {
            guard let count = Int(value), count > 0 else { throw Failure("glm: --prefill-ops takes a count") }
            options.prefillOperationsPerBuffer = count
        }
        // Diagnostic: where a different micro-batch cut of the first N tokens first changes bits.
        if let value = fields["--divergence"] {
            guard let tokens = Int(value), tokens > 0 else { throw Failure("glm: --divergence takes a token count") }
            options.divergenceTokens = tokens
            if let rows = fields["--divergence-rows"] {
                guard let value = Int(rows), value > 0 else { throw Failure("glm: --divergence-rows takes a row count") }
                options.divergenceMicroBatchTokens = value
            }
            if let offsets = fields["--divergence-start"] {
                let values = offsets.split(separator: ",").compactMap { Int($0) }
                guard !values.isEmpty, values.count == offsets.split(separator: ",").count, values.allSatisfy({ $0 >= 0 }) else {
                    throw Failure("glm: --divergence-start takes token offsets (K or K1,K2,...)")
                }
                options.divergenceStarts = values
            }
        }
        // Several requests decoding together (MTP rounds batched in one forward, or time-sliced).
        guard let lanes = Int(fields["--lanes"] ?? "1"), (1...8).contains(lanes), lanes == 1 || depth > 0 else {
            throw Failure("glm: --lanes takes 1 through 8, and more than one needs --mtp-depth")
        }
        options.lanes = lanes
        options.lanesBatched = (fields["--lanes-batched"] ?? "yes") == "yes"
        options.lanesSplitEval = (fields["--lanes-split-eval"] ?? "no") == "yes"
        // DSA and NextN histories: paged as the product's runtime, or contiguous (A/B).
        let kv = fields["--kv"] ?? "paged"
        guard ["paged", "contiguous"].contains(kv) else {
            throw Failure("glm: --kv takes paged or contiguous")
        }
        options.pagedKV = kv == "paged"
        // Routers and DSA selections on each rank's half of the rows (tp only; same bits).
        if let value = fields["--sequence-parallel"] { options.sequenceParallel = value == "yes" }
        let result = try GLM5NextTensorParallelBench.run(options, log: { note($0) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(result).write(to: URL(fileURLWithPath: report), options: [.withoutOverwriting])
        note("report \(report)")
    }
}
