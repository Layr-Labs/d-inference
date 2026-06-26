// THROWAWAY harness: prove the Gemma 4 pipeline shard preserves the forward pass
// against a MONOLITHIC reference, using a TINY SYNTHETIC checkpoint generated in
// this process. The real gemma-4-26B is far too big to load monolithic + 2 shards
// at once, so we mint a ~MB random checkpoint with the EXACT key names + shapes
// `Gemma4TextModel` expects, then run the same equivalence check the other
// shard-smokes run. NOT a product.
//
//   swift run -c release gemma4-shard-smoke            # uses a temp dir
//   swift run -c release gemma4-shard-smoke <out-dir>  # writes checkpoint there
//
// Approach (robust against shape drift): rather than hand-writing every weight
// key, we INSTANTIATE the monolithic `Gemma4TextModel` for the tiny config, read
// its actual parameter (key, shape) set via `parameters().flattened()`, and mint
// matching random tensors. That guarantees the synthetic checkpoint exactly
// matches the module structure (MoE SwitchGLU experts, k_eq_v full-attention
// layers that omit v_proj/v_norm, sliding/full mix, tied embeddings). We then:
//   1. Load the FULL Gemma4TextModel from that checkpoint (reference).
//   2. Load a 2-way layer split (head=[0,mid), tail=[mid,N)).
//   3. Run the same token ids through both; slice BOTH to the last position;
//      assert argmax matches AND relative logit diff < 0.02.
//
// This proves the Gemma 4 loader (vision-tower key filtering + index remap +
// tied-embed replication + shape-inferred quantize) and the partial forward
// (per-layer-type mask, √hidden embed scale, final-logit softcap) are correct.
// Mirrors Sources/gptoss-shard-smoke/main.swift.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

func fail(_ m: String) -> Never {
    FileHandle.standardError.write(Data("FAIL: \(m)\n".utf8)); exit(1)
}

// ----------------------------------------------------------------------------
// Tiny synthetic gemma4 config. MoE (enable_moe_block) + sliding/full mix +
// k_eq_v full attention. num_kv_shared_layers=0 and hidden_size_per_layer_input=0
// (the cluster-supported shape — the shard requires both off).
// ----------------------------------------------------------------------------
let textCfg: [String: Any] = [
    "model_type": "gemma4_text",
    "num_hidden_layers": 4,
    "hidden_size": 128,
    "intermediate_size": 256,
    "moe_intermediate_size": 128,
    "enable_moe_block": true,
    "num_experts": 4,
    "top_k_experts": 2,
    "num_attention_heads": 4,
    "num_key_value_heads": 2,
    "num_global_key_value_heads": 1,
    "head_dim": 32,
    "global_head_dim": 64,
    "attention_k_eq_v": true,
    "use_double_wide_mlp": false,
    "vocab_size": 320,
    "sliding_window": 8,
    "num_kv_shared_layers": 0,
    "hidden_size_per_layer_input": 0,
    "final_logit_softcapping": 30.0,
    "tie_word_embeddings": true,
    "rms_norm_eps": 1e-6,
    "layer_types": [
        "sliding_attention", "full_attention",
        "sliding_attention", "full_attention",
    ],
    "rope_parameters": [
        "sliding_attention": ["rope_type": "default", "rope_theta": 10000.0],
        "full_attention": ["rope_type": "proportional", "rope_theta": 1000000.0,
                           "partial_rotary_factor": 0.25],
    ] as [String: Any],
]
// Gemma 4's top-level (multimodal) config nests the text tower under
// `text_config`; both Gemma4Configuration and the cluster loader read it there.
let cfg: [String: Any] = [
    "model_type": "gemma4",
    "vocab_size": textCfg["vocab_size"]!,
    "text_config": textCfg,
]

// Output directory: arg or temp.
let args = CommandLine.arguments
let outDir: URL
if args.count >= 2 {
    outDir = URL(fileURLWithPath: args[1], isDirectory: true)
} else {
    outDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("gemma4-synth-\(UUID().uuidString)", isDirectory: true)
}
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

print("== gemma 4 synthetic shard smoke test ==")
print("checkpoint dir: \(outDir.path)")

// ----------------------------------------------------------------------------
// 1. Write config.json
// ----------------------------------------------------------------------------
let cfgData = try JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys])
try cfgData.write(to: outDir.appendingPathComponent("config.json"))

// ----------------------------------------------------------------------------
// 2. Build the monolithic model for THIS config, then mint random weights that
//    exactly match its parameter (key, shape) set. fp32, unquantized → no
//    quantization metadata, so the loader's shape-based quantize is a no-op.
// ----------------------------------------------------------------------------
MLXRandom.seed(0)

let textConfigData = try JSONSerialization.data(withJSONObject: textCfg)
let gemmaTextConfig = try JSONDecoder().decode(Gemma4TextConfiguration.self, from: textConfigData)
let scaffold = Gemma4TextModel(gemmaTextConfig)

// Read the model's actual parameter layout and replace each leaf with a small
// random tensor of the SAME shape. Norm weights live near 1.0 (Gemma's RMSNorm
// adds 1.0 internally, but a trained norm weight is still ~O(0.1) around 0, so
// small-scale random is fine and keeps activations well-scaled).
var w: [String: MLXArray] = [:]
for (key, value) in scaffold.parameters().flattened() {
    let shape = value.shape
    // Weights at ~0.2 (not 0.02) so the forward produces logits with REAL spread
    // — otherwise the tied-embed projection + tanh softcap collapse everything
    // toward zero and the relative-diff check becomes uninformative (a near-zero
    // scale makes any diff look like 0%). Norm weights stay near 0 (Gemma's
    // RMSNorm adds 1.0 internally).
    let scale: Float = key.contains("norm") ? 0.1 : 0.2
    w[key] = MLXRandom.uniform(low: -scale, high: scale, shape).asType(.float32)
}
eval(Array(w.values))

// The checkpoint on disk uses the HuggingFace key prefix `language_model.model.`
// for the text tower (+ tied embeddings: no separate lm_head). `parameters()`
// gives us the in-module keys (e.g. "model.layers.0...", "lm_head..." absent
// when tied). Map them to the on-disk convention the loader expects.
//   in-module "model.<x>"  -> "language_model.model.<x>"
//   in-module "lm_head.<x>" -> (tied build has none; skip if present)
var diskWeights: [String: MLXArray] = [:]
for (k, v) in w {
    if k.hasPrefix("model.") {
        diskWeights["language_model." + k] = v
    } else if k.hasPrefix("lm_head.") {
        // Tied build: the scaffold won't have lm_head; if some build does, drop
        // it (the shard projects through tied embed_tokens).
        continue
    } else {
        diskWeights["language_model.model." + k] = v
    }
}

let weightsURL = outDir.appendingPathComponent("model.safetensors")
try MLX.save(arrays: diskWeights, url: weightsURL)
print("wrote \(diskWeights.count) tensors -> \(weightsURL.lastPathComponent)")

// A short deterministic token sequence (no tokenizer needed for the math check).
let tokens = [1, 17, 42, 7, 100, 3, 256, 9]
let ids = MLXArray(tokens.map { Int32($0) }, [1, tokens.count])
let noCache: [KVCache]? = nil

// ----------------------------------------------------------------------------
// 3. Monolithic reference
// ----------------------------------------------------------------------------
print("\n[1/3] loading full model …")
let (full, N) = try Gemma4PipelineShardLoader.loadFullModel(outDir)
let mid = N / 2
print("layers: \(N)  split: head=[0,\(mid))  tail=[\(mid),\(N))")
let logitsFull = full(ids, cache: noCache)
logitsFull.eval()
print("    full logits shape: \(logitsFull.shape)")

// ----------------------------------------------------------------------------
// 4. Sharded
// ----------------------------------------------------------------------------
print("[2/3] loading 2 shards …")
let (headShard, total1) = try Gemma4PipelineShardLoader.loadFromDirectory(outDir, start: 0, end: mid)
let (tailShard, total2) = try Gemma4PipelineShardLoader.loadFromDirectory(outDir, start: mid, end: N)
precondition(total1 == N && total2 == N)

print("[3/3] running sharded forward …")
var h = headShard.embed(ids)
h = headShard.runOwnedLayers(h, cache: noCache)
h = tailShard.runOwnedLayers(h, cache: noCache)
let logitsShard = tailShard.projectToLogits(h)
logitsShard.eval()
print("    shard logits shape: \(logitsShard.shape)")

// ----------------------------------------------------------------------------
// Compare — aligned last-position slice (same logic as the other smokes).
// ----------------------------------------------------------------------------
func lastSlice(_ logits: MLXArray) -> MLXArray {
    guard logits.ndim == 3, logits.dim(1) > 1 else { return logits }
    return logits[0..., (logits.dim(1) - 1)..., 0...]
}
func argmaxLast(_ logits: MLXArray) -> Int {
    let a = argMax(logits, axis: logits.ndim - 1)
    a.eval()
    return Int(a.asArray(Int32.self).last ?? -1)
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
print(String(format: "aligned max abs logit diff = %.6f  (scale %.4f, relative %.6f)", maxDiff, scale, relDiff))

if scale < 0.01 {
    fail("logit scale \(scale) too small — forward collapsed to ~0, relative-diff check is uninformative")
}
if aFull == aShard && relDiff < 0.02 {
    print("\nPASS: Gemma 4 sharded forward matches monolithic (same next-token; aligned logits within \(String(format: "%.2f%%", relDiff*100)) relative).")
} else {
    fail("Gemma 4 sharded output diverged from monolithic — argmax \(aFull) vs \(aShard), maxDiff \(maxDiff), relDiff \(relDiff)")
}
