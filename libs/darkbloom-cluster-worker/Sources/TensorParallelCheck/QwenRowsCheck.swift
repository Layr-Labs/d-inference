import DarkbloomClusterRuntime
import Foundation
import MLX

// Qwen3.8-27B rows at the registered per-rank widths on two ranks of one Mac
// (`QwenTensorParallelRowsCheck`): random weights or a registered checkpoint's
// files read directly, never a model pass.
//   darkbloom-cluster-tp-check qwen-rows synthesize --output /DIR [--layers 4]
//   MLX_RANK=0|1 MLX_HOSTFILE=hosts.json darkbloom-cluster-tp-check qwen-rows run --model-dir /DIR \
//       --report FILE [--backend ring|socket] [--reduction native|sealed-bench]
// Each rank compares its own digests (a row alone, in cohorts, across KV
// segments, observed, in verify windows) and both agree on the verdict.
// `layers` (same options, [--target 7 --other 6]) reports the first decoder
// layer where a row's step beside another leaves its solo bits.
enum QwenRowsCheck {
    static func run(_ arguments: [String]) throws {
        guard let command = arguments.first, ["synthesize", "run", "layers"].contains(command) else {
            throw Failure("usage: darkbloom-cluster-tp-check qwen-rows synthesize|run|layers ...")
        }
        var options: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            guard arguments[index].hasPrefix("--"), index + 1 < arguments.count else {
                throw Failure("qwen-rows: expected --name value pairs")
            }
            options[String(arguments[index].dropFirst(2))] = arguments[index + 1]
            index += 2
        }
        if command == "synthesize" {
            guard let output = options["output"], output.hasPrefix("/") else { throw Failure("synthesize needs --output /DIR") }
            // Layer 4 is the first attention layer; the rows check needs one.
            guard let layers = Int(options["layers"] ?? "4"), (4...8).contains(layers) else {
                throw Failure("--layers takes 4 to 8")
            }
            try Device.withDefaultDevice(.gpu) {
                try QwenTensorParallelRowsCheck.writeCheckpoint(directory: URL(fileURLWithPath: output), layers: layers)
            }
            note("real-geometry checkpoint written (\(layers) layers)")
            return
        }
        guard let directory = options["model-dir"], let reportPath = options["report"] else {
            throw Failure("\(command) needs --model-dir and --report")
        }
        guard let target = Int(options["target"] ?? "7"), let other = Int(options["other"] ?? "6") else {
            throw Failure("--target and --other take row numbers")
        }
        guard let backend = QwenTensorParallelGroup.Backend(rawValue: options["backend"] ?? "ring"), backend != .jaccl else {
            throw Failure("qwen-rows runs on the loopback ring or socket only")
        }
        let reduction = options["reduction"] ?? "native"
        guard ["native", "sealed-bench"].contains(reduction) else { throw Failure("--reduction takes native or sealed-bench") }
        let url = URL(fileURLWithPath: directory)
        let configuration = try Data(contentsOf: url.appendingPathComponent("config.json"))
        let group = try QwenTensorParallelGroup(backend: backend)
        // Ranks running other commands or rows would pair different collectives.
        let work = command == "layers" ? "layers \(target) \(other)" : command
        guard try group.digestsEqual(fnv(sha256Hex(configuration) + "|" + reduction + "|" + work)) else {
            throw Failure("the ranks disagree on the checkpoint, the reduction or the command")
        }
        if reduction == "sealed-bench" {
            let codec = try QwenTensorParallelSealCodec.bench(group: group,
                scope: Data(("darkbloom-tp-qwen-rows-v1|" + sha256Hex(configuration)).utf8))
            try codec.install()
            group.sealed = codec
        }
        note("rank \(group.rank) of \(group.size) over \(backend.rawValue), \(reduction) sums")
        if command == "layers" {
            let lines = try Device.withDefaultDevice(.gpu) { () throws -> [String] in
                let model = try QwenTensorParallelModel.load(modelDirectory: url, role: .shard(rank: group.rank, size: 2),
                    reduction: group)
                return try QwenTensorParallelRowsCheck.firstDifferingLayers(model: model, configuration: configuration,
                    target: target, other: other)
            }
            try lines.joined(separator: "\n").write(toFile: reportPath, atomically: true, encoding: .utf8)
            lines.forEach { note($0) }
            return
        }
        let report = try Device.withDefaultDevice(.gpu) { () throws -> QwenTensorParallelRowsCheck.Report in
            let model = try QwenTensorParallelModel.load(modelDirectory: url, role: .shard(rank: group.rank, size: 2),
                reduction: group)
            return try QwenTensorParallelRowsCheck.run(model: model, configuration: configuration, rank: group.rank)
        }
        let bothPassed = try group.exchangeIntegers([report.passed ? 1 : 0]) == [2]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard FileManager.default.createFile(atPath: reportPath, contents: try encoder.encode(report)) else {
            throw Failure("could not write the report")
        }
        note("compared \(report.compared) digests, \(report.differing.count) differ\(report.differing.isEmpty ? "" : ": \(report.differing.prefix(8))");"
            + " both ranks passed: \(bothPassed)")
        guard bothPassed else { throw Failure("a rank found a row that differs from itself alone") }
    }
}
