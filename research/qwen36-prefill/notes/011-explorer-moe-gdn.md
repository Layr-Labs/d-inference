# 011 — Explorer: MoE + GDN + attention physics of one prefill chunk

Status: **kept (derivation)** — arithmetic is firm and calibrated against the
measured `notes/009` baseline; every efficiency split is marked ESTIMATE.

Scope: decompose ONE prefill chunk of `N = B·L` tokens into bytes, FLOPs, and
likely milliseconds on the M3 Max, then say which levers can and cannot reach
2.5x.

Code read: `libs/mlx-swift-lm/Libraries/MLXLLM/Models/Qwen35.swift`,
`Qwen35MoE.swift`, `GatedDelta.swift`,
`libs/mlx-swift-lm/Libraries/MLXLMCommon/SwitchLayers.swift`,
`libs/mlx-swift/Source/Cmlx/mlx-generated/quantized.cpp`,
`provider-swift/Sources/ProviderCore/Inference/{VisionTowerBudget,UnifiedMemoryCap}.swift`.
No M3 Max runtime was used for this note; the measurements it leans on are
`notes/009`.

---

## 0. Bottom line, before the arithmetic

1. **Prefill on this model is ALU-bound, not bandwidth-bound, at every chunk
   size we actually run.** Delivered rate is **8.6–9.1 TFLOPS**; delivered
   memory bandwidth is **~61 GB/s, about 15% of 400 GB/s**. `notes/003`'s
   weights-per-chunk roofline is the wrong roofline for `L >= 512`; it is the
   right roofline for *decode*.
2. **The whole B=1 curve is reproduced by two constants**:
   `t_step(N) = 66.2 ms + 0.566 ms x N`. That fit predicts the measured 4x2048
   burst makespan to **0.5–1.1%**. The 66.2 ms is the once-per-pass weight
   stream plus launch; everything else is per-token ALU.
3. **Therefore weight-stream amortization — the entire premise of the packing
   lever — is worth at most 5%.** Collapsing a 4x2048 burst from four passes to
   one deletes `3 x 66.2 ms` out of 4,901 ms.
4. `[4,2048]` in one pass is predicted at **1.08–1.25x**, not the 2.0–3.5x in
   `notes/012` rank 2. Reaching the 4,153 tok/s bar in one pass requires
   **24.3 TFLOPS sustained** = 171% of this GPU's FP32 peak and 86% of its FP16
   peak, on a workload that is 93% gathered 4-bit QMM plus a serial fp32
   recurrence.
5. **The only lever with 2x-class headroom is the delivered efficiency of
   `gatherQuantizedMM` / `quantizedMatmul` itself.** One microbenchmark decides
   whether the program's goal is physically legal. It has not been run.

---

## 1. Calibration: two constants from `notes/009`

`notes/009` medians, High Power, AC, contiguous KV, stripe 2048:

| L | TTFT (ms) | passes | tokens/pass |
|---:|---:|---:|---:|
| 512 | 356.0 | 1 | 512 |
| 2048 | 1225.3 | 1 | 2048 |
| 8192 | 5263.7 | 4 stripes | 2048 |

Fit `t = W + c·N` on the two single-pass points:

```
c = (1225.3 - 356.0) / (2048 - 512) = 0.56595 ms / token
W = 356.0 - 512 x 0.56595        =   66.2 ms / pass
```

Cross-checks (these are what make the fit trustworthy, not the fit itself):

- **8K as four stripes:** `4 x 1225.3 = 4901.2 ms` vs measured `5263.7 ms`.
  Residual **362.5 ms (6.9%)**.
- **The residual is exactly the cross-stripe attention growth.** Stripes 2/3/4
  additionally attend 2048/4096/6144 tokens of history:
  `2048 x 2048 x (1+2+3) = 25,165,824` extra score cells; at
  `16 heads x (2x256 QK + 2x256 AV) = 16,384 FLOP/cell` over 10 full-attention
  layers that is **4.12 TFLOP**, i.e. `4.12e12 / 0.3625 s = 11.4 TFLOPS`.
  Same order as the blended 9.1 TFLOPS and slightly above it, exactly as a
  pure-GEMM term should be.
- **The 4x2048 burst:** the burst runs four `[4,512]` packed passes
  (`notes/010` §2, `notes/012`), i.e. 2048 tokens per pass, identical to four
  solo 2048s. Model: `4 x 1225.3 = 4901 ms`. Measured 4,926 ms (`notes/009`) /
  4,955 ms (`notes/012`). **Error 0.5–1.1%.**

`W = 66.2 ms` against a 19.51 GB weight file (§3) implies **295 GB/s effective
for the streaming read plus launch overhead**, which is 74% of nominal. That
is a sane number and it is the reason to believe `W` is the weight stream and
not a fitting artifact.

> ESTIMATE flag: two points cannot distinguish "`W` fixed, `c` constant" from
> "`W = 0`, `c` falls 14% from 512 to 2048". Both fit. They imply opposite
> levers. **Measurement #2 in §10 resolves this and should be run first.**

---

## 2. FLOP ledger per token (CODE FACT)

Dims from `Qwen35TextConfiguration` + `notes/001`: `hidden=2048`,
`layers=40` (30 GDN + 10 full-attn, `fullAttentionInterval=4`), `E=256`,
`topK=8`, `moe_intermediate=512`, `shared_expert_intermediate=512`,
`H=16`, `kvHeads=2`, `headDim=256`, GDN `k_heads=16 / v_heads=32 / dim=128 /
conv=4`, `vocab=248320`.

Note two shapes that are easy to under-count and are together **35% of all
prefill FLOPs**:

- `Qwen35Attention.init`: `qProj = Linear(hidden, attentionHeads * headDim * 2)`
  = **2048 -> 8192**. Half is the sigmoid output gate consumed by
  `sigmoidMultiply(output, gate)`. `oProj` is 4096 -> 2048.
- `Qwen35GatedDeltaNet.init`: `convDim = 2*keyDim + valueDim = 2*2048 + 4096 =
  8192`, so `inProjQKV = Linear(2048, 8192)`, `inProjZ = Linear(2048, 4096)`,
  `outProj = Linear(4096, 2048)`. The 30 "linear-attention" layers carry a
  4x-expansion dense MLP each.

Per token, per layer (MACs; FLOP = 2 x MAC):

| Block | detail | MAC/token/layer | x layers | GFLOP/token |
|---|---|---:|---:|---:|
| **GDN** `in_proj_qkv` | 2048x8192 | 16,777,216 | | |
| **GDN** `in_proj_z` | 2048x4096 | 8,388,608 | | |
| **GDN** `in_proj_a` + `in_proj_b` | 2x 2048x32 | 131,072 | | |
| **GDN** `conv1d` depthwise k=4 | 8192x4 | 32,768 | | |
| **GDN** `out_proj` | 4096x2048 | 8,388,608 | | |
| **GDN subtotal** | | **33,718,272** | x30 | **2.023** |
| **Attn** `q_proj` (incl. gate half) | 2048x8192 | 16,777,216 | | |
| **Attn** `k_proj`, `v_proj` | 2x 2048x512 | 2,097,152 | | |
| **Attn** `o_proj` | 4096x2048 | 8,388,608 | | |
| **Attn subtotal** | | **27,262,976** | x10 | **0.545** |
| **MoE** router `gate` | 2048x256 | 524,288 | | |
| **MoE** 8 routed `gate_up_proj` | 8x 2048x1024 | 16,777,216 | | |
| **MoE** 8 routed `down_proj` | 8x 512x2048 | 8,388,608 | | |
| **MoE** shared expert (3 proj) | 3x 2048x512 | 3,145,728 | | |
| **MoE** `shared_expert_gate` | 2048x1 | 2,048 | | |
| **MoE subtotal** | | **28,837,888** | x40 | **2.307** |
| **GEMM total** | | **2,437,693,440 active params** | | **4.875** |

Non-GEMM, per token:

| Block | derivation | GFLOP/token |
|---|---|---:|
| GDN recurrence (`gated_delta_step`) | `7 FLOP x 524,288` state elems x30 layers | **0.110** |
| Full-attn scores + AV | `16 heads x (L/2) x 256 x 4` x10 layers = `81,920 x L` | **0.042** (L=512) / **0.168** (2048) / **0.671** (8192) |

**Delivered rate** (measured ms/token from `notes/009`, including `W`):

| L | GFLOP/token | ms/token | delivered TFLOPS | % FP32 peak (14.2) | % FP16 peak (28.4) |
|---:|---:|---:|---:|---:|---:|
| 512 | 5.027 | 0.6953 | **7.23** | 51% | 25% |
| 2048 | 5.153 | 0.5983 | **8.61** | 61% | 30% |
| 8192 | 5.656 | 0.6425 | **8.80** | 62% | 31% |
| marginal (`1/c`) | 5.153 | 0.56595 | **9.11** | 64% | 32% |

Three independent lengths land within 20% of each other. The 8.6–9.1 TFLOPS
figure is robust. It also matches `GOAL.md`'s prior "~24% of peak" note if that
note was quoting FP16 peak.

> M3 Max 40-core: 5,120 shading units. FP32 **14.2 TFLOPS** at 1.40 GHz /
> **16.4** at the 1.6 GHz boost figure; FP16 is **2x** (28.4 / 32.8); INT8 is
> 4x (65.5). Sources disagree on clock, not on the 1:2:4 ratio. Treat 14.2 /
> 28.4 as the conservative pair. ESTIMATE until measurement #1 in §10.

---

## 3. Byte ledger (CODE FACT + arithmetic)

4-bit affine g64 = `0.5 + 2/64 + 2/64` = **0.5625 B/param** (packed nibbles +
fp16 scale + fp16 bias). Routers are 8-bit (`notes/001`) = 1.0625 B/param.

| Block | params | bytes | share |
|---|---:|---:|---:|
| Routed experts, per layer (`gate_up_proj` [256,1024,2048] + `down_proj` [256,2048,512]) | 805,306,368 | **452.98 MB** | |
| Routed experts x40 | 32.21 B | **18.12 GB** | **92.9%** |
| GDN projections x30 (+ conv1d bf16) | 1.011 B | 570.5 MB | 2.9% |
| Attn projections x10 | 272.6 M | 153.4 MB | 0.8% |
| `lm_head` | 508.6 M | 286.1 MB | 1.5% |
| `embed_tokens` | 508.6 M | 286.1 MB | 1.5% |
| Shared experts x40 | 125.8 M | 70.8 MB | 0.4% |
| Routers x40 (8-bit) | 21.0 M | 22.3 MB | 0.1% |
| **Text path total** | **34.66 B** | **19.51 GB** | |

(Index `total_size` 21.28 GB; the delta is the vision tower + MTP, both outside
the text prefill path.)

**Routed experts are 93% of the bytes and 41% of the FLOPs.** That single line
is the whole decode/prefill split: decode touches 8/256 of the expert bytes
(14.2 MB/layer), prefill at `N >= 512` touches all 256 (453 MB/layer) — a **32x
byte amplification at identical per-token FLOPs**.

### Where the ridge is

Machine balance `14.2e12 / 400e9 = 35.5 FLOP/byte` (FP32) or 71 (FP16).

- Whole chunk: intensity `= N x 4.875e9 / 19.51e9 = 0.25 N`. Ridge at
  **N = 142 tokens** (FP32 balance) / **N = 284** (FP16).
- One routed expert (the tightest block): bytes `3,145,728 x 0.5625 = 1.769 MB`,
  FLOP `n x 6,291,456` for `n = N/32` tokens routed to it. Intensity `3.556 n`.
  Ridge at **n = 10 tokens/expert = N = 320 chunk tokens** (FP32) / 640 (FP16).

Every chunk we run (512 / 2048 / 8192) is past the ridge. Independent check:
total per-step traffic at `N=2048` is ~19.5 GB weights + ~55 GB activations
(§4) in 1.225 s = **~61 GB/s = 15% of 400 GB/s**, against **64% of FP32 ALU
peak**. ALU is the binding constraint, unambiguously.

---

## 4. Per-component decomposition of one chunk

`N = B·L` chunk tokens. "Shared across packed B" means *the weight stream* is
shared; FLOPs never are.

### 4.1 Embedding — `Qwen35TextModelInner.cbv2Forward` -> `embedTokens(inputs)`

| | |
|---|---|
| Weight bytes | 286 MB table; only `N x 2048 x 0.5625 = 1.15 KB/token` actually gathered |
| Activation bytes | `N x 2048 x 2` written = 33.6 MB at N=8192 |
| Bound by | BW, trivially |
| Scales with L | activations yes; table read is a sparse gather |
| Shared across packed B | table yes; gathered rows no |
| Share of step | **< 0.1%** |

### 4.2 GDN x30 — `Qwen35GatedDeltaNet.cbv2Forward` / `processChunk`

Four sub-blocks with very different physics.

**(a) Input/output projections** (`inProjQKV`, `inProjZ`, `inProjA`, `inProjB`,
`outProj`)

| | |
|---|---|
| Weight bytes | 19.01 MB/layer, **570 MB total, fixed** |
| FLOP | 2.023 GFLOP/token — **35% of all GEMM FLOPs** |
| Bound by | **ALU.** Intensity `3.54 N` FLOP/byte; ridge at N=10 |
| Scales with L | FLOP ∝ B·L; bytes fixed |
| Shared across packed B | **yes** (weights) |
| Share of step | **~28%** ESTIMATE |
| Note | `in_proj_a` and `in_proj_b` are `Linear(2048, 32)`: two dispatches/layer (60/step) that each read the whole `[B,S,2048]` activation to emit 32 columns. Intensity ≈ 0. This is precisely what the rolled-back 0.8.8 4-in-1 fusion removed. |

**(b) Depthwise conv + silu**

`processChunk` does `concatenated([convState, qkv], axis: 1)` (a
`[B, S+3, 8192]` **copy**: 33.6 MB at S=2048), then `silu(conv1d(convInput))`
as two more full passes.

| | |
|---|---|
| Weight bytes | 65 KB/layer (bf16, 8192x4) |
| Activation bytes | ~135 MB/layer at S=2048 |
| Bound by | **BW / elementwise** |
| Shared across packed B | no |
| Share of step | ~2–3% ESTIMATE |

**(c) The recurrent scan** — `gatedDeltaKernel`, `GatedDelta.swift`

CODE FACT: `grid: (32, Dv, B*Hv)`, `threadGroup: (32, 4, 1)`, and the kernel
body is `for (int t = 0; t < T; ++t)` — **strictly serial in T, parallel only
over `B x Hv x Dv x 32` = 131,072 threads at B=1**.

| | |
|---|---|
| Weight bytes | 0 (state is `[B, 32, 128, 128]` fp32 = 2.1 MB/layer/row) |
| FLOP | 0.110 GFLOP/token (7 FLOP per state element per token) |
| Bound by | ALU at poor efficiency: scalar fp32 + two `simd_sum` reductions per step, **no `simdgroup_matrix`** |
| Scales with L | serial in L; total work ∝ B·L |
| Shared across packed B | **no.** `grid.z = B*Hv`, so B=4 is 4x the work. At B=1 the kernel already issues 1,024 threadgroups over 40 cores, so it is throughput-limited, not latency-limited — there is no free occupancy to absorb B. |
| Share of step | **2–5%** ESTIMATE (225 GFLOP at N=2048; 16 ms at FP32 peak, 30–60 ms realistically) |
| Hidden traffic | each of the 128 `dv` positions re-reads the same `q_`/`k_` row; with `threadGroup.y = 4` that is **32x amplification** on q/k reads — ~537 MB/layer at S=2048, ~16 GB/step. A chunkwise-parallel reformulation or threadgroup-memory staging removes it. |

This caps the "GDN chunkwise-parallel scan" roadmap item at **~4%**, below
`notes/002`'s 5–7% guess.

**(d) Gated norm + out_proj** — folded into (a).

### 4.3 Full attention x10 — `Qwen35Attention.cbv2Forward` -> `cache.updateAndAttend`

**(a) QKV/O projections + gate**

| | |
|---|---|
| Weight bytes | 15.33 MB/layer, **153 MB total, fixed** |
| FLOP | 0.545 GFLOP/token |
| Bound by | ALU |
| Shared across packed B | **yes** |
| Share of step | ~8% ESTIMATE |

**(b) Scores, softmax, AV — the L² term**

CODE FACT with a large consequence: **`headDim = 256` is outside MLX's fused
SDPA head-dim set `{64, 80, 128}`**
(`VisionTowerBudget.fusedAttentionHeadDims`, mirroring
`sdpa_full_supported_head_dim`). `UnifiedMemoryCap.swift` states the
consequence directly: such a model "materialises an **fp32**
`[rows, heads, C, kL]` prefill score tensor", and "TEXT prefill is query
sub-blocked on both KV backends, which bounds it" — via
`CBv2AttentionV1.attendQueryBlocks` with
`queryBlockSize = 128` (`DARKBLOOM_CBV2_ATTN_QUERY_BLOCK`, `notes/017`).

| | |
|---|---|
| Weight bytes | 0 |
| FLOP | `81,920 x L` per token = 0.168 GFLOP/token at L=2048, 0.671 at L=8192 |
| Score bytes materialized | `16 heads x L²/2 x 4 B` **fp32** = 143 MB/layer at L=2048, **2.15 GB/layer at L=8192**; ~4 passes (write, softmax r+w, AV read) => ~570 MB/layer at 2048, ~8.6 GB/layer at 8192 |
| Bound by | **mixed.** Per head per block, intensity ≈ 64 FLOP/byte against a 35.5 ridge — only 1.8x past it. Roughly half the cost is the score round-trip. |
| Scales with L | **B·L²** |
| Shared across packed B | **no**, and `CBv2AttentionV1.packedPerRow` deliberately slices `[B,...]` into `[1,...]` calls (`notes/010`) |
| Share of step | 7% at L=2048; **the entire 362 ms cross-stripe residual at 8K** |

A fused D=256 flash kernel (the unqualified "D=256 Steel attention" row in
`notes/002`) deletes the score round-trip, i.e. roughly half of this block:
**~3–4% at 8K, growing as L**. It is a >=32K lever, not an 8K lever.

**(c) KV writes (GQA 16:2)**

`2 kv heads x 256 dim x 2 tensors x 2 B` = **2,048 B/token/layer**, x10 layers
= **20.5 KB/token**. 168 MB per 8K request, 672 MB at B=4. Trivial for
bandwidth (0.4 ms), material for KV capacity planning only.

### 4.4 MoE x40 — `Qwen35SparseMoeBlock.callAsFunction` -> `SwitchGLU`

**(a) Router + top-8**

`gate(x)` -> `MLX.softmax(gates, axis: -1, precise: true)` over **all 256**
-> `MLX.argPartition(gates, kth: 248)` -> `takeAlong` -> renormalize.

| | |
|---|---|
| Weight bytes | 0.56 MB/layer (8-bit) |
| Activation bytes | `[N,256]` fp32 = 2.1 MB/layer at N=2048 |
| Bound by | BW, trivial |
| Share of step | < 1% |

**(b) Sort / gather — `SwitchGLU.projectExperts` -> `gatherSort`**

```swift
x.flattened(start: 0, end: -3)[order.floorDivide(m)]   // SwitchLayers.swift
```

This **materializes an 8x-duplicated copy of the activations**:
`[N*8, 1, 2048]` bf16 = 67 MB at N=2048, 268 MB at N=8192, *per layer*.

| | |
|---|---|
| Weight bytes | 0 |
| Activation bytes | ~67 MB write + 67 MB read per layer at N=2048 |
| Bound by | **BW** |
| Shared across packed B | no |
| Share of step | ~2% ESTIMATE |

**(c) Routed experts — `QuantizedSwitchLinear` -> `MLX.gatherQuantizedMM(..., sortedIndices: true)` -> expert-tile route**

CODE FACT (`quantized.cpp`): every affine quantized matmul kernel — plain
`affine_qmm_t`, `affine_gather_qmm_t`, and the sorted
`affine_gather_qmm_gemma4_expert_tiles` — uses **`BM = BK = BN = 32`**, and
`build_sorted_expert_tiles_bm32<NE>` is instantiated for `NE=128` (Gemma 4) and
**`NE=256` (Qwen 3.5/3.6)** with descriptors of `(row, row_count, expert)` where
`row_count = min(BM, ...)`.

| | |
|---|---|
| Weight bytes | **452.98 MB/layer, 18.12 GB total — 93% of all weight bytes** |
| FLOP | 2.013 GFLOP/token — **41% of all GEMM FLOPs** |
| Bound by | **ALU** above `n = 10` tokens/expert; **tile-fill limited** below `n = 32` |
| Scales with L | FLOP ∝ B·L; bytes fixed once every expert is hit (true at N >= ~512) |
| Shared across packed B | **YES — this is the entire packing lever, and it is worth 66 ms** |
| Share of step | **~40%** ESTIMATE |

**The BM=32 tile-fill law.** Tokens per expert `n̄ = N·topK/E = N/32`. Each
expert issues `ceil(n_e/32)` descriptors; a partly-filled tile wastes its
unused rows.

| N (chunk tokens) | n̄ | mean tiles/expert | **fill** |
|---:|---:|---:|---:|
| 512 | 16 | 1.0 | **50%** |
| 1024 | 32 | ~1.5 | 67% |
| 2048 | 64 | ~2.5 | **80%** |
| 4096 | 128 | ~4.5 | 89% |
| 8192 | 256 | ~8.5 | **94%** |
| 16384 | 512 | ~16.5 | 97% |

> ESTIMATE: `E[ceil(n/32)] ≈ n̄/32 + 0.5` for a binomial histogram. Measurement
> #4 in §10 replaces it with the true `Σ ceil(n_e/32)`.

This law reproduces the measured efficiency curve. MoE routed is 41% of GEMM
FLOPs, so if only its efficiency tracks fill:

```
t/token(512) / t/token(2048) = 0.59 + 0.41 x (0.80/0.50) = 1.25   predicted
                             = 0.6953 / 0.5983            = 1.16   measured
```

Close, and the 7% gap is exactly the fixed `W` being attributed to `c`. The
mechanism is real.

**The consequence that matters:** going from a 2048-token pass to an
8192-token pass raises fill 80% -> 94%, i.e. `1/(0.59 + 0.41 x 0.80/0.94) =`
**1.065x overall**. Tile fill above 2048 tokens is a 6.5% lever, not a 2x
lever.

**(d) Activation + SwiGLU** — `compiledSiluProduct(xGate, xUp)`, one compiled
shapeless kernel. Reads `[N*8,1,1024]`, writes `[N*8,1,512]`. ~2% ESTIMATE.
**Do not fuse GateUp+SwiGLU** (`notes/002`: +64% / +71%).

**(e) Shared expert + shared gate** — `Qwen3NextMLP(2048, 512)` +
`Linear(2048,1)`. 1.77 MB/layer, 0.294 GFLOP/token, well-shaped, ALU. ~4%.

**(f) Unsort + weighted reduction** — `scatterUnsort(x:invOrder:shape:)` then
`weightedExpertSum`.

```swift
let y = switchMLP(x, inds)                                 // Qwen35.swift:1144
let combined = weightedExpertSum(y, scores.asType(y.dtype)) // Qwen35.swift:1145
```

| | |
|---|---|
| Activation bytes | scatter 67 MB r + 67 MB w, then `[N,8,2048]` 67 MB read for the reduce, at N=2048 per layer. **~270 MB/layer round trip, ~11 GB/step** |
| Bound by | **BW** |
| Share of step | **~2.5–4%** ESTIMATE |

**CODE FACT worth correcting in the shared record:** the fused direct reduction
`weightedExpertUnsort` is **unreachable for Qwen**. `SwitchGLU
.supportsWeightedExpertUnsort` requires the Gemma-4-only GeGLU
`weightedReductionProfile` **and** `inputDims == 2816`; `Qwen35SparseMoeBlock.init`
constructs `SwitchGLU(inputDims: 2048, ..., fuseGateUp:)` with the default
`.generic` profile, and calls `switchMLP(x, inds)` + `weightedExpertSum`
directly — never `callAndWeightedReduce`. Only `Gemma4Text.swift:1239` calls it.
So `MLX_GEMMA4_FUSED_WEIGHTED_UNSORT` is **inert for Qwen**, contra the reading
in `notes/017` that it "applies to shared gather QMM". A Qwen-shaped
equivalent would have to be written; per the standing instruction it needs a
decode + uptime A/B before it can be a default.

### 4.5 LM head / narrowing — `Qwen35TextModel.cbv2RecurrentPrefill`

```swift
case .evaluationOnly:      return hidden[0..., -1, 0 ..< 1]
case .lastPositionLogits:  let last = model.norm(hidden[0..., -1, 0...]); return lmHead(last)
```

| | `.evaluationOnly` (intermediate chunks) | `.lastPositionLogits` (frontier) | if narrowing were OFF |
|---|---|---|---|
| Weight bytes | 0 | 286 MB (full `lm_head` read for B rows) | 286 MB |
| FLOP | 0 | `B x 1.02 GFLOP` | `N x 1.02 GFLOP` = 8.3 TFLOP at N=8192 |
| Logits tensor | none | `[B, 248320]` = 0.5 MB | **`[1, 8192, 248320]` bf16 = 4.07 GB** |
| Cost | ~0 | **~0.7 ms** (GEMV, 3.6 FLOP/byte, BW-bound) | ~+950 ms at 8K |

**Narrowing is already banked and is worth ~0.94 s (≈1.18x) at 8K. Protect
it.** Note the
`164 GiB` hazard in `notes/000`: `164.8e9 / (248320 x 4) ≈ 165,888` — a
vocab-width fp32 tensor. Any change that reintroduces a full-length logits
projection re-arms that crash.

---

## 5. Consolidated table

Share-of-step column is at `N = 2048`, B=1. **ESTIMATE**, constrained to sum to
the measured 1,225 ms.

| Component | Weight bytes (fixed/chunk) | Activation bytes @N=2048 | ALU or BW | Scales with | Weight stream shared by packed B | ~% of step |
|---|---:|---:|---|---|---|---:|
| Embedding | 286 MB table (sparse) | 8 MB | BW | B·L | table | <0.1 |
| GDN projections x30 | 570 MB | ~10 GB | **ALU** | B·L | **yes** | 28 |
| GDN conv + silu x30 | 2 MB | ~4 GB | BW | B·L | yes | 2.5 |
| GDN scan x30 | 0 | ~16 GB (32x q/k re-read) | ALU (low eff) | B·L, serial in L | **no** | 3.5 |
| Attn QKVO x10 | 153 MB | ~1 GB | **ALU** | B·L | **yes** | 8 |
| Attn scores/softmax/AV x10 | 0 | ~5.7 GB **fp32** | mixed | **B·L²** | **no** | 7 |
| KV writes x10 | 0 | 42 MB | BW | B·L | no | 0.3 |
| MoE router + top-8 x40 | 22 MB | ~0.3 GB | BW | B·L | yes | 0.8 |
| MoE gatherSort x40 | 0 | ~5.4 GB | **BW** | B·L | no | 2 |
| **MoE routed experts x40** | **18.12 GB** | ~4 GB | **ALU** | B·L (bytes flat) | **YES** | **40** |
| MoE SwiGLU x40 | 0 | ~2 GB | BW | B·L | no | 2 |
| MoE shared expert x40 | 71 MB | ~1.4 GB | ALU | B·L | yes | 4 |
| MoE unsort + reduce x40 | 0 | ~11 GB | **BW** | B·L | no | 3 |
| LM head (narrowed) | 286 MB | 0.5 MB | BW | B only | yes | 0.06 |
| **Total** | **19.51 GB** | **~55 GB** | **ALU-bound** | | | **100** |

`19.51 + 55 = ~75 GB / 1.225 s = 61 GB/s = 15% of 400 GB/s`, against **64% of
FP32 ALU peak**.

---

## 6. The B-scaling law

For a packed `[B, L]` pass, `N = B·L`:

```
t_pass(B, L) = W + c(N) · N          W = 66.2 ms,  c(2048) = 0.566 ms/token
aggregate tok/s = N / t_pass
```

`c` depends on `N` only through expert tile fill (§4.4c) and on `L` only through
the `B·L²` attention term. **`B` enters `c` nowhere.** Packing buys exactly two
things: it deletes `(passes - 1) x W`, and it raises `N` per pass.

### Pre-registered predictions for the 2048-token-per-row B=4 burst

Baseline (measured): 4 passes of `[4,512]`, 4,926–4,955 ms, **1,661–1,663 tok/s**.
2.5x bar: **4,153 tok/s** = 1,972 ms makespan.

| Geometry | passes | N/pass | fill | c' (ms/tok) | predicted makespan | tok/s | **x** |
|---|---:|---:|---:|---:|---:|---:|---:|
| `[4,512]` (today) | 4 | 2048 | 80% | 0.566 | 4,901 ms | 1,671 | 1.00 |
| `[4,1024]` | 2 | 4096 | 89% | 0.543 | 4,579 ms | 1,789 | **1.07** |
| `[4,2048]` | 1 | 8192 | 94% | 0.531 | 4,417 ms | 1,854 | **1.11** |
| `[4,2048]`, optimistic `c'=0.48` | 1 | 8192 | — | 0.480 | 3,997 ms | 2,049 | **1.23** |
| **required for 2.5x** | 1 | 8192 | — | **0.233** | 1,972 ms | 4,153 | 2.50 |

`c' = 0.233 ms/token` at 5.656 GFLOP/token is **24.3 TFLOPS sustained** =
**171% of FP32 peak, 86% of FP16 peak** — across gathered 4-bit QMM, a serial
fp32 recurrence, argsort, softmax, and scatter/gather.

**Prediction to falsify:** `[4,2048]` in one pass lands in **1.08–1.25x**
(1,790–2,080 tok/s). If it exceeds 1.4x, this note's model is wrong and `W` is
much larger than 66 ms — which would itself be the most important finding of
the program. `notes/012` rank 2 currently expects 2.0–3.5x from this geometry;
I believe that is off by ~2x and the experiment is worth running mainly as a
cheap referee between the two models.

---

## 7. The three levers most likely to produce 2.5x aggregate at B=4

Ranked by headroom, not by ease.

### Lever 1 — Raise the delivered rate of 4-bit (gathered) quantized matmul

**93% of prefill FLOPs go through `MLX.gatherQuantizedMM` or
`MLX.quantizedMatmul`.** Delivered 9.1 TFLOPS = 64% of FP32 peak, 32% of FP16
peak. Every quantized kernel in `quantized.cpp` uses `BM = BK = BN = 32`.

- Mechanism A: measure the bare-kernel ceiling (§10 #1). If a bare
  `quantizedMatmul` at `[8192,2048]x[2048,8192]` already delivers ~9 TFLOPS,
  the kernel is the roof and **the program's goal is not achievable** — say so
  and re-negotiate. If it delivers 16–20, the gap is in the gathered/expert
  route and is worth **1.8–2.2x on 41% of the step plus 1.5x on the dense 52%**.
- Mechanism B: 32x32x32 tiles at `K=2048` (gate_up) and especially `K=512`
  (down_proj, only 8 groups of 64 per row) may be leaving `simdgroup_matrix`
  throughput on the floor. A 64x64 threadgroup tile with dequant staged into
  threadgroup memory is the standard fix. This is a **tile-shape** change to an
  existing independently-tiled kernel, explicitly *not* a mega-kernel and *not*
  a GateUp+SwiGLU fusion.
- Applies at every `B` and every `L`. Only lever with 2x-class headroom.
- **Expected: 1.0x–2.0x, entirely gated on one microbenchmark.**

### Lever 2 — One rectangle per burst: `[4,2048]`

Deletes 3 of 4 weight streams (`3 x 66.2 ms`) and raises expert-tile fill
80% -> 94%. Requires `notes/012` rank 1 (qualify the expert-tile route at
`M = 65,536`) first, otherwise the geometry falls back to the slower generic
gather path and measures the wrong thing.

- Costs: routed assignments 16,384 -> 65,536; the gathered activation copy
  grows to 268 MB/layer; fp32 score tensor per query block is unchanged
  (blocking is per-row and `queryBlockSize=128` is fixed), but total score
  bytes grow as `B·L²`. Check against `UnifiedMemoryCap` and `maxBufferLength`
  before running.
- **Expected: 1.08–1.25x.** Real, cheap, mergeable. Not the 2.5x lever.

### Lever 3 — Delete the non-GEMM tail

Four concrete, individually small, jointly material items:

1. `gatherSort`'s 8x activation duplication (`SwitchLayers.swift`) — use
   `gather_qmm`'s `lhs_indices` instead of materializing
   `x.flattened(...)[order.floorDivide(m)]`. ~2%.
2. `scatterUnsort` + the `[N,8,2048]` intermediate consumed by
   `weightedExpertSum` — a Qwen-shaped direct reduction (the 0.8.9 rollback,
   which as shown in §4.4f was never even wired for Qwen). ~2.5–4%.
   **Requires a decode + uptime A/B before it can default on.**
3. The two `Linear(2048, 32)` GDN projections and the 4-way activation re-read
   — the 0.8.8 4-in-1 fusion, **prefill-gated on `L > 128` with a decode A/B**,
   never as an unguarded default. ~1–2%.
4. Fused D=256 attention (no fp32 score round-trip). ~3–4% at 8K, more at 32K.

Plus two free micro-deletions found in the code (§8). **Expected: 1.10–1.18x.**

### Stacked

```
Lever 2 (1.12) x Lever 3 (1.14)                  = 1.28x   without Lever 1
Lever 2 (1.12) x Lever 3 (1.14) x Lever 1 (1.9)  = 2.43x   with it
```

**2.5x aggregate at B=4 is reachable only if the 4-bit QMM kernel has ~2x of
untapped efficiency. Everything else in the enumerated state space, stacked
optimistically, is 1.3x.**

---

## 8. Micro-levers (exact, code-cited, small)

**(a) Delete the 256-wide softmax before top-k.** `Qwen35SparseMoeBlock
.callAsFunction:1133-1143` computes `softmax(gates, precise: true)` over all
256, then `argPartition`, then (with `normTopkProb`) divides by the top-8 sum.
Softmax is monotone, so `argPartition` on the raw logits selects the same 8;
and `softmax(all)[top8] / sum(top8)` is algebraically `softmax(top8 logits)`.
Replacing the order deletes a `[N,256]` fp32 softmax and one full-width pass
per layer, x40. Exact up to fp32 summation order — needs a tolerance test.
**~0.5%.**

**(b) Fold the GDN q/k scale into the rmsNorm weight.** `processChunk` does

```swift
MLXArray(pow(invScale, 2)).asType(dtype) * MLXFast.rmsNorm(q, weight: .mlxNone, eps: 1e-6)
```

`MLXFast.rmsNorm` accepts a `weight`. Passing a constant vector instead of
`mlxNone` removes two full `[B,S,2048]` read+write passes per GDN layer, x30.
**~0.5–1%.**

**(c) Inert, noted for completeness.** `SwitchLinear.callAsFunction` calls
`self.weight.swappedAxes(-1, -2)` on every invocation; the quantized subclass
does not (it passes `transpose: true`), so the 4-bit model never pays it.

---

## 9. What is physically illegal for B=1 2.5x

The B=1 bars from `notes/009` are 3,588 / 4,173 / 3,888 tok/s.

1. **Every weight-sharing lever.** One row, one stream. `W = 66.2 ms` is 5.4%
   of a 2048-token pass and 1.3% of an 8K prefill. Deleting the fixed cost
   *entirely* gives **1.06x / 1.01x**.
2. **One-shot 8192.** `notes/009` says "one-shot 8K has a physical shot at the
   8K bar." It does not. Predicted:
   `66.2 + 8192 x 0.531 + 362.5 = 4,779 ms -> 1,714 tok/s = 1.10x`. The 362 ms
   cross-stripe residual **does not disappear** — it is inherent to causal
   attention over 8192 positions, not an artifact of striping. The claim is off
   by ~2.3x.
3. **Tokens-per-expert.** B=1 at L=8192 is already at `n̄ = 256`, 94% fill.
   <=6% remains, and it is unreachable at L=512/2048 without more rows.
4. **Attention deletion.** At 8K the L² term is 0.671 of 5.656 GFLOP/token =
   11.9%. Free attention gives **1.13x**.
5. **GDN scan deletion.** 2–5% of the step. Free scan gives **1.05x**.
6. **Any "more rows in flight" mechanism** — cross-row expert coalescing,
   cross-row score batching, concurrent encode across requests, mean-TTFT
   policy. No B=1 analogue by construction.
7. **Prefix caching.** Deletes tokens rather than accelerating them; off by
   product decision; does not answer "prefill tokens/sec".
8. **FLOP deletion.** Reducing `topK` below 8, pruning experts, low-ranking the
   GDN projections, sparse attention at 8K, or quantizing *activations* to int8
   (INT8 peak is 65.5 TFLOPS — the only precision on this die where 2.5x is
   arithmetically comfortable) all violate `GOAL.md` criterion 4.

**The only B=1-legal route to 2.5x is a 2.5x rise in delivered rate:
9.1 -> 22.8 TFLOPS = 160% of FP32 peak / 80% of FP16 peak, sustained across
gathered 4-bit QMM, a serial fp32 recurrence, argsort, softmax, and
scatter/gather.** Declare B=1 2.5x illegal unless measurement #1 overturns the
peak assumption.

---

## 10. Decisive measurements, ranked

**#1 — The bare-kernel TFLOPS ceiling. Run this before anything else.**
On the Mac, in `libs/mlx-swift/Tests/MLXTests/QwenExpertTilePerfTests.swift`:

| case | shape | why |
|---|---|---|
| dense bf16 matmul | `[8192,2048] x [2048,8192]` | the machine's real GEMM ceiling vs the 14.2/28.4 spec |
| `MLX.quantizedMatmul` 4-bit g64 | same shape | dequant tax on a perfect shape |
| `MLX.gatherQuantizedMM` sorted | E=256, K=2048, N=1024, M ∈ {16384, 65536} | Qwen `gate_up_proj` |
| `MLX.gatherQuantizedMM` sorted | E=256, K=512, N=2048, M ∈ {16384, 65536} | Qwen `down_proj`, the short-K case |

Report TFLOPS for each. **This decides whether the program's 2.5x goal is
physically legal.** If gathered 4-bit QMM tops out near 9 TFLOPS, the goal is
dead at any `B` and the finding should be escalated, not worked around.

**#2 — A third and fourth point on the B=1 single-pass curve.**
`L ∈ {128, 256, 1024, 3072, 4096}` with `DARKBLOOM_CBV2_SOLO_PREFILL_STRIPE`
set so each `L` is exactly one pass. Fit `t = W + c(N)·N`. This separates
"fixed weight stream `W`" from "tile-fill-dependent `c(N)`" — two hypotheses
that fit the current two points identically and imply opposite levers. Cheap.

**#3 — GPU wall vs busy for one 2048-token pass.** Metal capture or
`MTLCounterSampleBuffer`: wall time, sum of kernel durations, top-20 kernels by
total time. If `wall/busy > 1.15` there is a launch/encode bubble and the
wavefront/concurrent-encode roadmap item is real; if `≈ 1.0`, all loss is
inside kernels and Lever 1 is the only game. `GOAL.md`'s "busy-union == sum of
kernels" says there is no *kernel-to-kernel* overlap; it does not say whether
wall exceeds busy. Those are different diagnoses with different fixes.

**#4 — Real router histogram.** Per-expert assignment counts at
N = 512 / 2048 / 8192 on a real prompt, to replace the binomial tile-fill
estimate with the true `Σ ceil(n_e / 32)`. If routing is materially imbalanced,
fill is worse than §4.4c and Lever 2 is worth more than 1.12x.

**#5 — `packedPrefillActivity()` deltas + `GPU.gemma4ExpertQMMDiagnostics()`**
around each burst. Already fully specified in `notes/010` §5. Still open.

---

## 11. Estimate vs code-fact ledger

**CODE FACTS** (read from source this session, symbol-cited):

- `q_proj` is `2048 -> 8192` (gated attention); `o_proj` is `4096 -> 2048`
  (`Qwen35Attention.init`).
- GDN `convDim = 8192`; `in_proj_qkv` 2048->8192, `in_proj_z` 2048->4096,
  `in_proj_a`/`in_proj_b` 2048->32, `out_proj` 4096->2048
  (`Qwen35GatedDeltaNet.init`).
- `gatedDeltaKernel` grid `(32, Dv, B*Hv)`, threadgroup `(32,4,1)`, body is a
  serial `for (int t = 0; t < T; ++t)` (`GatedDelta.swift`).
- `processChunk` materializes `concatenated([convState, qkv], axis: 1)` and
  applies the q/k inverse scale as a separate elementwise multiply.
- `SwitchGLU.projectExperts` -> `gatherSort` materializes
  `x.flattened(start:0,end:-3)[order.floorDivide(m)]`, an 8x activation copy;
  `callAsFunction` then `scatterUnsort`s it back.
- `Qwen35SparseMoeBlock.callAsFunction` calls `switchMLP(x, inds)` then
  `weightedExpertSum` — **never** `callAndWeightedReduce`; profile is
  `.generic`, `inputDims == 2048`, so `weightedExpertUnsort` is unreachable for
  Qwen. Only `Gemma4Text.swift:1239` reaches it.
- Every affine quantized matmul kernel in `quantized.cpp` uses
  `BM = BK = BN = 32`; `build_sorted_expert_tiles_bm32<NE>` is instantiated for
  `NE = 256`, descriptor `row_count = min(32, ...)`.
- `headDim = 256` is outside MLX's fused SDPA set `{64, 80, 128}`
  (`VisionTowerBudget.fusedAttentionHeadDims`), so full-attention prefill
  materializes an **fp32** `[rows, heads, C, kL]` score tensor, bounded by
  `CBv2AttentionV1.attendQueryBlocks` at `queryBlockSize = 128`
  (`UnifiedMemoryCap.swift` comment; `notes/017`).
- `cbv2RecurrentPrefill` narrowing: `.evaluationOnly` returns
  `hidden[0..., -1, 0..<1]`; `.lastPositionLogits` projects exactly one row.

**MEASUREMENTS INHERITED** (`notes/009`, this M3 Max, 0.8.10): 356.0 / 1225.3 /
5263.7 ms at L = 512 / 2048 / 8192; 4x2048 burst makespan 4,926–4,955 ms.

**ESTIMATES** (mine; each is falsifiable by a listed measurement):

- `W = 66.2 ms`, `c = 0.566 ms/token` — a 2-point fit; measurement #2.
- FP32 peak 14.2 TFLOPS / FP16 28.4 — published spec, clock disputed;
  measurement #1.
- Per-component share-of-step column in §5 — apportioned by FLOP share and
  assumed per-kernel efficiency, constrained to sum to the measured 1,225 ms.
- Tile-fill table — binomial approximation; measurement #4.
- All §6 predicted makespans and all §7 lever multipliers.

**CORRECTIONS PROPOSED TO EXISTING NOTES:**

- `notes/003`: the weights-per-chunk roofline is the *decode* roofline. At
  `N >= ~320` chunk tokens the model is past the ridge; measured BW utilization
  is 15%. The "2.5x exceeds this roof" / "legal if 4-bit packed" framing should
  be replaced with an ALU roof.
- `notes/009`: "8K B=1 is chunk-serialized weight traffic" — the 4x1225
  observation is equally consistent with compute-bound, because compute also
  scales with stripes. "One-shot 8K has a physical shot at the 8K bar" is off
  by ~2.3x. "2.5x aggregate means >= 5,120 tokens per weight stream" chases a
  5% term.
- `notes/012` rank 2: `[4,2048]` expected 2.0–3.5x; this note predicts
  1.08–1.25x. Rank 1 (qualify the tile route at M=32K/64K) is still correct and
  still a prerequisite — just for a 1.12x payoff, not a 3x one. **Rank 1 should
  be re-ordered behind measurement #1**, which costs one test-file run and can
  invalidate the whole queue.
- `notes/017`: `MLX_GEMMA4_FUSED_WEIGHTED_UNSORT` is inert for Qwen, not
  "applies to shared gather QMM".
- `notes/002`: "GDN chunkwise-parallel scan, estimated 5–7%" — this note puts
  the whole scan at 2–5% of the step, so the ceiling on that item is ~4%.
