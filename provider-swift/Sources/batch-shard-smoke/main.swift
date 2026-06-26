// batch-shard-smoke — Phase 1 correctness oracle for batched sharded decode.
//
//   swift run -c release batch-shard-smoke <model-dir> [B=4] [maxTokens=32]
//
// Single machine, NO ring. Loads the FULL model as one shard (interval
// [0, N)) — so embed → runOwnedLayers → projectToLogits is the whole forward —
// and runs TWO greedy decodes of the same prompt:
//   (1) B=1 reference via the scalar path (embed/runOwnedLayers/projectToLogits
//       + a KVCacheSimple), exactly like ClusterPipeline does at worldSize=1.
//   (2) B identical rows via the BATCHED path (embedBatch/runOwnedLayersBatched/
//       projectToLogitsBatched + BatchKVCache).
// Asserts every batched row produces the SAME token stream as the reference.
// This proves the batched data plane (shapes, BatchKVCache, [B] sampling) is
// numerically identical to the proven B=1 path, with no network involved.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import ProviderCore

func fail(_ m: String) -> Never { FileHandle.standardError.write(Data("FAIL: \(m)\n".utf8)); exit(1) }

let args = CommandLine.arguments
guard args.count >= 2 else { fail("usage: batch-shard-smoke <model-dir> [B] [maxTokens]") }
let modelDir = URL(fileURLWithPath: args[1], isDirectory: true)
let B = args.count > 2 ? (Int(args[2]) ?? 4) : 4
let maxTokens = args.count > 3 ? (Int(args[3]) ?? 32) : 32

let physical = ProcessInfo.processInfo.physicalMemory
MLX.GPU.set(memoryLimit: Int(Double(physical) * 0.80), relaxed: false)

// ---- model_type + layer count from config.json ----
func configValue<T>(_ key: String, _ cast: (Any) -> T?) -> T? {
    guard let data = try? Data(contentsOf: modelDir.appending(component: "config.json")),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let v = obj[key] else { return nil }
    return cast(v)
}
let modelType = configValue("model_type", { $0 as? String }) ?? "llama"
let numLayers = configValue("num_hidden_layers", { $0 as? Int }) ?? 0
guard numLayers > 0 else { fail("could not read num_hidden_layers") }

print("== batch-shard-smoke == model=\(modelDir.lastPathComponent) type=\(modelType) layers=\(numLayers) B=\(B) maxTokens=\(maxTokens)")

func makeShard() throws -> any PipelineModelShard {
    let full = LayerInterval(nodeId: "solo", start: 0, end: numLayers)
    switch modelType {
    case "gpt_oss": return try GPTOSSShardAdapter.load(directory: modelDir, interval: full)
    case "gemma4", "gemma4_text": return try Gemma4ShardAdapter.load(directory: modelDir, interval: full)
    default: fatalError("unsupported model_type '\(modelType)' (have: gpt_oss, gemma4)")
    }
}

// Tokenize prompts via the same path the cluster uses. `--ragged` (4th arg
// "ragged") makes the B rows DIFFERENT lengths to exercise Phase 2 left-padding.
let ragged = args.count > 4 && args[4] == "ragged"
let tokenizer = try await LocalTokenizerLoader().load(from: modelDir)
func tok(_ s: String) throws -> [Int] {
    try tokenizer.applyChatTemplate(messages: [["role": "user", "content": s]], tools: nil, additionalContext: nil)
}
let basePrompt = "Name three primary colors."
let prompt = try tok(basePrompt)
// For ragged mode, build B prompts of deliberately different lengths.
let raggedPrompts: [[Int]] = ragged
    ? [try tok("Hi."),
       try tok("Name three primary colors."),
       try tok("Explain in one sentence what a rainbow is and why it appears."),
       try tok("List the days of the week, then count from one to five.")]
    : []
let eos: Set<Int> = { var s = Set<Int>(); if let e = tokenizer.eosTokenId { s.insert(e) }; return s }()

func argmaxLast(_ logits: MLXArray) -> [Int] {
    // logits [B, *, vocab] -> [B] argmax at last position
    let last = logits.ndim == 3 ? logits[0..., (logits.dim(1) - 1)..., 0...] : logits
    let ids = argMax(last, axis: last.ndim - 1)   // [B, 1] or [B]
    ids.eval()
    return ids.asArray(Int32.self).map { Int($0) }
}

// The B prompts: identical in equal-length mode, distinct in ragged mode.
let prompts: [[Int]] = ragged ? Array(raggedPrompts.prefix(B)) : Array(repeating: prompt, count: B)
let effB = prompts.count
let maxLen = prompts.map(\.count).max() ?? 0
let leftPad = prompts.map { maxLen - $0.count }   // left-pad each row to maxLen
print("mode=\(ragged ? "ragged" : "equal-length")  prompt lengths=\(prompts.map(\.count))  leftPadding=\(leftPad)")

// ---- (1) B=1 reference per row (scalar path) ----
print("[1/2] B=1 reference decode (\(effB) rows) …")
func referenceDecode(_ p: [Int], eosIds: Set<Int>, maxTok: Int) throws -> [Int] {
    let s = try makeShard()
    var seq = p; var out = [Int]()
    for step in 0..<maxTok {
        let inTok = step == 0 ? seq : [seq[seq.count - 1]]
        var h = s.embed(tokens: inTok)
        h = s.runOwnedLayers(h)
        let t = argmaxLast(s.projectToLogits(h))[0]
        seq.append(t); out.append(t)
        if eosIds.contains(t) { break }
    }
    return out
}
let refRows = try prompts.map { try referenceDecode($0, eosIds: eos, maxTok: maxTokens) }
print("    reference token counts: \(refRows.map(\.count))")

// ---- (2) Batched path with left-padding (fresh shard) ----
print("[2/2] B=\(effB) batched decode …")
let batShard = try makeShard()
batShard.beginBatch(leftPadding: leftPad)
var rowsOut = Array(repeating: [Int](), count: effB)
var lastTokens = [Int]()
for step in 0..<maxTokens {
    let h: MLXArray
    if step == 0 {
        h = batShard.runOwnedLayersBatched(batShard.embedBatch(rows: prompts, leftPadding: leftPad))
    } else {
        // Decode steps are width-1 per row: no padding needed.
        h = batShard.runOwnedLayersBatched(
            batShard.embedBatch(rows: lastTokens.map { [$0] }, leftPadding: Array(repeating: 0, count: effB)))
    }
    let toks = argmaxLast(batShard.projectToLogitsBatched(h))
    guard toks.count == effB else { fail("batched sampling returned \(toks.count), expected \(effB)") }
    lastTokens = toks
    for b in 0..<effB { rowsOut[b].append(toks[b]) }
    if toks.allSatisfy({ eos.contains($0) }) { break }
}

// ---- Compare per row ----
var mismatches = 0
for b in 0..<effB {
    let refLen = refRows[b].count
    let row = Array(rowsOut[b].prefix(refLen))
    if row != refRows[b] {
        mismatches += 1
        let fd = (0..<min(row.count, refLen)).first(where: { row[$0] != refRows[b][$0] }) ?? min(row.count, refLen)
        FileHandle.standardError.write(Data(
            "  row \(b) diverged at token \(fd): got \(row.prefix(fd+1).suffix(3)) vs ref \(refRows[b].prefix(fd+1).suffix(3))\n".utf8))
    }
}

print("\nrow 0 reference: \(tokenizer.decode(tokenIds: refRows[0]).prefix(100))")
if mismatches == 0 {
    print("\nPASS: all \(effB) batched rows match their B=1 reference token-for-token.")
} else {
    fail("\(mismatches)/\(effB) batched rows diverged from the B=1 reference")
}
