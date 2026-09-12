# Qwen3.6 attention outputs differ on identical captured inputs

> Last updated: 2026-09-06 · commit `0b91fa8d4`

Four real-model control/capture cells pass their integrity and trajectory checks.
At dense attention owner 0, the two backends have identical captured query,
incoming key/value, full stored key/value and scale bytes, but 786 of 4,096 BF16
output elements differ. The strict backend token comparison remains failed;
these observations do not establish model accuracy or release acceptance.

## Same-build controls and confirmed selection

The [combined optimized probe](2026-09-06-packet-cancellation-release-build.md)
uses parent `98103b39741a48f9d47026be7393362318a2ab0a`, native
`dcf39f6b43effaa2b483211c97d7d3a3e7c0269b` and executable SHA-256
`5839807f14649132591f7381ad0993a56afcd6e0cf864432db77efd10ce2eeeb`.
Six runtime resources retain reviewed build8 bytes/modes. All four M5 runs use
Qwen3.6-35B-A3B-VL-MTP MXFP8, B1, cache off, MTP off, the production KV grant,
September 6 prompt rendering and the same verified model/input artifacts.

Contiguous and paged controls each reproduce their own historical trajectories.
Each main prompt has 5,523 token IDs and each output has 83 token IDs. Controls
share the entire prompt and first 62 generated IDs; at index 62 contiguous
selects 1928 and paged selects 6829. The strict comparison preserves five
mismatch entries across main, tenant and cancellation donor/recovery outputs.

Each capture matches all seven completed same-backend control trajectories,
including prompt/output IDs, counts, finish and outcome. Canceled outputs remain
prefixes of their own recovery outputs. Both captures confirm exactly one
selected forward and all ten attention owners, dense 0–9 / model layers
3, 7, 11, 15, 19, 23, 27, 31, 35 and 39. Original queries, incoming/stored KV,
kernel outputs and outward outputs are BF16 throughout this observation.

The raw packet selects dense owner 0 / model layer 3, request 2, output index 62,
seed 11346, phase `chained_decode`, offset 5584→5585 and scale 0.0625. Selected
candidate logits for IDs `[1928, 6829]` remain `[23.5, 23.5]` contiguous and
`[23.5, 23.75]` paged, preserving the
[previous numerical difference](2026-09-05-qwen36-actual-logits.md).

## Captured native bytes and reference comparisons

| Tensor | BF16 shape B/H/T/D | Cross-backend native mismatches |
|---|---|---:|
| Original queries | 1/16/1/256 | 0 |
| Incoming keys and values, each | 1/2/1/256 | 0 |
| Full stored keys and values, each | 1/2/5585/256 | 0 |
| Attention output | 1/16/1/256 | 786 |

Each packet contains 11,456,512 tensor bytes in six native tensor files plus
its descriptor and owner metadata. All values are finite. The stored final KV
row matches the incoming row exactly, 512 elements per tensor in each arm.
This validates the observed final row; it does not independently validate all
historical cache writes or prove snapshot lifetime semantics.

The unchanged [packet analyzer](2026-09-06-attention-packet-analyzer.md) evaluates
the same captured input with NumPy 2.4.2 FP32 attention. This is descriptive
reference comparison, without an error tolerance or release pass criterion.

| Reference | Metric | Contiguous output | Paged output |
|---|---|---:|---:|
| FP32 result | Maximum absolute error | 0.00456417 | 0.00384080 |
| FP32 result | RMSE | 0.000472879 | 0.000443057 |
| FP32 result rounded to BF16 | Maximum absolute error | 0.0078125 | 0.00048828125 |
| FP32 result rounded to BF16 | RMSE | 0.000445816 | 0.00000762939 |

A separately labeled FP64 cross-check on the same common input measures
FP32-versus-FP64 reference RMSE 1.55602e-7 and maximum error 4.33922e-6.
Captured-output RMSE against FP64 is 0.000472868 contiguous and 0.000443044
paged, preserving the observed ordering. The original FP32 analysis remains
unchanged. Its [supplementary manifest](evidence/qwen36-owner0-packets-2026-09-06/supplementary-fp64-manifest.json)
and [four-payload archive](evidence/qwen36-owner0-packets-2026-09-06/supplementary-fp64.tar.gz)
retain the reviewed script, source identities, analysis and 32,768-byte FP64
reference. This is a numerical cross-check, not a model-quality test.

The paged sample is closer to this rounded reference at this selected operator.
That observation does not establish overall model quality or explain the whole
83-token divergence. The original query is already BF16, so no narrowed-query
counterfactual is evaluated. The captures come from separate model executions;
a controlled native/fixed/segmented operator replay remains necessary.

[INFERENCE] The pinned MLX host source selects standard two-pass vector
attention for this QL1, GQA16:2, KV5585, D256 geometry. Its first pass writes
unnormalized float accumulators through `static_cast<T>` into BF16 partials;
the second pass merges those partials in float. Intermediate narrowing is a
concrete candidate contributor. No actual kernel-pipeline trace or replay has
yet demonstrated that attribution.

## Evidence and remaining work

All four raw executions complete with exit 0. Fourteen unchanged wrapper tests
pass on M5 after exact source/runtime staging. Existing controller validation
has 26 passing CPU tests. Packet analyses use the validated Python 3.14.7 /
NumPy 2.4.2 environment with BLAS/OpenMP/VecLib thread counts pinned to one.
The initial control has no local thread override and performs no numerical
packet analysis; all remote model commands/environments remain identical to
their reviewed bindings.

Final postflight reports no owned jobs, GPU temperature 31.945 degrees C, load1
1.529 and 351,480,352,768 free bytes. Existing HTTP/cache/model roots remain
retained. No additional owner or model is run.

The [manifest](evidence/qwen36-owner0-packets-2026-09-06/manifest.json) and
[archive](evidence/qwen36-owner0-packets-2026-09-06/payloads.tar.gz) contain
224 regular-file payloads and two explicitly preserved private packet
directories with mode 0700: 226 archive members total. They retain all raw
packets, source/input/runtime identities, controls, analyses, failed strict
backend comparison, transfer proofs and reviews. Runtime executables, model
weights and key material are excluded; native activation bytes are included
as bounded test evidence.

Manifest SHA-256: `f22191f08fa53f83f8b01bfd9e6bdb2284fc2fa7e65def86633c9bc859efa01e`.
Archive SHA-256: `0ad883a7d23b3de60643197446064e15fd91ac71ee759012f5ef4ebd25f30f81`
(18,633,161 bytes).

Next work is a controlled three-arm replay on the exact captured common input,
comparing every result with both captured outputs. Independent full-history
validation, other owners/models, numerical policy and release promotion remain
separate requirements. This milestone banks evidence and no performance gain.
