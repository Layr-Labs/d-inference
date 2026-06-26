// loop-diag — single-machine diagnostic harness that isolates the cluster
// decode-loop OVERHEAD from the NETWORK cost.
//
//   swift run -c release loop-diag <model-dir> [maxTokens=96] [iterations=4]
//
// We have two decode paths on Apple Silicon MLX-Swift:
//   * solo-bench: uses MLX's native MLXLMCommon.generate (one lazy graph per
//     token, async, minimal syncs). ~57 tok/s for gpt-oss-20b on this machine.
//   * ClusterPipeline: a hand-rolled distributed decode loop — manual argMax
//     sampling, evalEvery:4 mid-layer eval chopping, and ~4-6 .eval() barriers
//     per token, plus per-token encrypt/serialize. ~9-12 tok/s clustered across
//     two machines.
//
// This harness runs the CLUSTER'S LOOP DISCIPLINE on ONE machine with the FULL
// model and NO network / group collectives (no send/recv/all_gather). So its
// tok/s vs solo-bench's tok/s isolates the PURE LOOP OVERHEAD — eval barriers,
// manual argMax sampling, evalEvery:4 — from the network hop + pipeline bubble.
//
// It mirrors ClusterPipeline.generate EXACTLY for a single node that is both
// head AND tail (one shard owns the whole model):
//   hidden = shard.embed(tokens:)            // step 0 = full prompt, else last token
//   hidden = shard.runOwnedLayers(hidden)    // already does evalEvery:4 internally
//   let logits = shard.projectToLogits(hidden)
//   let ids = argMax(logits, axis: logits.ndim - 1); ids.eval()   // SAME manual
//                                                                  // sample + barrier
// The send/recv/all_gather collectives are the NETWORK parts — they are OMITTED
// here. Everything else (the sampling + eval-barrier discipline) is preserved.
//
// NOT a product. Companion to solo-bench / cluster-run.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import ProviderCore

func die(_ m: String) -> Never { FileHandle.standardError.write(Data("ERROR: \(m)\n".utf8)); exit(1) }

let argv = CommandLine.arguments
guard argv.count >= 2 else { die("usage: loop-diag <model-dir> [maxTokens=96] [iterations=4]") }
let modelDir = URL(fileURLWithPath: argv[1], isDirectory: true)
let maxTokens = argv.count > 2 ? (Int(argv[2]) ?? 96) : 96
let iterations = argv.count > 3 ? (Int(argv[3]) ?? 4) : 4
let prompt = "Explain pipeline parallelism in two sentences."

// ---- config.json reads (mirror ClusterHeadBringup / cluster-run) ----
func configInt(_ dir: URL, _ key: String) -> Int {
    guard let data = try? Data(contentsOf: dir.appending(component: "config.json")),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let v = obj[key] as? Int else { die("cannot read \(key) from config.json") }
    return v
}
func modelTypeFromConfig(_ dir: URL) -> String {
    guard let data = try? Data(contentsOf: dir.appending(component: "config.json")),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let t = obj["model_type"] as? String else { return "llama" }
    return t
}

let numLayers = configInt(modelDir, "num_hidden_layers")
let modelType = modelTypeFromConfig(modelDir)

// Match the cluster runs' GPU memory posture (same line as solo-bench /
// ClusterHeadBringup). The deprecated relaxed: flag warning is expected.
let physical = ProcessInfo.processInfo.physicalMemory
MLX.GPU.set(memoryLimit: Int(Double(physical) * 0.80), relaxed: false)

print("loop-diag: \(modelDir.lastPathComponent), model_type=\(modelType), layers=\(numLayers), maxTokens=\(maxTokens), iterations=\(iterations)")

// ---- load the FULL model as ONE shard (interval covers all layers) ----
// One shard owns 0..<numLayers, so it is simultaneously head (embeds) and tail
// (projects to logits) — exactly what ClusterPipeline runs, minus the ring.
let interval = LayerInterval(nodeId: "loop-diag", start: 0, end: numLayers)
let shard: any PipelineModelShard
do {
    switch modelType {
    case "gpt_oss":
        shard = try GPTOSSShardAdapter.load(directory: modelDir, interval: interval)
    case "gemma4", "gemma4_text":
        shard = try Gemma4ShardAdapter.load(directory: modelDir, interval: interval)
    default:
        die("unsupported model_type '\(modelType)' (have: gpt_oss, gemma4)")
    }
} catch { die("shard load failed: \(error)") }
print("model loaded.\n")

// ---- tokenizer + chat template (mirror cluster-run) ----
let tokenizer: any Tokenizer
do { tokenizer = try await LocalTokenizerLoader().load(from: modelDir) }
catch { die("tokenizer load failed: \(error)") }

let promptTokens: [Int]
do {
    promptTokens = try tokenizer.applyChatTemplate(
        messages: [["role": "user", "content": prompt]], tools: nil, additionalContext: nil)
} catch { die("tokenize failed: \(error)") }

let eosTokenId = tokenizer.eosTokenId

// ---- decode loop: ClusterPipeline.generate, single-node, NO collectives ----
for i in 1...iterations {
    var seq = promptTokens
    var generated = [Int]()
    var prefillNs: UInt64 = 0
    var decodeNs: UInt64 = 0

    for step in 0..<maxTokens {
        let stepStart = DispatchTime.now().uptimeNanoseconds

        // step 0 = whole prompt (prefill); else just the most-recent token.
        let inputTokens: [Int] = step == 0 ? seq : [seq[seq.count - 1]]

        // HEAD: embed. (Cluster non-head ranks would recv hidden over the wire;
        // single-node here is always head, so always embed — no recv.)
        var hidden = shard.embed(tokens: inputTokens)

        // Owned layers — this already does evalEvery:4 internally (same as the
        // cluster). One shard owns ALL layers here.
        hidden = shard.runOwnedLayers(hidden)

        // (Cluster non-tail ranks would seal + send hidden here — OMITTED, no
        // network.) TAIL: project to logits, manual argMax, eval barrier — the
        // SAME sampling discipline as ClusterPipeline's tail.
        let logits = shard.projectToLogits(hidden)
        let ids = argMax(logits, axis: logits.ndim - 1)
        ids.eval()
        let nextToken = Int(ids.asArray(Int32.self).last ?? 0)

        // (Cluster all_gather token broadcast OMITTED — single node already has
        // the token; no collective.)
        seq.append(nextToken)
        generated.append(nextToken)

        let stepNs = DispatchTime.now().uptimeNanoseconds - stepStart
        if step == 0 { prefillNs = stepNs } else { decodeNs += stepNs }

        if let eos = eosTokenId, nextToken == eos { break }
    }

    // Steady-state decode tok/s = decode tokens (excluding the first produced
    // token) over the summed decode-step wall time. Match solo-bench's format.
    let totalNs = prefillNs + decodeNs
    let totalS = Double(totalNs) / 1_000_000_000
    let prefillS = Double(prefillNs) / 1_000_000_000
    let decodeS = max(0.0001, Double(decodeNs) / 1_000_000_000)
    let decodeToks = max(1, generated.count - 1)
    let tps = Double(decodeToks) / decodeS
    let tag = i == 1 ? " (cold — discard)" : ""
    print(String(format: "iter %d: %d tok in %.2fs · prefill %.2fs · decode %.2f tok/s%@",
                 i, generated.count, totalS, prefillS, tps, tag))
}
