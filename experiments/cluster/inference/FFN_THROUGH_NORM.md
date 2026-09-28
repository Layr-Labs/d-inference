# Gemma Float32 through branch normalization — 2026-09-13

Keeping each FFN branch in Float32 through its output RMSNorm fixes the two
previously traced BF16 failures but creates failures in other seeds. Eight of
twelve paired BF16 cases match exactly, compared with nine for the preceding
Float32-branch policy. **Moving this cast is not a general numerical fix. The
candidate remains explicit and unqualified; the default remains `native`.**

## Policy and hypothesis

`--ffn-branch-precision float32-through-norm` preserves ordinary input
normalization, widens the complete FFN branch, reduces Float32 partials, runs
that branch's RMSNorm in Float32 and casts its normalized result back to the
incoming dtype. Dense and sparse branches retain separate reductions and
norms. Both return to BF16 before their addition and the common FFN norm.
The residual, router, PLE and cache interfaces retain their existing policies.

The existing `float32` policy casts immediately before each branch output norm.
The [boundary diagnostic experiment](GEMMA_BOUNDARY_DIAGNOSTICS.md) established
rounding amplification at that location. In the pinned MLX implementation,
`rms_norm.metal` casts the normalized value to the output dtype before applying
the learned weight. Float32 input also makes this step Float32, so moving the
cast removes both early BF16 rounding points. A remaining BF16 output cast can
still straddle a rounding boundary; improvement was a hypothesis.

`GemmaReductions.swift` implements the change with the paired `FFNBranchCast`:
the original policy leaves Float32 in the norm's `before` transform, and the
new policy leaves it in `after`. Dtype state clears during the same forward's
graph construction. Collective order, count and Float32 payload width remain
unchanged. Stored parameters retain their original dtype/layout; the norm
temporarily promotes its weight for Float32 computation. Unchanged parameter
bytes do not imply equal total runtime memory or latency.

The policy has a distinct plan/report/worker identity. Schema 7 and worker
protocol 3 already require this exact field; unknown values fail closed in
older validators. Qwen rejects both wider FFN choices. Existing `native` and
`float32` semantics remain unchanged.

## Paired whole-model results

The matrix contains 60 logical executions on one Mac, using synthetic Gemma
weights and explicit two-process loopback transport. Each BF16 profile tests
six seeds under both Float32 policies in solo and TP modes. Seeds 503 and 997
were selected before this matrix as additional cases outside the preceding
four-seed experiment. Four Float32-parameter solo/TP pairs serve as controls;
four additional ordinary native solo runs supply the new seeds' references.

All runs use eight output logits with the same teacher inputs. Seed 7 uses
65 prompt tokens/chunks of 32; other seeds use 97/chunks of 16. Quantization,
small model geometry and scope match the
[synthetic Gemma profiles](README.md#synthetic-profiles). These cases do not
reproduce the registered 26B artifact or its production engine.

Worst output-row relative RMS, matched solo versus TP:

| Seed | Mixed W4/W8, prior `float32` | Mixed W4/W8, through norm | Uniform W8, prior `float32` | Uniform W8, through norm |
|---|---:|---:|---:|---:|
| 7 | 0.0154485 | 0 | 0 | 0.0147804 |
| 31 | 0 | 0 | 0 | 0 |
| 101 | 0 | 0 | 0.0150698 | 0 |
| 211 | 0 | 0 | 0 | 0.0153192 |
| 503 | 0.1531535 | 0.0128030 | 0 | 0.0114555 |
| 997 | 0 | 0 | 0 | 0 |

Zero denotes exact compared logits. Every nonzero BF16 case fails the unchanged
per-row limits: maximum absolute error below `1e-3` and relative RMS below
`1e-4`. Both policies retain 96/96 paired argmax matches. The new policy fixes
mixed seed 7 and W8 seed 101, creates W8 failures in seeds 7, 211 and 503, and
reduces but does not eliminate mixed seed 503's error. Therefore the two traced
fixes do not generalize across these fixtures.

All four Float32-parameter pairs pass the same numerical limits; their worst
relative RMS is approximately `0.00000238`. They exactly reproduce the archived
Float32-policy logits, as expected for an identity cast. The eight original
BF16 profile/seed pairs under the unchanged `float32` policy also match their
immutable archive exactly.

The candidate changes ordinary solo inference. Against native BF16 solo,
worst-row relative RMS ranges from `0.0402100` to `0.4937848`, and 4/96 argmax
choices change. Against the preceding Float32 solo policy, the range is
`0.0219580` to `0.2948772`, with 3/96 argmax changes. These synthetic departures
are not a real-model accuracy estimate; they prevent treating better paired
agreement on selected seeds as a quality qualification.

## Evidence and decision

The immutable matrix directory is `gemma-through-norm-20260913`, containing the
copied executable/resources, complete source snapshot, run specifications,
reports/logits and comparison receipt. Numeric summaries use the serialized
logit values; raw-byte diagnostic comparisons are recorded separately.

| Matrix evidence | SHA-256 |
|---|---|
| Native binary | `7d9b3261fd325ee22396640616c61c064e9c250ea709fada2be95421117a271e` |
| Source manifest | `a4b4345fc5e9339087f0a5aab6ce0ba351fe198c3045a89615f2d2756c62d1c8` |

The implementation's operator suite passes 73 records, including both policies'
F32/BF16 rounding placement, three deferred graphs per policy/dtype and
unchanged normalization storage. Metadata validation passes 9,174 checks and
26 rejected fixtures, plus eight storage-commitment rejection cases. The
149-test Python suite covers policy forwarding, family restrictions, every
pairwise policy mismatch, distinct worker identities and worker lifecycle.

The final build differs from the matrix build only in its CLI help text. Its
binary SHA-256 is
`8677f940c3b954b609a2dab50c8bd2ee48d77b00a1d46ff281e1f2ae3b0b4bea`;
the final diagnostic source manifest is
`96e2439e33e127f410f9257738916c6610fe4c6a356cc9d8292f04baa214e91e`.
Source comparison verifies this limited native delta and unchanged Python code.

Twelve final-build executions cover mixed BF16 seed 7 and W8 BF16 seed 101 in
solo/TP ordinary, untraced diagnostic and captured diagnostic modes. All four
control groups retain exact outputs across schedules/capture and against the
60-run archive. Across six traces, an independent CPU audit verifies 6,336
raw-byte hashes/dtype records, complete token/call coverage, and 540,672 values
at each of three transitions: exact input widening, unchanged reduction into
the Float32 norm, and nearest-even casting of the norm's result to BF16. Five
independent CPU controls also pass. This confirms the implemented boundary
placement, not whole-model quality.

Four final-build persistent cohorts (both BF16 profiles, solo/FFN) pass twelve
A/B/A requests and four fresh-process controls with exact results and one
model load per rank. Cancellation retires both solo and TP epochs and reaps all
workers. A native request mismatch fails before acceptance; a mismatch between
the two Float32 policies fails before readiness. Evidence resides in
`gemma-through-norm-boundaries-20260913`, `gemma-through-norm-workers-20260913`
and `gemma-through-norm-failures-20260913` beside the matrix archive.

This candidate is retained for reproducible experiments, not selected for model
serving. Do not relax logit bounds or force routes to turn these failures into
passes. Further numerical-policy promotion requires real checkpoint quality
and memory/latency evidence. This experiment establishes no TB5/RDMA transfer,
M3 Ultra speedup or progress toward the target through a measured TPS result;
the primary dense Qwen performance qualification remains outstanding.
