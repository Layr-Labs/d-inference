# 083 — Independent cross-layer artifact batching audit

Date: 2026-08-24
Status: **ADVANCE only to the bounded M3 projection microbenchmark; do not
enable in serving without its necessary wall-time gate**

## Decision

Cross-layer batching is algebraically legal for five raw historical projection
families, and MLX can execute them without changing or requantizing checkpoint
W4 values. It is not an arithmetic optimization: it performs the same
475,398,144 MACs per historical token, reads the same logical weights, and
writes the same artifact elements. The mechanism only combines QMM launches
and may change kernel occupancy/reduction association.

The B1x512 E51 result needs another **1.62058x** end-to-end speedup to reach the
locked 2.5x target. Even if artifact projections were 100% of E51 wall time,
their measured aggregate speedup must therefore be at least 1.62058x. Since the
wide GDN QKV matrices already expose hundreds of threadgroups per layer and
batching removes no matrix work, that result is not expected. One device
microbenchmark is justified; serving enablement is not.

Hard disposition:

1. **KILL** if the complete multiplicity-weighted projection microbenchmark at
   actual short-prompt history `M=320` is below 1.62058x. This is a necessary,
   deliberately optimistic condition.
2. If it clears that condition, capture the actual projection wall share `p`.
   **KILL** unless
   `(1 - p) + p / projection_speedup <= 1 / 1.62058`.
3. **ADVANCE** to one B1x512 serving cell only after numerical, memory, and
   Metal-fault gates pass. Retain only if it exceeds 3,586.5 tok/s and the
   established E51 quality/state gates remain green.

## 1. Value-flow proof

The E51 policy runs layers 0--3 fully and skips layers 4--39 for historical
rows. Those 36 skipped layers are 27 GDN layers and 9 full-attention layers.

`Qwen35TextModelInner.cbv2Forward` passes `hiddenStates` into each decoder
layer. For a skipped intermediate chunk,
`Qwen35DecoderLayer.cbv2PrefillArtifactOnly` constructs state/KV and returns
`x` unchanged. At the suffix boundary,
`cbv2PrefillFrontierStateRiver` returns:

```text
concat(x[:, 0..<historyCount, :], frontierOutput)
```

Therefore, by induction over every consecutive skipped layer:

```text
H_history(layer 4 input)
  == H_history(layer 5 input)
  == ...
  == H_history(layer 39 input)
```

This is value identity for `[B,M,2048]`; an intermediate chunk also returns the
same `MLXArray` root. A frontier concatenation can create a different array
root, but the historical values are copied unchanged. The same `positionIds`
argument and historical position slice are also reused.

No stronger identity is valid:

| Tensor | Cross-layer status | Reason |
|---|---|---|
| raw historical hidden `H_history` | identical | skipped history has no residual/MLP update |
| historical position IDs | identical | one request position input is sliced for every layer |
| `inputLayerNorm(H_history)` | **different** | every decoder layer owns a distinct learned 2048-wide RMS weight |
| GDN raw `qkv/a/b` | different output, batchable family | layer-specific W4 weights |
| attention raw `k/v` | different output, batchable family | layer-specific W4 weights |
| GDN conv state | layer-local | prior chunks and layer-specific depthwise conv weights |
| GDN SSM state | layer-local fp32 | prior state plus layer-specific `A_log` and `dt_bias` |
| attention normalized/rotated K | layer-local | learned `k_norm`, then cache offset/position transform |
| attention KV destination | layer-local | each full-attention layer owns a separate cache row |
| suffix/frontier hidden | **different** | every skipped layer executes full residual + MoE on the suffix |

The learned input norms prevent broadcasting one common normalized LHS into all
weights. They do not prevent projection batching: compute each layer's norm,
stack the resulting `[M,2048]` matrices, then issue one batched/gathered QMM.
The current `MLXFast.rmsNorm` accepts one 1-D weight matching the last axis, not
an `[L,2048]` bank. A custom multi-weight norm could share the RMS reduction,
but it is a separate kernel experiment and is not assumed here.

GDN recurrence and attention caches likewise do not block precomputation of
raw projections. They do prevent treating a whole skipped decoder layer as one
stateless batched affine operation. Conv/SSM processing, learned state
parameters, RoPE/K normalization, cache commitment, transaction staging, and
rollback remain associated with their original model layer and request.

## 2. Exact stackable projection families

The target has hidden width 2,048, affine W4 group 64, BF16 scales and
quantization biases, and BF16 activations. Logical packed arrays for one
family have:

```text
input       [L, M, 2048] BF16
weight      [E, N, 256] uint32       # 2048 * 4 bits / 32
scale/bias  [E, N, 32] BF16          # 2048 / group 64
rhs index   [L] uint32
output      [L, M, N] BF16
```

`E` is the complete family weight bank (30 GDN or 10 attention matrices);
`L` is the selected skipped-layer chunk. RHS indices select original family
ordinals in ascending order.

| Family | Skipped count | K | N | Historical use |
|---|---:|---:|---:|---|
| GDN `in_proj_qkv` | 27 | 2,048 | 8,192 | conv input, then recurrent Q/K/V |
| GDN `in_proj_a` | 27 | 2,048 | 32 | recurrent decay input |
| GDN `in_proj_b` | 27 | 2,048 | 32 | recurrent update gate |
| attention `k_proj` | 9 | 2,048 | 512 | K norm + RoPE + cache |
| attention `v_proj` | 9 | 2,048 | 512 | value cache |

These are the only historical affine projections in the skipped path. GDN
`in_proj_z`/`out_proj`, attention `q_proj`/`o_proj`, post-attention norm, router,
experts, and residuals are suffix-only and see a different hidden tensor at
every layer.

Two optional row concatenations are also exact at the packed-W4 boundary:

- GDN A+B can become one `N=64` projection and split its output;
- attention K+V can become one `N=1024` projection and split its output.

That reduces five launches to three but is not required to establish the
cross-layer mechanism. It must stack packed rows, scales, and quantization
biases directly; dequantize-concatenate-requantize is forbidden.

## 3. Output memory

Across the 27+9 skipped layers, raw artifact outputs contain 232,128 BF16
values per historical token:

```text
27 * (8192 + 32 + 32) + 9 * (512 + 512) = 232128
```

| Historical M | GDN QKV | GDN A+B | attention K+V | raw output total |
|---:|---:|---:|---:|---:|
| 512 | 216.000 MiB | 1.688 MiB | 9.000 MiB | **226.688 MiB** |
| 2,048 | 864.000 MiB | 6.750 MiB | 36.000 MiB | **906.750 MiB** |
| 8,192 | 3,456.000 MiB | 27.000 MiB | 144.000 MiB | **3,627.000 MiB** |

Materializing one separately normalized input per skipped layer adds 73,728
BF16 values per token:

| Historical M | normalized inputs | outputs + normalized inputs |
|---:|---:|---:|
| 512 | 72.000 MiB | **298.688 MiB** |
| 2,048 | 288.000 MiB | **1,194.750 MiB** |
| 8,192 | 1,152.000 MiB | **4,779.000 MiB** |

E51's actual history is prompt length minus the 192-token full-depth suffix:

| Prompt | Actual M | outputs + normalized inputs |
|---:|---:|---:|
| 512 | 320 | **186.680 MiB** |
| 2,048 | 1,856 | **1,082.742 MiB** |
| 8,192 | 8,000 | **4,666.992 MiB** |

The complete five-family 40-layer W4 stack is another **283.359 MiB**
(255.023 MiB for only E51's skipped matrices). It is an exact duplicate of
packed weights/scales/biases, not a zero-copy view, and must be charged as
persistent model memory.

## 4. Gather geometry and safe chunking

Use matrix-level gather:

```text
x            [L, M, 2048]
rhs_indices  [L] = ascending original-family ordinals
w            [E, N, 256]
out          [L, M, N]
```

MLX therefore keeps primitive `M` equal to the historical row count and Metal
dispatches `B=L` matrix batches. This takes the ordinary gathered-QMM path; it
does not match the E=128/256 MoE expert specialization.

Do not accidentally use:

```text
x            [L*M, 1, 2048]
rhs_indices  [L*M]
```

That makes primitive `M=1` and selects the sorted-RHS gathered-vector geometry.
It is retained only as a benchmark control. `sortedIndices: true` is valid only
because each RHS list is monotonically nondecreasing.

There is no useful fixed layer count above one that fits a 192 MiB transient
cap at every requested M:

| M | maximal consecutive prefix under 192 MiB | result |
|---:|---:|---|
| 512 | 22 layers | useful |
| 2,048 | 5 layers | useful |
| 8,192 | 1 GDN layer | no cross-layer batch |

For the short-B1 target, the estimator admits all 36 layers at `M=320`, but
that is not a peak-memory proof: 186.680 MiB leaves only 5.320 MiB under the
192 MiB planning cap before allocator/QMM scratch. Use the full 27-GDN/9-
attention geometry only for the isolated optimistic ceiling probe.

For the first live serving cell, use a **128 MiB adaptive cap**. At `M=320`
that selects a 24-layer prefix (18 GDN + 6 attention, 124.453 MiB nominal),
then the remaining 12 layers (9 GDN + 3 attention, 62.227 MiB nominal). It
retains cross-layer work in both chunks and reserves 67.547 MiB against the
192 MiB envelope for unmodeled transients. Increase it only after measuring
active/peak memory and Metal faults. At larger M, split at layer boundaries
and fall back to sequential when fewer than two same-family matrices fit.

If one fixed useful chunk is required across M=512/2048/8192, use **two
same-type layers**. At M=8192 two GDN layers require about **322 MiB** for both
normalized inputs and qkv/a/b outputs; three require about 483 MiB before
allocator scratch, and a 3-GDN+1-attention quartet requires 531 MiB. Two is the
conservative fixed probe shape, but it requires a transient cap above 322 MiB
and does not fit the default 192 MiB policy.

## 5. Immutable W4 semantics

Both existing APIs can preserve checkpoint quantization:

1. `quantizedMM` accepts matching batch dimensions for input, packed `uint32`
   weight, scales, and affine quantization biases.
2. `gatherQuantizedMM` accepts the same arrays plus matrix-level RHS indices.

Safety conditions:

- stack the original `uint32` words directly;
- stack original BF16 scales and affine quantization biases in the same order;
- require identical `groupSize=64`, `bits=4`, `.affine`, logical K/N, and
  bias presence within a family;
- never replace named module parameters with the execution stack;
- pass `transpose=true` exactly as `QuantizedLinear` does;
- fail closed before cache/state mutation when any condition or byte bound
  fails.

This preserves every decoded W4 value and leaves source modules immutable.
It does not promise bit-identical outputs: sequential B=1 `quantizedMM` can use
split-K while batched/gathered QMM uses a different reduction association,
especially for N=32 A/B and N=512 K/V. Those outputs feed fp32 recurrence and
cache state, so projection tolerance, final state, rollback/cancellation,
full-model checksum, and semantic quality checks remain mandatory.

## 6. Speed ceiling

Historical projection arithmetic is unchanged:

```text
GDN:      27 * 2048 * (8192 + 32 + 32) = 456,523,776 MAC/token
attention: 9 * 2048 * (512 + 512)      =  18,874,368 MAC/token
total                                      475,398,144 MAC/token
```

The incumbent emits 99 projection QMM nodes:

```text
27 * (qkv + a + b) + 9 * (k + v) = 99
```

A whole-run five-family graph can reduce that to five nodes (or three with the
optional row concatenations), but Metal still executes the same output tiles
and weight decode. At actual `M=320`, one wide QKV layer exposes 640
threadgroups on the M3 NAX 64x64 path
(`ceil(320/64) * ceil(8192/64)`) or 2,560 on the generic 32x32 path. Either is
already hundreds of threadgroups per layer. Stacking does not create grid
occupancy; only encoder/launch overhead and kernel-route details can improve.

Locked B1x512 arithmetic:

```text
E51 throughput                 2,213.1 tok/s
2.5x target                    3,586.5 tok/s
required additional speedup    1.62058x
E51 wall                       231.350 ms
target wall                    142.758 ms
required wall deletion          88.592 ms (38.294%)
```

For projection wall share `p`, the required projection speedup is:

```text
s >= p / (p - 0.382936)
```

Examples: `p=0.5 -> 4.27x`, `p=0.6 -> 2.76x`, `p=0.7 -> 2.21x`,
`p=0.8 -> 1.92x`. This is why 1.62058x is only the impossible-best-case
necessary gate, not a sufficient advance result.

## 7. Standalone decision probe

`Qwen35ArtifactProjectionBatchPerfTests` is opt-in and compares four routes
over real target geometries:

- one `quantizedMM` per layer (incumbent);
- aligned batched `quantizedMM`;
- matrix-level `gatherQuantizedMM` (candidate);
- per-row sorted gather (M=1/QMV control).

Without a layer override it runs only the exact short-B1 serving rectangle:
`M=320`, GDN `L=27` gathered from `E=30` at RHS ordinals 3--29, and attention
`L=9` gathered from `E=10` at RHS ordinals 1--9. It validates each candidate
against sequential W4 output at the serving artifact tolerances, rotates route
order over 15 GPU-complete samples, and emits both per-family medians and a
complete multiplicity-weighted speedup/disposition. A separate fixed-two-layer
run covers the requested larger M values without pretending those shapes fit
the serving memory policy. On the M3 checkout:

```bash
cd libs/mlx-swift-lm
swift test -c release list
BIN="$(swift build -c release --show-bin-path)"
SRC="$HOME/.darkbloom/Darkbloom.app/Contents/MacOS/mlx.metallib"
cp "$SRC" "$BIN/mlx.metallib"
for d in "$BIN"/*.xctest/Contents/MacOS; do
  ln -sf "$BIN/mlx.metallib" "$d/mlx.metallib"
done

# Exact E51 B1x512 history and actual serving bank/assignment geometry.
unset DARKBLOOM_QWEN35_ARTIFACT_BATCH_BENCH_LAYERS
DARKBLOOM_QWEN35_ARTIFACT_BATCH_BENCH=1 \
DARKBLOOM_QWEN35_ARTIFACT_BATCH_BENCH_M=320 \
  swift test -c release --skip-build \
    --filter Qwen35ArtifactProjectionBatchPerfTests 2>&1 |
  tee /tmp/qwen35-artifact-projection-batch-serving.log

# Fixed-chunk diagnostics at the requested larger historical rectangles.
DARKBLOOM_QWEN35_ARTIFACT_BATCH_BENCH=1 \
DARKBLOOM_QWEN35_ARTIFACT_BATCH_BENCH_M=512,2048,8192 \
DARKBLOOM_QWEN35_ARTIFACT_BATCH_BENCH_LAYERS=2 \
  swift test -c release --skip-build \
    --filter Qwen35ArtifactProjectionBatchPerfTests 2>&1 |
  tee /tmp/qwen35-artifact-projection-batch-fixed2.log
```

The exact aggregate uses model multiplicities 27 QKV, 54 A-or-B, and 18
K-or-V. Its emitted terms are `1x27`, `2x27`, and `2x9`: precisely the five
serving family calls. Only this `M=320 geometry=serving` disposition applies
the 1.62058x projection gate. Layer-overridden and larger-M values are
diagnostics, and the row-gather control is never credited as a candidate.

The nested upstream rejects this agent identity with HTTP 403. The batching
implementation and initial probe are therefore published as ordered patch 079;
the exact-geometry correction is ordered patch 080. Apply 080 after 079. The
root gitlink remains on a fetchable commit.

Only after the projection gate passes, run the serving cell:

```bash
cd provider-swift
export DARKBLOOM_QWEN35_PREFILL_ARTIFACT_ONLY=1
export DARKBLOOM_QWEN35_PREFILL_FULL_LAYERS=0-3
export DARKBLOOM_QWEN35_PREFILL_FRONTIER_TOKENS=192
export DARKBLOOM_QWEN35_PREFILL_MOE_TOP_K=4
export DARKBLOOM_QWEN35_PREFILL_ARTIFACT_PROJECTION_BATCH=1
export DARKBLOOM_QWEN35_PREFILL_ARTIFACT_PROJECTION_BATCH_MIB=128

.build/release/darkbloom benchmark \
  --model qwen3.6-35b-a3b-vl-mtp-mxfp8 \
  --scheduler-prefill \
  --prefill-lengths 512,2048 \
  --prefill-iterations 3 \
  --kv-backend contiguous
```

Record requested/effective policy, selected layer chunks, output/state
parity, active/peak memory, every sample, median throughput, and any fallback.
An enabled flag without effective cross-layer batches is a control, not a
candidate result.
