# Qwen3.6 operator replay reproduces the captured arithmetic difference

> Last updated: 2026-09-06 · commit `75b526348`

Three genuine operators reproduce the two previously captured attention
outputs on exactly the same input. Native SDPA matches the contiguous capture
byte for byte. Both fixed and segmented paged attention match the paged
capture byte for byte, and both return the complete supplied KV history
unchanged. This isolates the selected attention-output difference to operator
arithmetic on those bytes. Whole-model exact-token comparison remains failed.

## Exact common input and actual operators

The [confirmed model packets](2026-09-06-qwen36-owner0-packets.md) select
Qwen3.6 dense attention owner 0 / model layer 3, output index 62, seed 11346,
offset 5584→5585 and scale 0.0625. All five input tensors are byte-identical
across the original captures: query, incoming K/V and full chronological K/V.
They retain BF16, 16 query heads, two KV heads, head dimension 256 and history
length 5,585. The replay input SHA-256 is
`17114f5243a9657bfcc3d4c7d1f3d9362bffeb744b1ceb5f815c321f0479d487`.

The [standalone replay](2026-09-06-attention-operator-replay.md) invokes actual
MLX native SDPA, actual fixed-pool decode and actual segmented-pool decode in
three separate processes. Each paged arm seeds T−1 through the existing bulk
writer/fence and writes the incoming token through real decode. Full ordinary
gathers then verify the resulting chronological storage. No model is loaded
for replay. The paged receipts report 350 distinct physical pages and
partition size 256; the segmented pool reports six segments.

| Replay output | Native mismatches against contiguous capture | Native mismatches against paged capture |
|---|---:|---:|
| Native SDPA | 0 / 4,096 | 786 / 4,096 |
| Paged fixed | 786 / 4,096 | 0 / 4,096 |
| Paged segmented | 786 / 4,096 | 0 / 4,096 |

Fixed and segmented outputs are identical. Each paged arm's complete stored
keys and values match all supplied bytes, including the selected incoming
row. All outputs and the FP32 reference are finite. The unchanged full
collector and the additional comparison against both captures report no
inconclusive reasons.

## Descriptive numerical comparison

The original-Q NumPy 2.4.2 FP32 reference remains the primary numerical
comparison. Python 3.14.7 runs locally with BLAS/OpenMP/VecLib threads pinned
to one. Per-head/global errors, nonfinite counts and native mismatch counts
are preserved without introducing an error tolerance or release gate.

| Reference metric | Native SDPA | Both paged arms |
|---|---:|---:|
| FP32 maximum absolute error | 0.00456417 | 0.00384080 |
| FP32 RMSE | 0.000472879 | 0.000443057 |
| FP32 rounded to BF16 maximum error | 0.0078125 | 0.00048828125 |
| FP32 rounded to BF16 RMSE | 0.000445816 | 0.00000762939 |

These values reproduce the original packet analysis. The separately retained
FP64 cross-check in the packet report supports the same ordering. Paged output
is closer to this reference at the selected operator; overall model quality
remains a separate measurement. No arithmetic was changed to force the paged
output to reproduce baseline token choices.

The replay reproduces the operator numerical difference on equal supplied
inputs, with exact placement checks in both replay pools. It does not
reconstruct the original physical slabs or independently
verify every earlier model-history write. The pinned MLX source's intermediate
BF16 narrowing remains a candidate internal mechanism; the replay identifies
the actual API/operator, without tracing MLX's internal kernel pipeline.

## Runtime, lifecycle and evidence

The optimized standalone binary uses parent
`0b91fa8d4ed56f03c60ed5f155183bc457d6952b`, native
`7d32d43977a5774f223b6892ecfbbaa844047600` and executable SHA-256
`9481f37927932a1887116879c77562d554bdcc6b189ab4a5d765ec2a0e0be846`
(33,648,800 bytes, mode 0755). Build and six refusal smokes pass. Independent
review verifies 975 build payloads, two declared test symlinks, all seven
runtime files and 595 compiler source references. Six resources retain their
reviewed bytes/modes; compact source, graph and runtime proofs accompany the
actual results here.

All three operator processes exit 0. Each launch has an idle/cooled host guard,
exact source/input/runtime validation, a 180-second native timeout and owned
process-group cleanup. Twenty-one controller CPU functions include harmless
child HUP/TERM cleanup tests; six common-input comparison tests, four staging
recovery tests and two path-alias tests also pass. Numerical interpretation
runs after the independent arms complete, while transport integrity failures
stop successors.

Two plumbing failures are retained. The populated stage originally omitted
its JSON completion message; an independently verified completion receipt
resumes the exact staged runtime without overwriting the failed receipt. The
supplementary local comparison originally passed an unresolved `/tmp` alias to
a strict path helper; resolving the owned root fixes that call in a fresh
analysis directory. The original and corrected primary collector outputs are
byte-identical. Neither event reruns an operator or changes native inputs.

Final postflight has no owned jobs, GPU temperature 26.003 degrees C, load1
1.210 and 350,952,955,904 free bytes. The original model/cache/capture roots
remain retained.

The [manifest](evidence/qwen36-owner0-replay-2026-09-06/manifest.json) and
[archive](evidence/qwen36-owner0-replay-2026-09-06/payloads.tar.gz) contain
246 regular payloads: actual outputs/full readbacks, controls and failures,
analyses, exact bindings, source/graph proofs and independent reviews. The
complete original input tensors remain in the linked packet archive; this
archive retains their hashes and selected original output references without
duplicating the full input. Runtime executables/resources, weights, keys and
bulk unchanged native source copies are excluded.

The [additional independent byte review](evidence/qwen36-owner0-replay-2026-09-06/root-byte-review.json)
rechecks all five common inputs, the 4,096-element output comparisons and both
paged full KV readbacks. It is retained alongside the unchanged archive.

Manifest SHA-256: `4ba74ee042da9ca54b279f83c8a76d6deea18387c2187009269c59e479f569d2`.
Archive SHA-256: `3fc5c7f7bacce2e3f7b7d62d20695a441d002e6657c11ef2a689c70af6b03dfa`
(18,744,667 bytes).

This is one selected operator input, with one execution per arm. Whole-model
quality, MTP/lifecycle coverage, other model differences and repeated serving
performance remain separate requirements. No latency or decode improvement
is banked by this numerical experiment.
