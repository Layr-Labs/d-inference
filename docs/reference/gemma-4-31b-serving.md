# Gemma 4 31B serving (flagship)

How the provider serves `mlx-community/gemma-4-31b-4bit` — the fully-resident
flagship model that replaced DeepSeek-V4 as the rollout target (2026-07-05).

## Checkpoint facts

| Property | Value |
|---|---|
| On-disk size | 18.4GB (4 safetensors shards) |
| Architecture | `Gemma4ForConditionalGeneration`, `model_type: gemma4` |
| Text config | 60 layers, hidden 5376, dense (`enable_moe_block: false`) |
| Attention | sliding window 1024, `full_attention` every 6th layer, logit softcap 30 |
| Context | 262144 max positions |
| Vocab | 262144 |
| Quantization | 4-bit affine, group 64 |
| `vision_config` | present (image-text-to-text) |
| Chat template | **none** (base model — `-it-4bit` is the instruct variant) |
| Base model | `google/gemma-4-31b`, converted with mlx-vlm 0.4.3 |

## Serving path

Everything uses pre-existing, fleet-proven machinery — no model-specific
subsystems (contrast: [deepseek-v4-serving.md](deepseek-v4-serving.md)):

- **Load**: fully resident, ~18.4GB weights. Because config.json carries a
  `vision_config`, the provider routes through `VLMModelFactory` → MLXVLM
  `Gemma4` (`libs/mlx-swift-lm/Libraries/MLXVLM/Models/Gemma4.swift`), same
  as the Gemma-4 26B MoE sibling already in the fleet. Audited for the
  Qwen3.5 `ropeDeltas` failure pattern (mlx-swift-lm#65): the Gemma4 language
  model keeps **no** per-request mutable module state — positions derive from
  the per-request cache offsets only.
- **Batched serving**: standard continuous batching. Cache layout is
  `RotatingKVCache(maxSize: 1024)` per sliding layer and
  `KVCacheSimple`/`RotatingKVCache(maxKVSize)` per full-attention layer
  (`Gemma4Text.swift newCache`), which the batched engine represents natively
  (`BatchRotatingKVCache`) — `supportsBatchedServing` accepts it; no
  sequential clamp.
- **Prompt encoding**: no `chat_template` in the checkpoint, so the
  provider's ChatML auto-injection engages (the same path Qwen3.5 base
  models use; `TemplateRenderCheck` validates at scan time). This is a BASE
  model: completions are untuned-model continuations, not instruct-style
  answers. The instruct variant `mlx-community/gemma-4-31b-it-4bit` ships a
  real Gemma turn template if instruct behavior is wanted later.
- **NAX**: release builds keep `-Xcc -DMLX_METAL_NO_NAX`
  (see `docs/spikes/nax-nondeterminism-m5.md` — JIT-compiled NAX kernels are
  broken on M5 for all models, not DSV4-specific).

## Fleet registration

No `catalog_size_gb` override — the on-disk total IS the resident footprint,
so the default `SyncModelCatalog` size derivation is correct as-is.

| Parameter | Value | Why |
|---|---|---|
| `size_gb` | 18.4 (auto) | raw manifest total = resident weights |
| `min_ram_gb` | 32 | `reportedFreeForLoadAdmits` needs 18.4×1.1176 ≈ 20.6GB ≤ 0.9×RAM−4; clears at 32GB (24.8), fails at 24GB (17.6) |
| Context clamp | provider-side via engine KV sizing | 262k positions; KV per token is bounded by the sliding window on 50 of 60 layers |

Gate-by-gate coverage: `coordinator/registry/gemma4_31b_resident_test.go`
(admission across 32/36/48/64/96/128GB tiers, below-floor rejection at 24GB,
cold-spill eligibility at the 32GB floor).

## Validation surface

- Coordinator: `go test ./registry/ -run TestGemma31b`
- Model/engine (mlx-swift-lm): existing Gemma-4 suites (`Gemma4*Tests`)
  cover the architecture; no new model code was needed for the 31B dense
  variant.
- Live on-box validation (M5 Max): load, single-stream + batched decode,
  SSE streaming, mid-decode admission waves — results recorded here when the
  run completes.
