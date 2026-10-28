import DarkbloomClusterRuntime
import Foundation
import MLX

// darkbloom-cluster-tp-check qwen-prefill --model-dir /ABS [--rank R] [--shares A:B] [--prompt-tokens N]
//     [--chunks 512,1024] [--ops 0,16,100] [--strides 0,1] [--modes local,cpu-hop] [--repeats N]
//     [--layers yes|no] [--gemm yes|no] [--gemm-rows 512,1024]
// One Qwen tensor-parallel rank's prompt prefill on this Mac with no peer
// (QwenTensorParallelPrefillBench): the product's request-owned prefill
// timed per frame, per layer and per projection. Diagnostic only: the
// outputs are not a tensor-parallel result.
enum QwenPrefillBench {
    static func run(_ arguments: [String]) throws {
        var fields: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            guard arguments[index].hasPrefix("--"), index + 1 < arguments.count else {
                throw Failure("qwen-prefill: arguments are --name value pairs")
            }
            fields[arguments[index]] = arguments[index + 1]; index += 2
        }
        guard let directory = fields["--model-dir"], directory.hasPrefix("/") else {
            throw Failure("usage: qwen-prefill --model-dir /ABS [--rank R] [--shares A:B] [--prompt-tokens N] [--chunks 512,1024] [--ops 0,16,100] [--strides 0,1] [--modes local,cpu-hop] [--repeats N] [--layers yes|no] [--gemm yes|no] [--gemm-rows 512]")
        }
        func list(_ name: String, _ fallback: [Int]) throws -> [Int] {
            guard let text = fields[name] else { return fallback }
            let values = text.split(separator: ",").compactMap { Int($0) }
            guard !values.isEmpty, values.count == text.split(separator: ",").count else { throw Failure("\(name) takes integers") }
            return values
        }
        var options = QwenTensorParallelPrefillBench.Options(modelDirectory: URL(fileURLWithPath: directory, isDirectory: true))
        options.rank = Int(fields["--rank"] ?? "0") ?? 0
        if let shares = fields["--shares"] {
            let parts = shares.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2 else { throw Failure("--shares takes A:B") }
            options.shares = parts
        }
        options.promptTokens = Int(fields["--prompt-tokens"] ?? "4096") ?? 4096
        options.chunks = try list("--chunks", [512])
        options.operations = try list("--ops", [0])
        options.strides = try list("--strides", [0])
        options.modes = try (fields["--modes"] ?? "local").split(separator: ",").map {
            guard let mode = QwenTensorParallelPrefillBench.Mode(rawValue: String($0)) else { throw Failure("--modes takes local,cpu-hop") }
            return mode
        }
        options.repeats = Int(fields["--repeats"] ?? "1") ?? 1
        options.layers = fields["--layers"] == "yes"
        options.gemm = fields["--gemm"] == "yes"
        options.gemmRows = try list("--gemm-rows", [512])
        try Device.withDefaultDevice(.gpu) {
            try QwenTensorParallelPrefillBench.run(options) { line in
                FileHandle.standardOutput.write(Data((line + "\n").utf8))
            }
        }
    }
}
