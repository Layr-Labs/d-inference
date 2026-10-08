# Long-prefill tensor budget and arithmetic admission

These are additive, source-only Foundation/CryptoKit drafts. Only Python CPU checks were executed by the author. No MLX import, model payload read, inference build, native inference, SSH or GPU work occurred. The three core files are independent of Options, the CLI, wire types and the existing admission helper. The fourth file is a prospective pure Swift selfcheck; `BudgetCheckMain.swift` is its standalone stdin test entry point, not a product mode.

## APIs and distinct scopes

`QwenLongPrefillTensorBudget.estimate(geometry:maximumTokens:chunkSize:)` counts explicit tensor geometry with checked signed-Int arithmetic. Its immutable geometry initializer validates bounded dimensions, layer/attention alignment and GDN head alignment. It applies **no resource ceiling and authorizes no execution**. Kernel size one correctly has zero convolution history. Context capacity is 1...32768 and chunk is 1...512, bounded by capacity.

`QwenRegistered9BLongPrefillAdmission.admit(configuration:expectedArtifactAggregateSHA256:promptCount:chunkSize:outputCount:batchSize:teacherTokenCount:nativeDType:bf16ConversionEnabled:)` is the narrow execution precondition. It requires exact retained configuration SHA `c8e767de4953e58352fbc1acbf6615329075ed02fe16a36b8065714d85ee4423`, expected aggregate `127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b`, 8192/512/output1, batch1, teacher0, BF16 policy1 and native dtype `bfloat16`. It parses dimensions from those admitted bytes. It checks 8193 reserved tokens, 16 frames, exact estimate745345056 and its separately named 768 MiB ceiling.

The supplied artifact digest is an expected pin, **not a completed artifact verification**. The caller still verifies the actual artifact, active native dtype, natural token bytes, stage plan, source policies and OS resource admission. A caller cannot use a small request or another configuration that happens to have the same dimensions to satisfy this registered qualification. This does not widen legacy `QwenLayerStageComparisonAdmission`; its prompt<=128/chunk<=32/output<=4 and 512 MiB gate are explicitly rechecked by the CPU audit.

`QwenLongPrefillArithmeticEnvironment.admit(_ environment: [String:String])` consumes the actual process environment passed by the caller **before any MLX initialization or cached environment lookup**. It reads no global state. The receipt contains only the five named controls, never the whole environment. Baseline and candidates must pass the same contract before constructing arrays.

| Control | Required raw state | Source-bound effect |
| --- | --- | --- |
| `DARKBLOOM_CBV2_ATTN_QUERY_BLOCK` | exactly `128` | Matches pinned attention default; a 512-token chunk issues four128-query blocks. |
| `DARKBLOOM_BF16_WEIGHTS` | exactly `1` | Converts stored Float16 tensors to BFloat16 under loader policy, before subsequent math. Existing Float32 tensors stay Float32. |
| `MLX_ENABLE_TF32` | exactly `1` | Matches pinned Cmlx default and permits eligible NAX paths. It does not force NAX availability or make all math TF32. |
| `MLX_METAL_GPU_ARCH` | absent, including no empty value | Keeps actual-device architecture detection; forbids a dispatch override. |
| `MLX_SDPA_BLOCKS` | absent, including no empty value | Keeps source default0/adaptive two-pass reduction block selection. |

The helper deliberately does not normalize numeric strings. Pinned Cmlx `get_var` uses `atoi`, which would accept some noncanonical prefixes; source Swift controls have different parsing rules. Exact values prevent those differences from becoming implicit experiment policy. TF32=1 is the existing default, not a new numerical optimization.

## Independent named-tensor arithmetic

The formula preserves the legacy inventory: four-byte activation/KV estimates, three recurrent generations, one largest CPU state component and two boundaries. Python derives counts by enumerating all32 layer kinds from the retained config and summing tensor shapes, independently of the Swift aggregate expression.

| Term at capacity8193/chunk512 | Bytes |
| --- | ---: |
| Convolution history per recurrent layer | 98,304 |
| SSM state per recurrent layer | 2,097,152 |
| KV capacity per attention layer | 67,117,056 |
| Conservative F32 boundary | 8,388,608 |
| Three recurrent generations across24 layers | 158,072,832 |
| Eight KV capacities plus Int32 offsets | 536,936,480 |
| Largest one-component CPU snapshot | 33,558,528 |
| Two conservative F32 boundaries | 16,777,216 |
| **Total** | **745,345,056** |
| Separate registered ceiling | 805,306,368 (768 MiB) |

The frozen independent inventory additionally gives source-derived BF16 geometry: 134,234,112 bytes of KV capacity per16-layer stage, a 4,194,304-byte native boundary, and 319,946,784 bytes in72 final logical state components at8192 committed tokens. These are mathematical shape counts, not new native observations. The 5,038,041,600 bytes of active source weights are outside the tensor estimate, as are loader/fusion transients, attention/GDN workspaces, allocator metadata, Metal/driver memory, other process usage and RSS. Passing768 MiB is not a whole-process memory-safety claim.

## Pinned arithmetic-dispatch audit

All paths here are under `/Users/developer/DarkbloomDev/d-inference`. `cpu-audit.json` binds exact source bytes before/after the CPU check; future native evidence must bind its actual source archive, executable and Metal libraries independently.

* `libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/AttentionV1.swift:35–48,369–374,578–581`: the cached block-size control defaults128. At512 it updates complete KV state then attends four blocks. The source explicitly says blocking is not bit-identical to the single-call path because reduction tiling/kernel specialization can differ. A same-model **8192/chunk512 full-model baseline** is mandatory. Previous chunk32 results do not qualify these arithmetic paths.
* `experiments/cluster/inference/Sources/ClusterInference/VerifiedQwenDiagnosticLoading.swift:38–54`, `PreparedQwenLayerSource.swift:45` and `VerifiedQwenLayerStageLoading.swift:56–58`: stored F16→BF16 conversion is shared by ordinary and stage loading. This is a 16-bit-to-16-bit conversion, not widening. Any later BF16→F32 arithmetic observes the already rounded BF16 values; it must not bypass that order by loading original F16 directly as F32. The registered inventory keeps `A_log` as F32.
* `libs/mlx-swift/Source/Cmlx/mlx/mlx/utils.h:214–227`, `utils.cpp:295–308`, Metal `matmul.cpp:917,2839,2918`, `quantized.cpp:1045,1241,1729`, `scaled_dot_product_attention.cpp:218,755`: `MLX_ENABLE_TF32` defaults1 and participates in NAX eligibility for F32 math. BF16 inputs can remain eligible regardless of this flag. The helper preserves the explicit default across both arms.
* Metal `device.cpp:641–647,999–1016`: architecture override, actual device architecture, OS>=26.2 and the `MLX_METAL_NO_NAX` compile definition affect kernel availability. Environment admission alone cannot certify the actual architecture, OS, backend, compiler flags, packaged libraries or selected kernel. Record those identities with the tested executable. Hardware changes require a new same-hardware correctness control.
* Metal `scaled_dot_product_attention.cpp:519–523,749–764`: a positive `MLX_SDPA_BLOCKS` overrides the two-pass reduction partition. The exact registered path has head_dim256 and128-query blocks and selects the composed/unfused route. The large-q head256 NAX exception needs at least1024 queries and cannot be triggered by128 blocks. The two-pass knob is therefore inactive for the exact sixteen full512-token chunks, but is still excluded explicitly; ragged tiny cases can exercise small-query paths.
* `libs/mlx-swift-lm/Libraries/MLXLLM/Models/GatedDelta.swift:60,297–327`: there is no environment-controlled GDN recurrence branch. Gate/beta and state use F32, with an explicit kernel-versus-ops path. The Metal kernel loops overT and preserves its compensated dot-product section with reassociation/contraction disabled. No chunk32/512 threshold occurs in this recurrence. Metal custom-kernel availability/source/build remains relevant; `MLXFastKernel.swift:190–223` creates the Metal kernel and has a fatal non-Metal stub. A nonexistent GDN environment switch must not be invented.
* `Qwen35.swift:272–280` and Metal `conv.cpp:1535–1555`: registered Qwen uses depthwise one-dimensional convolution with stride1/dilation1/padding0/groups=channels. The native depthwise fast path returns before grouped unfold/GEMM or2D Winograd dispatch. `MLX_CONV_UNFOLD_TILE_ROWS`, `MLX_CONV_WINOGRAD_WORKING_SET` and `MLX_CONV_WINOGRAD_TILE_BATCH` are real controls (`conv.cpp:38,75,99`) but inactive in this model path. Keep them absent in a clean qualification launch; a future geometry/path change needs a new audit. Quantized fused QKV/Z/B/A assembly in `Qwen35.swift:409–497` is first-use state without an environment toggle.

Other controls should be bound separately for timing/resource reproducibility. `ConstantArrayCastCache.swift:30–34` enables `MLX_QUANTIZED_CONSTANT_CACHE` by default unless a false spelling is present; it caches exact BF16→F32 conversion and changes lifetime/latency rather than intended arithmetic. Use exact1 or prospectively require absence in all arms and record that choice. Pin/clear `MLX_BFS_MAX_WIDTH` (default20), `MLX_MAX_OPS_PER_BUFFER` and `MLX_MAX_MB_PER_BUFFER` (device-selected defaults), `MLX_METAL_FAST_SYNCH` (default0), residency controls and `MLX_RESOURCE_LIMIT`. They influence scheduling/synchronization/residency/admission and are **not validated by the small arithmetic helper**. Preserve process-level warmth/cache policy separately.

`compile.cpp:241` treats any presence of `MLX_DISABLE_COMPILE` as disabling compilation, even the string0; no compile call is made by the direct diagnostic request/session path examined here. EngineLoop's `DARKBLOOM_CBV2_PREFILL_NARROWING` is an engine-only switch (`EngineLoopV2.swift:2399–2403`), while the diagnostic session calls its explicit narrowing path. MTP environment policy belongs to the MTP engine and is outside this prefill-only diagnostic. Dense affine Qwen does not take GPTOSS/MXFP4 fast-tail/tile or Gemma expert-slice branches. These inactive controls should remain absent or fixed in a clean future launcher; this helper does not expand its scope to those engines/models.

## Checks and root-owned pure Swift harness

Reproduce the CPU arithmetic/source checks without any native work:

```sh
python3 -B /Users/developer/DarkbloomDev/cluster-research/long-prefill-budget-draft/check_long_prefill_budget.py
```

`cpu-audit.json` records20 passing Python test methods, with mutation subcases for integer types/overflow, geometry and context limits, exact configuration bytes, supplied artifact pin, dtype/policy, teacher/batch/output, required environment values and forbidden overrides. It also checks the legacy source ceiling/bounds, dispatch source clauses and the source-only imports. These tests do **not** establish that the Swift draft compiles or executes correctly.

Root can compile only Foundation/CryptoKit files using the standalone test entry point:

```sh
cd /Users/developer/DarkbloomDev/cluster-research/long-prefill-budget-draft
/usr/bin/swiftc QwenLongPrefillTensorBudget.swift QwenRegistered9BLongPrefillAdmission.swift QwenLongPrefillArithmeticEnvironment.swift QwenLongPrefillBudgetCheck.swift BudgetCheckMain.swift -o /Users/developer/DarkbloomDev/cluster-research/long-prefill-budget-check
/Users/developer/DarkbloomDev/cluster-research/long-prefill-budget-check < /Users/developer/DarkbloomDev/cluster-research/runs/qwen-layer-stage-prefill-ranks-serial-peer24-20260914/remote-metadata/before-config.json
```

The Swift selfcheck covers the actual positive registered admission and independent term vector plus the same essential rejection classes. Its generic larger-capacity case deliberately computes a number above768 MiB to demonstrate that generic geometry is not the registered resource gate. It creates no model or tensor and has no MLX imports. Native/inference qualification and public adapter integration remain root-owned.
