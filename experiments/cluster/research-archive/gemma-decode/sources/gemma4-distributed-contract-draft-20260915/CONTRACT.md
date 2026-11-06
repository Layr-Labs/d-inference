# Gemma 4 26B text adapter and partition contract

This package implements a private metadata mapper for the exact retained `gemma-4-26b-qat-4bit` artifact. It does not implement or admit native Gemma distributed execution. It reads seven small retained metadata/header files; it opens no weight shard or tokenizer payload. The root evidence has full shard sizes and bounded headers/index, **not verified whole-payload hashes**. All declared SHA values remain declarations where the bytes have not been hashed.

The next native adapter should reuse the existing Gemma decoder, CBv2 state owner, descriptor materializer, owner protocol and generation schedule. The minimum changes are explicit replicated tensor destinations, an original-geometry stage constructor, and per-kind state validation. A Qwen compact configuration with a renamed model type cannot supply this contract.

## Exact source authority

- Root evidence: [artifact manifest](../gemma4-26b-distributed-artifact-20260915/manifest.json), [config](../gemma4-26b-distributed-artifact-20260915/metadata/config.json), [index](../gemma4-26b-distributed-artifact-20260915/metadata/model.safetensors.index.json), [header inventory](../gemma4-26b-distributed-artifact-20260915/tensor-inventory.json).
- Declared aggregate: `2468a0cb3049a871f42052f4d9f9380bf12a0792f64c7a29f768559fc7d28785`.
- Verified retained config bytes: `29910322dd085f45c8f95c6c0f1611b20f722d6f6c8394321b34817e98a972fa`.
- Verified retained index bytes: `5455e83705bbdd4e3702c7d4f9d49d4900e84533036628f74500538075dd5c80`.
- The generated [input pins](derived/input-pins.json) bind the exact seven files read. [Source pins](source-pins.json) bind the local implementation examined. Neither is a loaded-storage commitment or numerical-policy agreement.

`artifact.py` checks duplicate JSON keys, bounded file sizes, config/index pins, header hashes, all 1,697 descriptor names, index-to-shard assignments, packed shape/dtype byte counts, contiguous nonoverlapping offsets, and each declared shard size including its captured header. It independently derives the expected 1,339 text tensor shapes from model widths. It does not treat an internally consistent header as authenticated payload content.

## Model and stage responsibilities

The full text model has 30 layers, hidden width 2,816, vocabulary 262,144, tied input/output embeddings and final logit softcap 30. It uses 25 sliding layers and five full layers, with the repeated global pattern `sliding × 5, full`. Sliding attention has Q16/KV8/head256/window1024; full attention has Q16/KV2/head512. Full rotary uses proportional RoPE with partial factor 0.25 and theta1,000,000; sliding rotary uses theta10,000. Attention scale is the existing Gemma value 1.0. No per-layer input embeddings or cross-layer KV sharing are present.

Each layer owns all 128 experts, a top-eight router and the shared FFN. Expert intermediate width is704; shared width is2,112. Top-eight routing is dynamic execution selection, **not permission to omit 120 experts from resident storage**. Text-only admission excludes vision/audio input and active MTP. The root config's `use_bidirectional_attention=vision` remains intact; text requests use causal CBv2 attention.

For any explicit cut `1..<30`:

| Responsibility | Rank 0 | Rank 1 |
|---|---|---|
| Layer ownership | Global `[0,cut)` | Global `[cut,30)` |
| Input embedding | Own triplet; lookup ×sqrt(2816) | Own replica for tied output projection only |
| Inter-stage value | Emit all current chunk residual rows before final norm | Consume exact residual without another embedding or scale |
| Final norm and vocabulary projection | Absent | Final norm, embedding `.asLinear`, softcap30 |
| Final prompt narrowing | Disabled at local stage end | Existing policy only at global layer29 |
| State | Own each local layer's KV, no remote KV copy | Same |

There is no phase-alignment requirement for a ranged Gemma constructor that retains global indices. A cut at1 must still make local rank1 layer4 use the original global layer5 full-attention geometry. Cuts12 and15 are planning examples; no cut is performance- or fit-qualified here.

## Exact tensor ownership and quantization

The header union contains 1,697 tensors: 1,339 text, 355 `vision_tower`, three `embed_vision`. The text inventory is 25×45 sliding-layer tensors +5×42 full-layer tensors +3 embedding tensors +1 final norm. Every text tensor has exactly one destination except the three explicitly replicated tied embedding tensors, each with destinations on both ranks. There are 1,342 destination tensors in total. No `lm_head` tensor exists.

Each expert gate/up/down projection retains its complete `[128,out,in]` geometry. The source already uses `experts.switch_glu.{gate_proj,up_proj,down_proj}`; no raw-HF split or fused gate/up conversion is required. Quantization is affine group64, fallback4-bit, with exactly120 explicit8-bit overrides: shared FFN gate/up/down and `router.proj` on every layer. Embedding, attention and experts remain4-bit. The mapper relocates override module paths from global layer indices to local module paths while preserving the original full config separately for model policy.

Packed weight axes are logical `in/(32/bits)` with U32 storage. Scale and affine bias axes are `in/64`, BF16. Learned norms, router scales, per-expert scales and `layer_scalar` retain their exact BF16 header shapes. `v_norm` has no learned tensor. The five full layers have no `v_proj`; sliding layers do.

| Header-derived payload quantity | Bytes |
|---|---:|
| Unique text source | 14,467,688,508 |
| Excluded vision source | 1,140,925,536 |
| Extra tied embedding replica | 415,236,096 |
| Sum of two rank destinations | 14,882,924,604 |
| Cut12 rank0 / rank1 | 6,036,214,808 / 8,846,709,796 |
| Cut15 rank0 / rank1 | 7,437,403,934 / 7,445,520,670 |

These are logical source tensor bytes, not allocator residency or peak process memory. The two embedding copies are physically independent across processes but bind the same source descriptor and quantization policy. The same canonical source must not be double-counted in the unique-source receipt. The additional destination and read obligations must be charged explicitly.

The exact destinations, descriptor shapes, replica roles, excluded names and relocated policies are in [cut12](derived/partition-cut12.json) and [cut15](derived/partition-cut15.json); [all cuts](derived/all-cuts.json) reports all29 splits. These private metadata fingerprints are deliberately not existing runtime Plan fingerprints.

## Global geometry and native dispatch

The existing [Gemma topology gate](/Users/developer/DarkbloomDev/d-inference/libs/mlx-swift-lm/Libraries/MLXLLM/Models/Gemma4Text.swift:94) requires `numHiddenLayers==30`, H2816,128experts,top8,expert704 and the existing visibility mode. Coupled weighted unsort eligibility also requires4-bit/group64/affine and no expert-specific override. The 120 shared/router overrides do not violate that condition.

Construct selected [Gemma4DecoderLayer](/Users/developer/DarkbloomDev/d-inference/libs/mlx-swift-lm/Libraries/MLXLLM/Models/Gemma4Text.swift:1313) objects with the **original full configuration and global layer index**. Do not change `numHiddenLayers` to the stage count, change the original layer-type array, construct all30 then prune, or force a native route. Keep stage-local module ordinal, global layer identity and full source geometry as separate values.

The final-layer optimization in the current full [trunk loop](/Users/developer/DarkbloomDev/d-inference/libs/mlx-swift-lm/Libraries/MLXLLM/Models/Gemma4Text.swift:1730) uses the end of its local `layers` array. A stage adapter must instead test original global layer29 and final-output responsibility. Every rank0 prefill row is required by downstream KV construction. Rank1 may apply the existing tail/last-query policy only after all earlier layers; its KV still advances for the entire chunk. Submission cadence should retain global `layerNumber`, while cache indexing remains local.

Use the existing `Gemma4Configuration` nested text/root quantization decoder, exact shared FFN + routed GeGLU math, and `Gemma4Model` text sanitizer. Keep split experts. The native [R1 classifier](/Users/developer/DarkbloomDev/d-inference/libs/mlx-swift/Source/Cmlx/mlx/mlx/backend/common/gemma4_expert_qmm.h:116) additionally requires actual BF16/U32 dtypes, contiguity, AOT kernels and supported assignment counts4096/8192/16384. The current split gate/up shape with output704 does not match its fused gate/up output1408 case; down704→2816 can match. A512-token/top8 prefill gives4096 assignments before final-row narrowing, but this is not evidence of an actual kernel hit. [NAX takes precedence](/Users/developer/DarkbloomDev/d-inference/libs/mlx-swift/Source/Cmlx/mlx/mlx/backend/metal/quantized.cpp:1729) and must remain unchanged. Existing solo selection and flags are outside this patch.

The custom-activation [SwitchGLU initializer](/Users/developer/DarkbloomDev/d-inference/libs/mlx-swift-lm/Libraries/MLXLMCommon/SwitchLayers.swift:535) performs a tiny `.item(Bool.self)` activation probe. Therefore a future actual Gemma constructor requires native error/resource/deadline guards even before payload materialization. This pure mapper constructs no model and executes no such probe.

## State and frontier contract

Use the existing contiguous backend and cache bank, with one owning row per global layer. The artifact has `num_kv_shared_layers=0`; no nil borrowed rows, duplicated source caches or inter-rank KV replication are needed. Tied weight replication does not replicate request state.

`attention_k_eq_v` shares only the raw full-attention K projection. The [attention code](/Users/developer/DarkbloomDev/d-inference/libs/mlx-swift-lm/Libraries/MLXLLM/Models/Gemma4Text.swift:1033) applies learned K normalization and RoPE to K, but scale-free normalization without RoPE to V. **Both K and V must have independent state storage**; do not halve the full-layer byte charge.

At committed input frontier F:

- Every local row has absoluteOffsetF and its device Int32 position offsetF.
- Full layers retain `[0,F)` with K/V shape `[1,2,F,512]`.
- Sliding layers retain `[max(0,F-1024),F)` with K/V shape `[1,8,min(F,1024),256]` in temporal order.
- The sliding backend allocates a fixed1024-slot ring even for a short request. During multi-token update, attention may retain1023 previous tokens plus the complete new chunk; this temporary view is larger than the final ring snapshot.
- No recurrent state exists. The existing empty `CBv2RecurrentStateSpec` can bind/evaluate/commit with zero roots/bytes, but `confirmedStateSnapshot()` returns nil for that empty spec. Snapshot code must accept that exact empty case without weakening the nonempty Qwen requirement.
- Each layer contributes keys, values and one Int32 position-offset entry:90 named state entries globally. Local-to-global indices remain injective and cover0..<30 exactly.

For P prompt tokens and O committed greedy outputs, the final ordinary-generation input frontier is P+O−1; reserve capacityP+maximumOutput. Early EOS uses the actual committed output count. For P32/C16/O128: F159,capacity160. For P8192/C512/O128: F8319,capacity8320. These are private planning vectors, not installed Gemma profile admission.

Expected BF16 logical capacity is25×1024×8×256×2×2 +5×capacity×2×512×2×2. At cut15, P32 gives110,362,624/102,629,376 bytes; P8192 gives177,209,344/202,899,456. The generated state vectors also expose a four-byte scalar planning option, but no native Gemma KV dtype has been measured or attested. The future constructor must derive/check actual loaded activation and K/V dtypes; Gemma currently lacks Qwen's `CBv2CompleteCheckpointKVTypeProviding` implementation.

Do not implement Gemma MTP or ordinary post-wrap rollback in this first adapter. Existing windowed speculative staging is a separate correctness requirement if later enabled: plain rollback after a ring wraps destroys history. Normal failure retires the complete request owner, releases all rows and waits for native cleanup under the existing protocol.

## Resource and validation boundary

Retain actual-free≥6GiB, AC/pressure/zero-swap checks, maximum native buffer checks, allocation rounding, pre-read admission, bounded deadlines, canonical device lease and actual process cleanup proof. The current Qwen dense ledger cannot be reused with substituted Gemma dimensions: there is no GDN fusion/conv/SSM state, but there is MoE routing/gather/sort/activation workspace and windowed attention views.

The next resource profile must charge selected tensors and the explicit replica, construction/probe lifetime, host/aligned reads, per-array allocator footprint, ring/full KV, temporary attention views, MoE scratch and its asynchronously retained roots, boundary copies, logits/sampler and requested diagnostic copies. For C512, the logical BF16 residual alone is2,883,584 bytes per buffer. Header bytes plus that value are not a complete admission bound. No claim of24GB/48GB runtime fit, numerical correctness, throughput or product eligibility follows from this package.
