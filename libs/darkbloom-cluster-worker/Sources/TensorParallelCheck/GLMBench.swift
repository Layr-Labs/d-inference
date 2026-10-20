import DarkbloomClusterRuntime
import Darwin
import Foundation

// darkbloom-cluster-tp-check glm --mode full|shard|tp --model-dir DIR --report FILE
//     [--prompt-tokens N | --prompt-file TOKENS.json] [--output-count N] [--chunk N] [--repeats N]
//     [--shard-rank R] [--partials float32|stored] [--pipelined yes|no] [--census yes|no]
//     [--reduction native|sealed] [--cache-limit-mb N] [--micro-batches N]
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
            throw Failure("usage: glm --mode full|shard|tp --model-dir /ABS --report /ABS [--prompt-tokens N | --prompt-file /ABS] [--output-count N] [--chunk N] [--repeats N] [--shard-rank R] [--partials float32|stored] [--pipelined yes|no] [--census yes|no] [--reduction native|sealed] [--cache-limit-mb N] [--micro-batches N]")
        }
        let promptCount = Int(fields["--prompt-tokens"] ?? "4096") ?? 4096
        var prompt: [Int]
        if let file = fields["--prompt-file"] {
            // A JSON array of token IDs (e.g. real text through the artifact's tokenizer).
            prompt = try JSONDecoder().decode([Int].self, from: Data(contentsOf: URL(fileURLWithPath: file)))
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
        let result = try GLM5NextTensorParallelBench.run(options, log: { note($0) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(result).write(to: URL(fileURLWithPath: report), options: [.withoutOverwriting])
        note("report \(report)")
    }
}
