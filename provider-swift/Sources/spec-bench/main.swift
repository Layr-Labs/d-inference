// spec-bench — single-node SPECULATIVE decoding benchmark.
//
//   swift run -c release spec-bench <target-dir> <draft-dir> [maxTokens=96] [iterations=4] [K=4]
//
// A small draft model proposes K tokens; the large target model verifies them in
// one forward pass, accepting the longest agreeing prefix. For greedy (temp=0)
// the output is token-identical to the target alone — this is pure latency win,
// 2-3x typical, topology-independent (helps single-node AND clustered decode).
//
// Compare against `solo-bench <target-dir>` (plain decode, same prompt/maxTokens)
// to read the speedup. Uses the fork's SpeculativeTokenIterator via the
// MLXLMCommon.generate(...draftModel:numDraftTokens:) overload — no new model code.
//
// Draft + target MUST share a tokenizer (llama-1b and llama-8b have byte-identical
// tokenizer.json, so token ids are interchangeable).

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import ProviderCore

func die(_ m: String) -> Never { FileHandle.standardError.write(Data("ERROR: \(m)\n".utf8)); exit(1) }

let argv = CommandLine.arguments
guard argv.count >= 3 else { die("usage: spec-bench <target-dir> <draft-dir> [maxTokens=96] [iterations=4] [K=4]") }
let targetDir = URL(fileURLWithPath: argv[1], isDirectory: true)
let draftDir = URL(fileURLWithPath: argv[2], isDirectory: true)
let maxTokens = argv.count > 3 ? (Int(argv[3]) ?? 96) : 96
let iterations = argv.count > 4 ? (Int(argv[4]) ?? 4) : 4
let K = argv.count > 5 ? (Int(argv[5]) ?? 4) : 4
let prompt = "Explain pipeline parallelism in two sentences."

let physical = ProcessInfo.processInfo.physicalMemory
MLX.GPU.set(memoryLimit: Int(Double(physical) * 0.80), relaxed: false)

print("spec-bench: target=\(targetDir.lastPathComponent) draft=\(draftDir.lastPathComponent) K=\(K) maxTokens=\(maxTokens) iterations=\(iterations)")
let targetContainer = try await LLMModelFactory.shared.loadContainer(
    from: targetDir, using: LocalTokenizerLoader())
print("models loading …")

let rawMessages: [MLXLMCommon.Message] = [["role": "user", "content": prompt]]

// Run all iterations inside ONE perform so the draft model is loaded once and
// stays within the target container's isolation domain (it's non-Sendable).
try await targetContainer.perform { context in
    let draftContext = try await LLMModelFactory.shared.load(
        from: draftDir, using: LocalTokenizerLoader())
    let draftModel = draftContext.model
    FileHandle.standardError.write(Data("models loaded.\n\n".utf8))

    for i in 1...iterations {
        let start = ContinuousClock.now
        var firstTokenAt: ContinuousClock.Instant?
        var completion = 0

        let input = try await context.processor.prepare(input: UserInput(messages: rawMessages))
        let params = GenerateParameters(maxTokens: maxTokens, temperature: 0.0, topP: 1.0, topK: 0)
        let stream = try MLXLMCommon.generate(
            input: input, parameters: params, context: context,
            draftModel: draftModel, numDraftTokens: K)

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
}
