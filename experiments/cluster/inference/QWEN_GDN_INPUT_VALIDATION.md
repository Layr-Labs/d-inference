# Registered Qwen3.5 9B GDN input projection — 2026-09-13

The first recurrent layer already has a numerical partitioning difference
before convolution or recurrence. On one actual, evaluated BF16 input, the
reconstructed full projection and its two head-selected counterparts differ
in 125,801 of 395,264 values (31.827%). The capture run's final vocabulary
logits exactly match its ordinary solo control. This isolates a projection
arithmetic discrepancy; it does not identify every cause of the
[whole-model TP failures](REAL_QWEN_TP_VALIDATION.md) or establish a fix.

## Experiment and identity

Four native calls run sequentially on the local M4 Max with 36 GiB unified
memory, 14 CPU cores and 32 GPU cores: tiny F32 and BF16 diagnostic fixtures,
a registered 9B solo control, and the registered 9B input diagnostic. Each
uses one 32-token chunk, one output, seed 7, zero warmups and one repetition.
The real prompt is the first 32 IDs of the previously frozen 96-token prose
prefix. The old 96-token logits are not a control for this shorter request.
All policies remain native; CBv2 contiguous state and disabled MTP are shared.

Tested executable SHA-256:
`c1fef9e4950fe067787943c07fdfb1f58e514b7ea4658ca89c136bb34aa7063b`.
Registered artifact aggregate:
`127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b`.
Configuration SHA-256:
`c8e767de4953e58352fbc1acbf6615329075ed02fe16a36b8065714d85ee4423`.
The artifact has 12 files totaling 6,113,952,230 bytes. Its canonical text
parameters comprise 927 tensors and 5,038,041,600 stored bytes.

The [diagnostic contract](README.md#gdn-input-projection-diagnostic) retains
bounded configuration and actual token inputs before initialization. The
verified full-model loader pins and hashes file descriptors, then loads the
complete canonical tensors under explicit byte limits. It shares descriptor
preparation with the direct partition loader. Storage limits are not whole
process memory guarantees.

## What is held fixed

Only the first decoder's input RMSNorm is observed. Its replacement calls the
same RMSNorm operation with the original weight and epsilon, returns the
unchanged result, and retains a handle outside the module parameter tree.
The forward evaluates its normal output and all KV/conv/SSM state roots,
commits the request, and closes it before serializing the capture. The original
norm is restored. Input projection classes remain exact frozen
`QuantizedLinear` instances, preserving native fusion eligibility.

Afterward, the diagnostic reconstructs the frozen packed `[qkv,z,b,a]`
projection and two counterparts that select matching Q/K/V and value-head
segments before fusion. It does not take contiguous halves of the fused
matrix. Input K, W4/G64 packing, BF16 metadata and BF16 input/output dtype
are unchanged. Source and fused tensor hashes are checked against the actual
safetensor bytes. All three projections receive the same evaluated
`[1,32,4096]` input, whose logical-byte SHA-256 is
`4581989d3cfa6e0c6a65b17aa3b1f3e4c550085ad7ab6a99c460af68f3ba0f46`.

These are reconstructed fused outputs, not a direct trace of the model's
private fused-output field. Complete first-logit equality with an independent
ordinary solo run checks the combined loader/capture path for this request:
all 248,320 values match and both select token 2018.

## Results

| Input / geometry | Compared projection values | Differing values | Maximum absolute error | Relative RMS |
|---|---:|---:|---:|---:|
| Tiny F32, K128 / full N1028 | 32,896 | 0 | 0 | 0 |
| Tiny BF16, K128 / full N1028 | 32,896 | 0 | 0 | 0 |
| Registered 9B BF16, K4096 / full N12352 | 395,264 | 125,801 | 0.25 | 0.002689177293 |

The real rank outputs each have width 6,176. All six semantic components
differ on both ranks. Per-component relative RMS ranges from
`0.002480024388` to `0.003086345910`. Raw arrays and independently reconstructed
component intervals are retained, along with absolute error and BF16 step
counts. Large step distances can occur near or across zero; they are not
model-quality scores. The tiny fixtures use a different K and do not establish
the real projection's arithmetic behavior.

The pinned Metal dispatch is a concrete explanation to test further. At
M32/K4096, its output-width rule predicts one K partition for full N12352
and two for rank N6176. The split-K implementation stores partial results
in the input dtype before summing. The source is
`libs/mlx-swift/Source/Cmlx/mlx/mlx/backend/metal/quantized.cpp`
(`QuantizedMatmul::eval_gpu`, `qmm_splitk`). This is source-derived dispatch
analysis, not a captured kernel trace or proof that split-K is the only cause.
The measured discrepancy requires neither state advancement nor transport
between projections.

## Verification, memory and limitations

The release build, 187 CPU launcher tests and unchanged worker protocol
checks pass. The new native admission check rejects 44 malformed or
incompatible cases before model execution. Four dense/MoE FFN/full loader
regression calls cover the shared preparation refactor. Dense fixtures also
compare every parameter from the new verified full loader against ordinary
loading, including F16-to-BF16 metadata conversion, bad-aggregate rejection
without parameter mutation, and independent buffers after source deletion.

Every native call exits zero with saved process cleanup. Sampled system
pressure is level 2; no new swap is recorded. Peak sampled owned-process RSS
is 4,181,262,336 bytes for the real solo control and 5,783,322,624 for the GDN
diagnostic. The driver's admission estimate requires 7,729,163,878 bytes of
reclaimable headroom, including an additional 512 MiB for projection/capture
work. Sampling can miss transients, and this is not a hard allocation bound.

The original driver fails after the fourth native call while assembling its
summary: it supplies an `exact` dictionary key twice. The complete native
output, successful cleanup and original failed receipt are preserved. The
future driver removes the duplicate key; no inference is rerun for this
bookkeeping correction. A separate CPU audit reconstructs the completed
results from the frozen raw files.

The private research workspace retains 157 archived source entries, bundle
copies, prompt IDs, raw captures and audit evidence under
`runs/qwen-gdn-input-20260913`. All observations are correctness diagnostics;
there is no throughput, target 27B, M3 Ultra, physical RDMA, or continuation
qualification here. The next arithmetic check should change only projection
accumulation precision on the same captured input and compare both partition
agreement and departure from native. Whole-layer prefill pipelining remains
an alternative that preserves full projection widths, with its own loading,
state, transport and performance requirements.
