// solo-bench — single-node decode benchmark, pointed straight at a model dir.
//
//   swift run -c release solo-bench <model-dir> [maxTokens] [iterations]
//
// Bypasses the coordinator/scanner machinery of `darkbloom benchmark` (which
// resolves models from the HF hub cache + advertised-model config). This loads
// the model directly with the same MLX-Swift LLM API the provider uses and
// reports steady-state decode tok/s — the single-node baseline to compare
// against the cluster's pipeline-parallel numbers.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import ProviderCore

func die(_ m: String) -> Never { FileHandle.standardError.write(Data("ERROR: \(m)\n".utf8)); exit(1) }

let argv = CommandLine.arguments
guard argv.count >= 2 else { die("usage: solo-bench <model-dir> [maxTokens=96] [iterations=4]") }
let modelDir = URL(fileURLWithPath: argv[1], isDirectory: true)
let maxTokens = argv.count > 2 ? (Int(argv[2]) ?? 96) : 96
let iterations = argv.count > 3 ? (Int(argv[3]) ?? 4) : 4
let prompt = "Explain pipeline parallelism in two sentences."

// Match the cluster runs' GPU memory posture.
let physical = ProcessInfo.processInfo.physicalMemory
MLX.GPU.set(memoryLimit: Int(Double(physical) * 0.80), relaxed: false)

print("solo-bench: \(modelDir.lastPathComponent), maxTokens=\(maxTokens), iterations=\(iterations)")
let container = try await LLMModelFactory.shared.loadContainer(
    from: modelDir, using: LocalTokenizerLoader())
print("model loaded.\n")

let rawMessages: [MLXLMCommon.Message] = [["role": "user", "content": prompt]]

for i in 1...iterations {
    let start = ContinuousClock.now
    var firstTokenAt: ContinuousClock.Instant?
    var completion = 0

    let stream: AsyncStream<Generation> = try await container.perform { context in
        let input = try await context.processor.prepare(input: UserInput(messages: rawMessages))
        let params = GenerateParameters(maxTokens: maxTokens, temperature: 0.0, topP: 1.0, topK: 0)
        return try MLXLMCommon.generate(input: input, parameters: params, context: context)
    }

    for await gen in stream {
        switch gen {
        case .chunk:
            if firstTokenAt == nil { firstTokenAt = .now }
            completion += 1
        case .info(let info):
            if completion == 0 { completion = info.generationTokenCount }
        case .toolCall: break
        }
    }

    let total = ContinuousClock.now - start
    let totalS = Double(total.components.seconds) + Double(total.components.attoseconds) / 1e18
    let prefillS: Double = {
        guard let f = firstTokenAt else { return 0 }
        let d = f - start
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }()
    let decodeS = max(0.0001, totalS - prefillS)
    let decodeToks = max(1, completion - 1)
    let tps = Double(decodeToks) / decodeS
    let tag = i == 1 ? " (cold — discard)" : ""
    print(String(format: "iter %d: %d tok in %.2fs · prefill %.2fs · decode %.2f tok/s%@",
                 i, completion, totalS, prefillS, tps, tag))
}
