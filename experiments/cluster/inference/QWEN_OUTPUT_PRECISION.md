# Dense Qwen output precision — 2026-09-13

Widening attention/GDN and dense FFN output projections makes 11 of 12 BF16
synthetic solo/TP comparisons exact on the CBv2 path. One full-TP case still
fails the unchanged numerical gate. Wider policies also change native solo
outputs, including two synthetic token choices. They remain explicit
experimental options; `native` remains the default.

This record also isolates a separate vocabulary-projection shape effect using
the same evaluated hidden tensor, including the registered Qwen3.5 9B artifact.
The real-model checks are bounded solo diagnostics. They provide no real-model
TP, physical RDMA, M3 Ultra throughput or model-quality qualification.

## Implementation and identity

`--ffn-output-precision native|float32` controls dense Qwen's down projection.
The Float32 candidate casts its input before quantized multiplication, retains
Float32 through any rank reduction, then casts once to the incoming activation
dtype. It preserves gate/up projections, SILU, normalization and stored packed
parameters. It retains the concrete `Qwen3NextMLP` required by CBv2 typed
dispatch. All target layers are validated before replacements are installed.

`QuantizedOutputLinear` in `AttentionOutputPrecision.swift` implements the
shared projection/reduction behavior. `FFNOutputPrecision.swift` installs the
solo policy, and `FFNSharding.swift` installs it for partitioned models. Both
require supported affine W4/G64 quantization without an ordinary linear bias.
Duplicate wrappers and unsupported models are rejected. MoE and Gemma reject
the new nonnative option; Gemma's whole-branch precision remains separate.

Schema **9** reports and protocol **5** workers require `ffnOutputPrecision`.
Qwen plan identity, peer agreement and readiness bind the policy separately
from attention precision; requests bind to that admitted epoch/model load.
Old worker versions 1–4 are
rejected. The Python workload field is `ffn_output_precision`, default `native`.

Unchanged packed parameters do not imply unchanged memory or communication
cost. Wider affine constants can be cached by the quantized layer; activations
and collective payloads are wider. Use matched-policy solo controls and measure
these costs before selecting the policy for performance.

## Synthetic precision matrix

The 78 logical executions comprise 72 BF16 runs and six Float32 controls. Each
BF16 case runs four policies across solo, FFN TP and full TP. All use the actual
dense CBv2 model/state path, eight captured output rows, and seven fixed teacher
inputs. Two processes communicate over the actual TCP ring on one local Mac.
The tiny and `qwen27-heads` fixtures have small hidden/layer dimensions; neither
is a real 27B model.

The six cases are tiny seed 7 with prompt/chunk 65/32 and 37/16, plus
`qwen27-heads` with seed/prompt/chunk 7/65/32, 31/96/32, 101/129/32 and
503/193/32. The unchanged per-row gate requires maximum absolute error below
`1e-3`, relative RMS below `1e-4`, and matching argmax.

| Output projections widened | FFN TP passes | Full TP passes |
|---|---:|---:|
| Neither | 0/6 | 0/6 |
| Attention/GDN only | 0/6 | 0/6 |
| FFN down only | 5/6 | 0/6 |
| Attention/GDN and FFN down | 6/6 | 5/6 |

Every BF16 pass is also exact. Both-wide policies agree on all 96 compared
argmax rows. Their remaining full-TP failure is seed 31, prompt 96/chunk 32:
only row zero differs, with maximum absolute error `0.009765625` and relative
RMS `0.00547284137`; all seven teacher-controlled decode rows are exact.
Both sides use CBv2's same output-narrowing schedule, so the separate ordinary
versus CBv2 projection-shape diagnostic below does not explain this failure.

FFN-only widening misses FFN-TP at seed 101, prompt 129, rows 2–6, with worst
relative RMS `0.00339564041`. Its full-TP tiny prompt-37 case also changes row
three's argmax from matched-policy solo 310 to TP 412. All peer rank logits are
exact in every completed pair; peer agreement alone does not establish solo
parity.

Each wider solo policy differs numerically from native in all six cases. Each
changes two of 48 argmax choices: tiny prompt 37 rows three/four change from
412/118 to 310/79. Better agreement with a matched wider solo is therefore not
native-policy equivalence or a quality result.

The four Float32 TP comparisons pass, with worst relative RMS below `7.92e-7`.
Quoted matrix errors use the audit's reconstructed IEEE754 tensor values;
computing on serialized JSON decimals changes trailing digits, without changing
any acceptance decision.
Native and both-wide Float32 outputs are exact within each corresponding
solo/FFN/full mode. Six previous native BF16 controls also reproduce exactly,
covering both fixture profiles and all three partition modes at prompt 65.

## Isolating final projection shape

`--mode qwen-output-check` captures an ordinary model's evaluated hidden
tensor, then compares full normalization/projection, full normalization followed
by a one-row projection, and one-row normalization/projection. It uses the same
actual final norm and quantized head for each branch. Prompt/chunk limits are
512, with one output, one repetition, zero warmups and native policies.
It reports diagnostic hashes, norm values and numerical differences without a
numerical pass assertion or throughput measurement.

Twelve synthetic calls cover two fixtures, Float32/BF16 and final chunk widths
one, two and 32. Full versus narrowed normalization is exact throughout. The
recomputed full-head result also equals the original result throughout.
Widths one/two are exact across all branches. At width 32, the BF16 head shape
changes 272/512 tiny logits and 265/512 qwen27-heads logits, with maximum
absolute error `0.0078125` and relative RMS about `0.00344`/`0.00347`.
Float32 differences stay below `2.64e-7` relative RMS. All argmax choices agree.

The qwen27 seed-31 full/narrowed head hashes match the previous ordinary/CBv2
solo first-row hashes exactly. Projection shape alone is sufficient to reproduce
that specific gap. This does not prove equality of CBv2 trunk/cache bytes or
identify a unique internal Metal kernel cause.

## Bounded registered Qwen3.5 9B checks

All 12 registered files were rehashed, totaling 6,113,952,230 bytes. Their
aggregate is
`127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b`.
The experiment uses actual W4/G64 weights and BF16 metadata/activations, with
MTP disabled. It runs six short solo calls: two same-hidden diagnostics with
65/96 prompt tokens, then four generation controls with the same 96-token prose
prefix, chunk 32 and four outputs.

The ordinary native control supplies the three teacher inputs for CBv2 native,
CBv2 FFN-wide and CBv2 both-wide controls. All four argmax sequences agree:
`[4087, 13, 271, 1206]`. This single fixed-history sample is not a quality test.

At prompt 65 the diagnostic branches are exact. At prompt 96, normalization
remains exact while the full 32-row versus single-row vocabulary projection
changes 100,298/248,320 logits: maximum absolute error `0.125`, relative RMS
`0.00215441019`. Actual head/norm tensor hashes match the verified safetensors.
The full/narrowed first-row hashes also match the independent ordinary/CBv2
native controls. Those controls' next three teacher decode rows are exact.

Widening precision changes all four rows even when CBv2 is held fixed. Relative
to CBv2 native, worst-row relative RMS is `0.01265845163` for FFN-wide and
`0.01412320609` for both-wide. None of the six pairwise four-row comparisons
passes the strict gate, despite all argmax choices agreeing.

| Solo control | Peak active MLX bytes |
|---|---:|
| Ordinary native | 5,265,031,082 |
| CBv2 native | 5,283,110,656 |
| CBv2 FFN-wide | 5,519,546,102 |
| CBv2 both-wide | 5,609,991,782 |

The peak resets after model loading. It includes resident loaded buffers and
active execution allocations, including lazy precision casts. It excludes the
earlier loading peak, free allocator cache, host arrays/JSON and process RSS.
The two standalone diagnostics expose no peak measurement.

## Validation and reproducibility

The release build passed. The 173-test CPU suite passed with unchanged source
hashes. Native operator output contains 75 records, including two new FFN
wrapper checks with exact Float32/BF16 reference comparisons and preserved
parameter handles/storage; other records include numerical diagnostics rather
than universal pass assertions. The native protocol check accepts 4,112
fixtures and rejects 97. Its version-5 canonical fixture SHA-256 is
`d269b0584795c3542a1524afbd01e57dea67e58402716c0474a8d30cd78177c6`.

Six persistent both-wide cohorts cover tiny/qwen27-heads BF16 across
solo/FFN/full modes. All 24 A/B/A and one-token requests complete, retain one
model load per rank, and match repeated-A and six fresh controls exactly.
Single-output requests execute zero decode forwards. Cancellation retires and
reaps each solo/FFN/full epoch; reuse is rejected. Command mismatches reject
before acceptance, and mismatched FFN precision rejects before readiness.
Six additional invalid CLI combinations reject before model loading.
Their receipt retains summarized outcomes, corroborated by the source guards;
separate raw stdout/stderr files were not retained for those six cases.

Tested executable SHA-256:
`74ab08e0d55dbb00b7f5603ec7b686ef7dab2021fcdc790bc816d29c03b3fcb1`.
Main matrix experiment-source manifest SHA-256:
`32acc8968a811f39bf7c0be9d401d93b633d4f6e38c5f7ac54e71a9e1107f964`.
This snapshot is not a complete dependency-build attestation.

Raw receipts, archived sources, bundle hashes and independent CPU audits are
retained outside Git in the private research workspace under these run names:

- `qwen-ffn-output-smoke-20260913` and `qwen-ffn-output-precision-20260913`.
- `qwen-output-boundaries-20260913` and `qwen9-output-boundaries-20260913`.
- `qwen-ffn-output-workers-20260913` and `qwen-ffn-output-failures-20260913`.

The original failure receipt has a stale `report_schema_version: 8` annotation;
its protocol is version 5, and the tested binary uses report schema 9. This
metadata error is preserved with a separate audit erratum. Those failure cases
exercise worker frames, not acceptance of a schema-8 inference report.

Independent replay verifies all 78 matrix runs and six real-model calls,
including source/artifact identities, peer outputs, native regressions and raw
logit metrics. The matrix has no hardware-throughput candidates; the real-model
receipt explicitly disclaims throughput qualification. Solo native timing flags
can remain true because capture happens after their timers; this does not turn
these diagnostic experiments into performance evidence.

The integration remains serialized dense CBv2 with contiguous KV, fresh
request-owned state and no production EngineV2 scheduler, paged backend, prefix
reuse, MTP or state handoff. The [distributed goal](../../../docs/design/distributed-inference-goal.md)
remains active; neither the 800 TPS acceptance target nor physical two-machine
correctness has been qualified. See the [previous CBv2 record](CBV2_VALIDATION.md)
for the preceding implementation and its historical schema/protocol versions.
