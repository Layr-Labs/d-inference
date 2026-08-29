# Qwen3.5-9B (dense `qwen3_5`) validation + native inline-MTP head

**Date:** 2026-08-28 · **Worktree:** branch `qwen35-9b-dense` @ `origin/master` (`0e63aed`, provider v0.8.15) · **Hardware:** Apple M4 Max (128 GB, 40 GPU cores, 546 GB/s)

## Summary

- `mlx-community/Qwen3.5-9B-MLX-4bit` (dense `qwen3_5`, natively multimodal, hybrid GDN/full-attention) is **supported end-to-end by master with zero code changes**. The dense-`qwen3_5` integration shipped in #700 ("Qwen3.8-27B full VLM" — Qwen3.8-27B is itself `model_type: qwen3_5`), and #752 added Qwen MTP; the 9B rides the same paths: `EngineV2SupportedModels` whitelist, `EngineV2VLMTextExtraction` dense branch, `EngineV2Factory` `Qwen35Model` family switch, vision prefill/tower, template fixes, `SpecDecArtifactFunnel.isQwen35Target`.
- No MLX-format MTP artifact exists for the 9B (HF search: GGUF derivatives only). The original `Qwen/Qwen3.5-9B` bf16 checkpoint ships the native one-layer MTP head (15 `mtp.*` tensors, 486 MB bf16). We built a combined inline-MTP 4-bit artifact from it and **verified a 1.51× decode speedup** through the production engine.

## Verification matrix (all live, real weights from HF cache)

| Check | Result |
|---|---|
| Scan/advertise | `qwen3_5`, `is_vision: true`, `template_render_ok: true`, 6.6 GB |
| `darkbloom benchmark --sweep` (production CBv2 engine, contiguous KV, VLM extraction + parity gate) | Prefill 566 / 738 / 731 tok/s @ 128/512/2048 · Decode B=1 **45.9** → B=6 **183.6 tok/s aggregate** (30.6/seq) |
| Baseline: same sweep on `EigenLabs/Qwen3.5-35B-A3B-MLX-VL-4bit-g64` (fleet MoE) | B=1 24.5 tok/s, B=4 78.8 agg — the 9B is 1.9× faster at B=1, dense-style batch scaling |
| Standalone server (`darkbloom start --local`) | chat completions coherent; **vision correct** (red-square/blue-circle description, 2.0 s); streaming SSE TTFT 0.10 s warm; zero WARN/ERROR |
| Unit tests | `QwenVLMTargetExtractionTests` 15/15 (dense extraction, long-context solo stripe, factory acceptance); `EngineV2SupportedSetGateTests` all pass |

## MTP for the 9B

The 9B checkpoint carries no MTP tensors (0 `mtp.*` keys), so MTP is disabled by the funnel's fallback path — graceful by design. To try it for real we built a combined artifact:

**Recipe** (from `Qwen/Qwen3.5-9B` bf16 + `mlx-community/Qwen3.5-9B-MLX-4bit`):

1. Extract the 15 `mtp.*` tensors from the original checkpoint (they span shards 2/3/4).
2. Convert norms: HF Qwen3.5-family RMSNorm stores `x·(1+w)`; MLX computes `x·w` — **add 1 to every norm weight** (`input_layernorm`, `post_attention_layernorm`, `norm`, `pre_fc_norm_hidden`, `pre_fc_norm_embedding`, `q_norm`, `k_norm`). Raw-HF norms produce garbage drafts (~0 % acceptance → 4× SLOWER than target-only).
3. Quantize the 8 linear modules (fc, self_attn.{q,k,v,o}_proj, mlp.{gate,up,down}_proj) to 4-bit g64 affine via `mx.quantize`; keep `.weight`/`.scales`/`.biases` triplet keys. **Scales/biases MUST be bfloat16** — float16 scales make the assistant fail to activate and the funnel silently serves target-only (48 tok/s, same as no-MTP).
4. Write a `mtp-00001.safetensors` shard next to the base's shards (APFS-clone the base files), add the 31 keys to `model.safetensors.index.json` (`mtp.<module>.weight|scales|biases` — no double `.weight`), and declare in `config.json`:
   - `"mtplx_mtp": {"included": true, "prefix": "mtp.", "model_type": "qwen3_5_mtp", "block_size": 3, "shares_target_embeddings": true, "shares_target_lm_head": true}`
   - `"mtplx_mtp_quantization": {"group_size": 64, "bits": 4, "mode": "affine"}`
5. Serve with `[backend] mtp_mode = "on"` (`.auto` only auto-enables for `EigenLabs/Qwen3.8-27B-4bit`).

**Results** (identical request, 256 tokens, temperature 0, standalone server):

| Configuration | tok/s | Note |
|---|---|---|
| Target only (MTP kill switch) | 47.9–48.5 | baseline |
| MTP on, raw-HF bf16 head (norms not +1'd) | 12.4 | engaged but drafts garbage → 0 % acceptance, 4× slower |
| MTP on, 4-bit head, fp16 scales | 47.6 | assistant never activates; silent target-only fallback |
| MTP on, 4-bit g64 head, bf16 scales, +1'd norms | **73.1–73.4** | **1.51× vs baseline**, stable across runs |
| MTP on, bf16 head (raw linears), +1'd norms | **78.6–79.8** | **1.63× vs baseline** — draft precision buys ~8 % back |

**Draft precision tradeoff:** 4-bit quantizing the head costs ~8 % of the MTP
speedup (quantization noise flips near-tie draft logits → slightly lower
acceptance) in exchange for 3.5× smaller resident bytes (137 MB vs 486 MB) and
a cheaper draft read each step. The bf16 head wins on raw throughput at this
model size; 4-bit matches the published EigenLabs convention
(`EigenLabs/Qwen3.8-27B-MTP-4bit`) and the tighter resident budget slot sizing
charges (`SpecDecLimits.residentEstimate`). Both activate through the same
inline funnel path (for the bf16 head, ship the linears unquantized and leave
`mtplx_mtp_quantization` an empty object).

Output-under-MTP is a target-legal continuation but not byte-identical to non-MTP greedy (diverges at ~char 335 into an equally plausible phrasing). This matches the engine's top-two/rectangular acceptance policy — the same semantics production Qwen3.8-27B MTP ships; forcing `DARKBLOOM_MTP_MAX_RECTANGULAR_TOKENS=0` does not change the text.

## Fleet notes

- Serving this model on the network requires no coordinator/provider code changes: publish (`scripts/publish-model.sh` → R2) + register (`register-model.yml`), with a **provider version floor at/above the #700 release** — older providers 404 `qwen3_5` dense loads at the advertised-set guard.
- An EigenLabs-style published MTP head for the 9B would follow the conventions above (or the standalone-head format of `EigenLabs/Qwen3.8-27B-MTP-4bit`, pinned to the target revision).

## Worktree build gotchas

- `git submodule update --init` is not enough: `libs/mlx-swift` has **nested** submodules (`Source/Cmlx/mlx`, `Source/Cmlx/mlx-c`) that must be initialized or the build fails on `no_jaccl.cpp`.
- `scripts/fetch-metallib.sh` once per worktree; for `swift test`, also copy `mlx.metallib` into `DarkbloomProviderPackageTests.xctest/Contents/MacOS/`.
- The standalone server takes a machine-wide media-serving lock — one `darkbloom start --local` per box; a second instance displaces the first.
