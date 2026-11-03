import DarkbloomClusterRuntime
import Foundation
import MLX

// A Qwen tensor-parallel prompt on two ranks of one Mac, one frame a step and
// in merged wavefront steps (`QwenTensorParallelPrefillBench.pair`):
//   MLX_RANK=0|1 MLX_HOSTFILE=hosts.json darkbloom-cluster-tp-check qwen-wavefront --model-dir /DIR \
//       [--backend ring|socket] [--reduction native|sealed-bench] [--prompt-tokens 4096] [--chunk 512] \
//       [--output-tokens 8] [--wavefronts 1,2,8] [--repeats 1]
// Each rank logs every run's step times, peak memory and digests; both agree
// that every run left the same bytes. Loopback timings show the overlap, never
// a pair's. `--output-tokens` sets the request's context past the prompt.
enum QwenWavefrontCheck {
    static func run(_ arguments: [String]) throws {
        var options: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            guard arguments[index].hasPrefix("--"), index + 1 < arguments.count else {
                throw Failure("qwen-wavefront: expected --name value pairs")
            }
            options[String(arguments[index].dropFirst(2))] = arguments[index + 1]
            index += 2
        }
        guard let directory = options["model-dir"], directory.hasPrefix("/") else {
            throw Failure("qwen-wavefront needs --model-dir /DIR")
        }
        guard let backend = QwenTensorParallelGroup.Backend(rawValue: options["backend"] ?? "ring"), backend != .jaccl else {
            throw Failure("qwen-wavefront runs on the loopback ring or socket only")
        }
        let reduction = options["reduction"] ?? "sealed-bench"
        guard ["native", "sealed-bench"].contains(reduction) else { throw Failure("--reduction takes native or sealed-bench") }
        let wavefronts = (options["wavefronts"] ?? "1,2,8").split(separator: ",").compactMap { Int($0) }
        guard let prompt = Int(options["prompt-tokens"] ?? "4096"), prompt > 0,
              let chunk = Int(options["chunk"] ?? "512"), chunk > 0, let repeats = Int(options["repeats"] ?? "1"),
              let output = Int(options["output-tokens"] ?? "8"), output > 0,
              !wavefronts.isEmpty, wavefronts.allSatisfy({ (1...8).contains($0) }) else {
            throw Failure("--prompt-tokens, --chunk, --output-tokens and --repeats take positive integers, --wavefronts 1 to 8")
        }
        let url = URL(fileURLWithPath: directory)
        let configuration = try Data(contentsOf: url.appendingPathComponent("config.json"))
        let group = try QwenTensorParallelGroup(backend: backend)
        let work = "\(reduction)|\(prompt)|\(chunk)|\(output)|\(wavefronts)|\(repeats)"
        guard try group.digestsEqual(fnv(sha256Hex(configuration) + "|" + work)) else {
            throw Failure("the ranks disagree on the checkpoint or the runs")
        }
        if reduction == "sealed-bench" {
            let codec = try QwenTensorParallelSealCodec.bench(group: group,
                scope: Data(("darkbloom-tp-qwen-wavefront-v1|" + sha256Hex(configuration)).utf8))
            try codec.install()
            group.sealed = codec
        }
        note("rank \(group.rank) of \(group.size) over \(backend.rawValue), \(reduction) sums")
        let same = try Device.withDefaultDevice(.gpu) { () throws -> Bool in
            let model = try QwenTensorParallelModel.load(modelDirectory: url, role: .shard(rank: group.rank, size: 2),
                reduction: group)
            return try QwenTensorParallelPrefillBench.pair(model: model, configuration: configuration,
                promptTokens: prompt, chunk: chunk, outputTokens: output, wavefronts: wavefronts, repeats: repeats) { line in
                FileHandle.standardOutput.write(Data((line + "\n").utf8))
            }
        }
        let both = try group.exchangeIntegers([same ? 1 : 0]) == [2]
        note("both ranks left the same bytes in every run: \(both)")
        guard both else { throw Failure("a merged prompt left other bytes than one frame a step") }
    }
}
