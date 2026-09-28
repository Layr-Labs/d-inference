# Gemma FFN branch precision experiment — 2026-09-13

The experimental `--ffn-branch-precision float32` policy improves synthetic
Gemma BF16 solo/TP agreement. Six of eight paired cases become exactly equal,
and all 64 compared argmax choices agree. Two cases still exceed the strict
logit bounds. The policy also changes ordinary solo results, including one
argmax choice. **This is a numerical candidate, not real-model quality or
performance qualification. The default remains `native`.**

## Arithmetic boundary

The Gemma adapter applies the same policy to solo and two-rank execution:

1. Run each branch's ordinary input RMSNorm in its incoming activation dtype.
2. Promote that normalized result to Float32 before gate/up projections.
3. Retain Float32 through projections, GELU, expert weighting and the branch
   collective. Router computation remains outside these widened paths.
4. Cast the reduced branch result once to the recorded incoming dtype, then run
   that branch's original output RMSNorm.

This widens the entire dense and sparse FFN branches, not only their down
projections. The branches retain separate normalization and the existing
per-layer dependency ordering their two collectives. `FFNBranchCast` pairs
input/output during graph construction and clears its dtype state before the
next forward. It introduces no evaluation or dependency across requests.

`FFNBoundaryNorm` retains the native norm parameter storage through MLX's normal
parameter-update operation. All packed weights, stored quantization metadata,
parameter shapes and dtype/layout commitments remain unchanged. The pinned
`QuantizedLinear` and `QuantizedSwitchLinear` widen affine constants to the input
dtype and cache those constants. Thus unchanged stored parameter bytes do not
imply unchanged resident memory. Float32 arithmetic and twice-width branch
communication can also cost latency.

Whole-model runs check that the branch reaches its reduction boundary in
Float32; unexpected narrowing fails immediately. The boundary test compares
F32/BF16 norm transforms and three deferred graphs against direct expressions,
checking native storage addresses and exact values. MLX may use a different
Swift `MLXArray` object while retaining the same native array storage.

## Matched solo/TP observations

The fixtures are the same reduced Gemma models described in
[Gemma runtime validation](GEMMA_RUNTIME_VALIDATION.md): mixed W4/W8 and uniform
W8 with G64, H128, four layers, four experts/top-2, PLE, sliding/full attention,
shared KV and unequal dense/expert slices. Both use BF16 stored floating
parameters for the main comparison. These are not the production 26B geometry
or weights.

Seeds 7, 31, 101 and 211 were selected before this matrix ran. Seed 7 uses 65
prompt tokens/chunk 32; the others use 97/chunk 16. Each case produces eight
logit rows under seven fixed teacher inputs. All TP rank logits match each
other exactly. Native-policy rows and the wider-policy rows use identical
weights and token histories.

| Quantization | Seed | Native worst row relative RMS | Wider worst row relative RMS | Native argmax agreement | Wider argmax agreement |
|---|---:|---:|---:|---:|---:|
| Mixed W4/W8 | 7 | 0.060147 | 0.015448 | 7/8 | 8/8 |
| Mixed W4/W8 | 31 | 0.228170 | 0 | 8/8 | 8/8 |
| Mixed W4/W8 | 101 | 0.249862 | 0 | 7/8 | 8/8 |
| Mixed W4/W8 | 211 | 0.036981 | 0 | 8/8 | 8/8 |
| Uniform W8 | 7 | 0.036877 | 0 | 8/8 | 8/8 |
| Uniform W8 | 31 | 0.057435 | 0 | 8/8 | 8/8 |
| Uniform W8 | 101 | 0.037713 | 0.015070 | 8/8 | 8/8 |
| Uniform W8 | 211 | 0.032178 | 0 | 8/8 | 8/8 |

The remaining maximum absolute differences are 0.058585 and 0.050727. These two
cases do not pass the existing maximum-absolute <0.001 and per-row relative-RMS
<0.0001 bounds. Exact argmax agreement does not override the failed bounds.

Four F32 control pairs (two profiles, seeds 7/31) pass the strict bounds and
match the archived native-policy F32 logits exactly. The newly built native
BF16 path also matches the archived seed 7/31 results exactly. This checks both
that the F32 cast policy is an identity on already-F32 activations and that
ordinary BF16 behavior was preserved.

## Departure from the ordinary solo baseline

Improved agreement between two wider executions does not establish equivalent
model behavior. The wider solo run differs from the ordinary BF16 solo run:

| Quantization | Seed | Worst row relative RMS | Matching argmax rows |
|---|---:|---:|---:|
| Mixed W4/W8 | 7 | 0.195301 | 8/8 |
| Mixed W4/W8 | 31 | 0.225402 | 8/8 |
| Mixed W4/W8 | 101 | 0.249678 | 8/8 |
| Mixed W4/W8 | 211 | 0.041417 | 7/8 |
| Uniform W8 | 7 | 0.054135 | 8/8 |
| Uniform W8 | 31 | 0.051230 | 8/8 |
| Uniform W8 | 101 | 0.050182 | 8/8 |
| Uniform W8 | 211 | 0.212484 | 8/8 |

Router arithmetic is unchanged, but later routes can change as preceding layer
outputs change. This matrix does not capture Gemma router choices or isolate
the source of the residual two-case discrepancy. Neither route amplification
nor BF16 rounding at the output norm is established as its cause by these
observations. Controlled teacher histories also do not test free-running text
quality. Actual artifact quality and latency must be evaluated separately.

## Runtime and regression checks

Native reports now use schema 7 with required `ffnBranchPrecision`; workers use
protocol 3 with the same field in the common identity. The Gemma plan fingerprint
also binds the policy. Defaults are explicit, unsupported values are rejected,
and Qwen accepts only native FFN precision. Different rank policies fail before
readiness. Historical reports retain their original executable/runtime snapshots.

- Four wider BF16 Gemma cohorts pass 12 A/B/A requests and four fresh one-shot
  controls, with one model load per rank and exact request isolation.
- Six Qwen cohorts pass 18 A/B/A requests and six fresh one-shot controls under
  the new protocol, covering dense, MoE and BF16 head-profile execution.
- Actual native solo/TP cancellation retires the epoch and reaps every worker.
  Mismatched request prompts fail before `accepted`; mismatched precision
  policies fail before `ready`.
- Five invalid native precision configurations fail before model construction,
  including a real-directory Qwen configuration.
- All 147 Python tests pass, including protocol matching and actual local
  process lifecycle fixtures. No Python source changed after that test receipt.
- Native protocol: 4,112 accepted and 93 rejected fixtures. Metadata planning:
  9,166 accepted checks, 26 rejected fixtures and eight malformed storage
  commitments rejected. The operator suite passes all 71 emitted records,
  including the new boundary tests and existing Qwen/Gemma checks.

Two initial test failures were fixture assumptions: a short-pipe check still
expected protocol 2, and a norm test incorrectly required Swift object identity.
The corrected tests require protocol 3 and unchanged native storage/values.
Both initial failures remain in the development log; the final binary passes.

## Reproducibility and next gate

The final executable SHA-256 is
`99d539d3400ab186be80e2bfe003d1db9f202fb95d5c8d56e9b49d956a0b325b`;
the one-shot bundle-manifest SHA-256 is
`3582be53622b55acb943c6fabc4ed25b9fcfbd59c0a6fdde07076390351329d0`.
The 40-execution matrix source-manifest SHA-256 is
`0bb766e83d4ffeac67f3da3adb5d702e12f56a1977c46302d44294b9204182a5`.
Code is retained in that archive; later documentation edits are outside it.
Repository base and pinned dependencies are unchanged from the preceding report.

Private raw logits, run specifications, native output, drivers, source archives
and receipts remain outside the repository under
`gemma-ffn-precision-20260913`, `gemma-ffn-precision-workers-20260913`, and
`gemma-ffn-precision-failures-20260913`; Qwen regression evidence is in
`ffn-precision-qwen-regression-20260913`. All cooperative execution uses two local
processes on the development M4 Max with explicit synthetic loopback. Timing is
not a hardware-cluster throughput measurement.

The next numerical gate is to locate the remaining divergence without forcing
baseline expert routes or weakening bounds. A performance choice additionally
needs real-artifact quality, measured extra memory and paired latency results.
The [active M3 Ultra goal](../../../docs/design/distributed-inference-goal.md),
real RDMA and opt-in provider integration remain unverified.
