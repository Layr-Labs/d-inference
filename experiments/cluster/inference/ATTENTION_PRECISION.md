# Attention output precision experiment — 2026-09-13

Widening attention/GDN output projections and reductions improves the isolated
matrix calculations but does **not** resolve whole-model BF16 MoE disagreement.
The default remains `native`. The optional `float32` policy is an experimental
candidate with no real-model quality or performance qualification.

## Implemented policy

`AttentionOutputLinear` preserves the stored packed W4 weights and quantization
metadata. In `float32` mode it converts the input to F32, uses the existing
quantized linear's exact metadata promotion, retains F32 through an optional
all-sum, and casts once to the incoming activation dtype. Baseline and FFN-only
plans apply the policy to unpartitioned attention outputs; full TP applies it
at the attention/GDN reduction boundary. FFNs and routers execute normally.

`QwenPartitionPlan` v2 fingerprints include this policy. Native report schema 5
requires `attentionOutputPrecision`, and the launcher validates it against the
requested workload and every rank. Numerical policies cannot share a plan
identity just because they load the same tensor ranges. Router trace format 2
also binds precision; legacy format-1 traces can replay only under `native`.

## Projection checks

Six cases cover input widths 256, 384 and 512, output width 128, and one or 32
rows. They use BF16-rounded inputs and metadata with packed U32 weights. A CPU
oracle independently decodes every W4 nibble and computes the affine dot product
using Double accumulation. Stored parameter bytes remain unchanged.

For these exactly representable fixtures, F32 solo and split sums agree exactly
with the CPU reference. After casting to BF16, split-result relative RMS lies
between 0.00165 and 0.00185, versus 0.00257–0.00371 for native split results.
Promoting only already-rounded local results remains a separate diagnostic;
it does not recover precision lost inside the projection.

These checks assert the F32 errors against explicit bounds and exercise the
cast-back ordering. They do not establish whole-model quality or measure a
real transport. The separate full-model cases below execute actual two-process
collectives using explicit loopback transport.

## Whole-model evidence

All cases use four-layer synthetic models, vocabulary 512, prompt length 65,
chunk size 32, eight output logits and a fixed seven-token teacher history.
BF16 fixtures retain F32 recurrent state. The 27B head fixture reproduces head
counts/dimensions with reduced hidden/FFN widths; it is not the 27B checkpoint.

The table reports the largest output-row relative RMS. Every TP comparison
uses a baseline with the **same policy**. The last column separately measures
the effect of changing baseline arithmetic.

| BF16 fixture | Native TP / native solo | F32-output TP / F32-output solo | F32-output solo / native solo |
|---|---:|---:|---:|
| MoE, seed 7 | 0.245065 | 0.286389 | 0.283784 |
| MoE, seed 31 | 0.196589 | 0.191331 | 0.025033 |
| MoE, seed 103 | 0.018270 | 0.157567 | 0.013885 |
| Dense 27B head geometry, seed 7 | 0.012477 | 0.011616 | 0.009211 |

Under the same-policy comparisons, seed-7 F32-output MoE and seed-31 native MoE
match only seven of eight baseline argmax tokens. Other table cells comparing
TP with their same-policy baseline match eight; that agreement does not turn
their large logit differences into passing quality evidence. All continuation
inputs remain teacher-controlled, and both ranks consume identical histories.

The all-F32 MoE control passes the existing strict synthetic bounds, with
maximum row relative RMS 7.0e-7 and eight matching argmax tokens. The new native
path exactly reproduces the previously archived seed-7 ordinary baseline and
full-TP logits. No numerical acceptance threshold was widened.

The worse wide-policy cases show why a locally more accurate matrix operation
cannot be assumed to improve a complete MoE's agreement. It changes rounded
hidden states even on one device; discrete expert selection can amplify the
differences. The earlier [controlled routing intervention](MOE_RUNTIME_VALIDATION.md)
demonstrates such amplification, but does not prove that one remaining
projection or routing precision change will solve every case.

The wide-policy seed-7 trace contains 12 changed expert sets and 11 order-only
changes across 288 token/layer positions. At output row 5, following teacher
token 64, layer 2 changes expert 13 to expert 5 at a tied BF16 probability
cutoff. Its router-input relative RMS is 0.006435; layer 3's input error then
reaches 0.190392 and another expert changes. The final row reaches 0.286389
relative RMS and changes argmax from 473 to 480. Both ranks' complete events and
logits remain exactly equal, and traced logits match uninstrumented controls.
This locates a further routing discontinuity without isolating every source of
the earlier hidden-state differences.

## Reproducibility and remaining work

The 18 ordinary executions and six projection cases use executable SHA256
`1168951b3d7cb36f0dcc7f28c9f1cad4ee4cede80818889d2b6d3da0cbb7e3cb`.
Their runtime bundle manifest SHA256 is
`372eca9e9fc74cbdf39863e8746fcff9c90960c086ba0dde5e93c4b3d4c0ce1c`.
Private receipts retain each specification, rank report, complete logits,
runtime snapshot and comparison. Follow-up traces reproduce uninstrumented
wide-policy logits exactly, and both old-native and new-wide baseline replay
controls are exact. Replaying a baseline under a different policy is rejected.

This is evidence against selecting wider attention outputs as a universal MoE
fix. Preserve native precision as the default; retain policy identity and the
counterexamples when evaluating other plans. Actual checkpoint quality,
long-context state, memory/cost of wider communication, real RDMA, and M3 Ultra
prefill performance remain unmeasured. The
[distributed-inference goal](../../../docs/design/distributed-inference-goal.md)
remains active.
