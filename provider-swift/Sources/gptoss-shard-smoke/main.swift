// THROWAWAY harness: prove the GPT-OSS pipeline shard preserves the forward pass
// against a MONOLITHIC reference, using a TINY SYNTHETIC checkpoint generated in
// this process. The real gpt-oss-20b is far too big to load monolithic + 2 shards
// at once, so we mint a ~MB random checkpoint with the EXACT key names + shapes
// `GPTOSSModel` expects (post-`sanitize`), then run the same equivalence check
// `shard-smoke` runs for Llama. NOT a product.
//
//   swift run -c release gptoss-shard-smoke            # uses a temp dir
//   swift run -c release gptoss-shard-smoke <out-dir>  # writes checkpoint there
//
// What it does:
//   1. Generate config.json (tiny gpt_oss: 4 layers, 4 experts, mixed attn,
//      yarn rope_scaling) + a single random fp32 weights.safetensors with EVERY
//      parameter the monolithic GPTOSSModel needs.
//   2. Load the FULL GPTOSSModel via GPTOSSPipelineShardLoader.loadFullModel.
//   3. Load a 2-way layer split (head=[0,mid), tail=[mid,N)) via loadFromDirectory.
//   4. Run the same token ids through both; slice BOTH to the last position;
//      assert argmax matches AND relative logit diff < 0.02.
//
// This proves the GPT-OSS loader (key filtering + index remap + MoE expert keys)
// and the partial forward are correct. Mirrors Sources/shard-smoke/main.swift.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

func fail(_ m: String) -> Never {
    FileHandle.standardError.write(Data("FAIL: \(m)\n".utf8)); exit(1)
}

// ----------------------------------------------------------------------------
// Tiny synthetic gpt_oss config. mixed attention (sliding/full) + yarn rope.
// ----------------------------------------------------------------------------
let cfg: [String: Any] = [
    "model_type": "gpt_oss",
    "num_hidden_layers": 4,
    "num_local_experts": 4,
    "num_experts_per_tok": 2,
    "hidden_size": 256,
    "intermediate_size": 256,
    "head_dim": 32,
    "num_attention_heads": 8,
    "num_key_value_heads": 2,
    "vocab_size": 512,
    "sliding_window": 8,
    "rope_theta": 150000,
    "rms_norm_eps": 1e-5,
    "layer_types": [
        "sliding_attention", "full_attention",
        "sliding_attention", "full_attention",
    ],
    "rope_scaling": [
        "rope_type": "yarn",
        "factor": 32,
        "original_max_position_embeddings": 4096,
        "beta_fast": 32,
        "beta_slow": 1,
        "truncate": false,
    ] as [String: Any],
]

let numLayers = cfg["num_hidden_layers"] as! Int
let numExperts = cfg["num_local_experts"] as! Int
let hidden = cfg["hidden_size"] as! Int
let inter = cfg["intermediate_size"] as! Int
let headDim = cfg["head_dim"] as! Int
let nHeads = cfg["num_attention_heads"] as! Int
let nKV = cfg["num_key_value_heads"] as! Int
let vocab = cfg["vocab_size"] as! Int

// Output directory: arg or temp.
let args = CommandLine.arguments
let outDir: URL
if args.count >= 2 {
    outDir = URL(fileURLWithPath: args[1], isDirectory: true)
} else {
    outDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("gptoss-synth-\(UUID().uuidString)", isDirectory: true)
}
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

print("== gpt-oss synthetic shard smoke test ==")
print("checkpoint dir: \(outDir.path)")

// ----------------------------------------------------------------------------
// 1. Write config.json
// ----------------------------------------------------------------------------
let cfgData = try JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys])
try cfgData.write(to: outDir.appendingPathComponent("config.json"))

// ----------------------------------------------------------------------------
// 2. Generate random weights with the EXACT post-sanitize key names + shapes
//    GPTOSSModel expects. Small uniform values keep activations well-scaled so
//    the forward pass is numerically stable. fp32 (synthetic FP checkpoint => no
//    quantization, so sanitize early-returns on `gate_proj.weight`).
// ----------------------------------------------------------------------------
MLXRandom.seed(0)
func rnd(_ shape: [Int], scale: Float = 0.02) -> MLXArray {
    MLXRandom.uniform(low: -scale, high: scale, shape).asType(.float32)
}

var w: [String: MLXArray] = [:]

// embeddings + final norm + lm_head
w["model.embed_tokens.weight"] = rnd([vocab, hidden])
w["model.norm.weight"] = rnd([hidden], scale: 0.1) + 1.0   // norm weights ~1
w["lm_head.weight"] = rnd([vocab, hidden])

for i in 0 ..< numLayers {
    let p = "model.layers.\(i)"
    // RMSNorms (centered near 1 like a real trained norm)
    w["\(p).input_layernorm.weight"] = rnd([hidden], scale: 0.1) + 1.0
    w["\(p).post_attention_layernorm.weight"] = rnd([hidden], scale: 0.1) + 1.0

    // attention: q/k/v/o (Linear with bias) + sinks (ParameterInfo)
    let qOut = nHeads * headDim
    let kvOut = nKV * headDim
    w["\(p).self_attn.q_proj.weight"] = rnd([qOut, hidden])
    w["\(p).self_attn.q_proj.bias"] = rnd([qOut])
    w["\(p).self_attn.k_proj.weight"] = rnd([kvOut, hidden])
    w["\(p).self_attn.k_proj.bias"] = rnd([kvOut])
    w["\(p).self_attn.v_proj.weight"] = rnd([kvOut, hidden])
    w["\(p).self_attn.v_proj.bias"] = rnd([kvOut])
    w["\(p).self_attn.o_proj.weight"] = rnd([hidden, qOut])
    w["\(p).self_attn.o_proj.bias"] = rnd([hidden])
    // non-zero sinks so the sinks-active attention path is exercised.
    w["\(p).self_attn.sinks"] = rnd([nHeads], scale: 0.5)

    // MoE router (Linear with bias)
    w["\(p).mlp.router.weight"] = rnd([numExperts, hidden])
    w["\(p).mlp.router.bias"] = rnd([numExperts])

    // MoE experts: SwiGLUSwitchGLU -> SwitchLinear weights are
    // [numExperts, outputDims, inputDims], biases [numExperts, outputDims].
    // gate_proj/up_proj: inputDims=hidden, outputDims=inter.
    // down_proj:        inputDims=inter,  outputDims=hidden.
    w["\(p).mlp.experts.gate_proj.weight"] = rnd([numExperts, inter, hidden])
    w["\(p).mlp.experts.gate_proj.bias"] = rnd([numExperts, inter])
    w["\(p).mlp.experts.up_proj.weight"] = rnd([numExperts, inter, hidden])
    w["\(p).mlp.experts.up_proj.bias"] = rnd([numExperts, inter])
    w["\(p).mlp.experts.down_proj.weight"] = rnd([numExperts, hidden, inter])
    w["\(p).mlp.experts.down_proj.bias"] = rnd([numExperts, hidden])
}

eval(Array(w.values))
let weightsURL = outDir.appendingPathComponent("model.safetensors")
try MLX.save(arrays: w, url: weightsURL)
print("wrote \(w.count) tensors -> \(weightsURL.lastPathComponent)")

// A short deterministic token sequence (no tokenizer needed for the math check).
let tokens = [1, 17, 42, 7, 100, 3, 256, 9]
let ids = MLXArray(tokens.map { Int32($0) }, [1, tokens.count])
let noCache: [KVCache]? = nil

// ----------------------------------------------------------------------------
// 3. Monolithic reference
// ----------------------------------------------------------------------------
print("\n[1/3] loading full model …")
let (full, N) = try GPTOSSPipelineShardLoader.loadFullModel(outDir)
let mid = N / 2
print("layers: \(N)  split: head=[0,\(mid))  tail=[\(mid),\(N))")
let logitsFull = full(ids, cache: noCache)
logitsFull.eval()
print("    full logits shape: \(logitsFull.shape)")

// ----------------------------------------------------------------------------
// 4. Sharded
// ----------------------------------------------------------------------------
print("[2/3] loading 2 shards …")
let (headShard, total1) = try GPTOSSPipelineShardLoader.loadFromDirectory(outDir, start: 0, end: mid)
let (tailShard, total2) = try GPTOSSPipelineShardLoader.loadFromDirectory(outDir, start: mid, end: N)
precondition(total1 == N && total2 == N)

print("[3/3] running sharded forward …")
var h = headShard.embed(ids)
h = headShard.runOwnedLayers(h, cache: noCache)
h = tailShard.runOwnedLayers(h, cache: noCache)
let logitsShard = tailShard.projectToLogits(h)
logitsShard.eval()
print("    shard logits shape: \(logitsShard.shape)")

// ----------------------------------------------------------------------------
// Compare — aligned last-position slice (same logic as shard-smoke).
// ----------------------------------------------------------------------------
func lastSlice(_ logits: MLXArray) -> MLXArray {
    guard logits.ndim == 3, logits.dim(1) > 1 else { return logits }
    return logits[0..., (logits.dim(1) - 1)..., 0...]
}
func argmaxLast(_ logits: MLXArray) -> Int {
    let ids = argMax(logits, axis: logits.ndim - 1)
    ids.eval()
    return Int(ids.asArray(Int32.self).last ?? -1)
}
let fullLast = lastSlice(logitsFull)
let shardLast = lastSlice(logitsShard)
precondition(fullLast.shape == shardLast.shape,
             "aligned shapes expected, got full=\(fullLast.shape) shard=\(shardLast.shape)")

let aFull = argmaxLast(fullLast)
let aShard = argmaxLast(shardLast)

let diffArr = (fullLast - shardLast).abs()
diffArr.eval()
let maxDiff = diffArr.max().item(Float.self)
let scale = logitsFull.abs().max().item(Float.self)
let relDiff = scale > 0 ? maxDiff / scale : maxDiff

print("\nfull  argmax(last) = \(aFull)")
print("shard argmax(last) = \(aShard)")
print(String(format: "aligned max abs logit diff = %.4f  (scale %.1f, relative %.4f)", maxDiff, scale, relDiff))

if aFull == aShard && relDiff < 0.02 {
    print("\nPASS: GPT-OSS sharded forward matches monolithic (same next-token; aligned logits within \(String(format: "%.2f%%", relDiff*100)) relative).")
} else {
    fail("GPT-OSS sharded output diverged from monolithic — argmax \(aFull) vs \(aShard), maxDiff \(maxDiff), relDiff \(relDiff)")
}
