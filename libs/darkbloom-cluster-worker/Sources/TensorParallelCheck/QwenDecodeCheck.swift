import DarkbloomClusterRuntime
import Foundation
import MLX

// The batch driver's plain decode on two ranks (`QwenTensorParallelDecodeBench`), of one Mac over the loopback
// ring or socket, or of two Macs over JACCL (`--backend jaccl`, with the JACCL_* environment of a pair):
//   MLX_RANK=0|1 MLX_HOSTFILE=hosts.json darkbloom-cluster-tp-check qwen-decode --model-dir /DIR \
//       [--backend ring|socket|jaccl] [--reduction native|sealed-bench] [--width 1] [--prompt-tokens 32] \
//       [--output-tokens 64] [--sampled 0|1] [--control exchanged,folded] [--repeats 3] [--answer-delay-us 0] \
//       [--layer-strides 1,8,16 (decode layer strides to compare, 0 = whole step; default: the product's,
//        `QwenTensorParallelLaunch.decodeLayerStride`)] \
//       [--build-ahead 0,1 (read-then-build and/or the driver's build-ahead, folded control only; default 0)]
// Each rank logs every run's decode step time and token digest; both agree
// that every run retired the same tokens. Loopback timings show a step's host
// work and synchronization, never a pair's; JACCL timings are the pair's.
enum QwenDecodeCheck {
    static func run(_ arguments: [String]) throws {
        var options: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            guard arguments[index].hasPrefix("--"), index + 1 < arguments.count else {
                throw Failure("qwen-decode: expected --name value pairs")
            }
            options[String(arguments[index].dropFirst(2))] = arguments[index + 1]
            index += 2
        }
        guard let directory = options["model-dir"], directory.hasPrefix("/") else {
            throw Failure("qwen-decode needs --model-dir /DIR")
        }
        guard let backend = QwenTensorParallelGroup.Backend(rawValue: options["backend"] ?? "ring") else {
            throw Failure("qwen-decode takes --backend ring, socket or jaccl")
        }
        let strides: [Int?] = try options["layer-strides"].map { list in
            try list.split(separator: ",", omittingEmptySubsequences: false).map { text -> Int? in
                guard let value = Int(text), (0...64).contains(value) else { throw Failure("--layer-strides takes 0-64 each") }
                return value
            }
        } ?? [nil]
        let reduction = options["reduction"] ?? "sealed-bench"
        guard ["native", "sealed-bench"].contains(reduction) else { throw Failure("--reduction takes native or sealed-bench") }
        let controls = (options["control"] ?? "exchanged,folded").split(separator: ",").map(String.init)
        let aheads = try (options["build-ahead"] ?? "0").split(separator: ",").map { value -> Bool in
            guard value == "0" || value == "1" else { throw Failure("--build-ahead takes 0, 1 or 0,1") }
            return value == "1"
        }
        guard !aheads.contains(true) || controls == ["folded"] else {
            throw Failure("--build-ahead 1 runs with --control folded only")
        }
        guard let width = Int(options["width"] ?? "1"), (1...8).contains(width),
              let prompt = Int(options["prompt-tokens"] ?? "32"), prompt > 0,
              let output = Int(options["output-tokens"] ?? "64"), output > 1,
              let repeats = Int(options["repeats"] ?? "3"), repeats > 0,
              let delay = Int(options["answer-delay-us"] ?? "0"), delay >= 0,
              let sampled = Int(options["sampled"] ?? "0"), [0, 1].contains(sampled),
              !controls.isEmpty, controls.allSatisfy({ ["exchanged", "folded"].contains($0) }) else {
            throw Failure("--width 1-8, positive --prompt-tokens, --output-tokens > 1, --repeats, --answer-delay-us >= 0,"
                + " --sampled 0|1, --control exchanged,folded")
        }
        let url = URL(fileURLWithPath: directory)
        let configuration = try Data(contentsOf: url.appendingPathComponent("config.json"))
        let group = try QwenTensorParallelGroup(backend: backend)
        let work = "\(reduction)|\(width)|\(prompt)|\(output)|\(sampled)|\(controls)|\(repeats)|\(delay)|\(strides.map { $0.map(String.init) ?? "product" })|ahead=\(aheads)"
        guard try group.digestsEqual(fnv(sha256Hex(configuration) + "|" + work)) else {
            throw Failure("the ranks disagree on the checkpoint or the runs")
        }
        if reduction == "sealed-bench" {
            let codec = try QwenTensorParallelSealCodec.bench(group: group,
                scope: Data(("darkbloom-tp-qwen-decode-v1|" + sha256Hex(configuration)).utf8))
            try codec.install()
            group.sealed = codec
        }
        note("rank \(group.rank) of \(group.size) over \(backend.rawValue), \(reduction) sums")
        let same = try Device.withDefaultDevice(.gpu) { () throws -> Bool in
            let model = try QwenTensorParallelModel.load(modelDirectory: url, role: .shard(rank: group.rank, size: 2),
                reduction: group)
            var same = true
            for stride in strides {
                let label = stride.map(String.init) ?? "product"
                note("decode layer stride \(label)")
                same = try QwenTensorParallelDecodeBench.pair(model: model, configuration: configuration, group: group,
                    width: width, promptTokens: prompt, outputTokens: output, sampled: sampled == 1,
                    folds: controls.map { $0 == "folded" }, repeats: repeats, answerDelayMicroseconds: delay,
                    layerStride: stride, buildsAhead: aheads) { line in
                    FileHandle.standardOutput.write(Data((line + " stride=\(label)\n").utf8))
                } && same
            }
            return same
        }
        let both = try group.exchangeIntegers([same ? 1 : 0]) == [2]
        note("both ranks retired the same tokens in every run: \(both)")
        guard both else { throw Failure("folded control changed a retired token") }
    }
}
