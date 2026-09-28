# Qwen MoE runtime and routing diagnostics — 2026-09-13

The experimental Qwen adapter now executes a whole synthetic MoE model through
both FFN-only and full tensor partitions. F32 comparisons pass the existing
synthetic logit bounds. BF16 full partition exposes routing amplification that
remains unqualified. None of these local tests establishes real-checkpoint
quality, two-machine RDMA, or the M3 Ultra prefill target.

## Scope and identity

All routing comparisons use the same four-layer `qwen-moe` fixture: hidden 128,
vocabulary 512, 16 experts, top-4 normalized routing, expert intermediate 512,
shared intermediate 256, and W4/G64 packed weights. BF16 converts all floating
parameters, including A_log; recurrent state remains F32. The workload has 65
prompt tokens, chunk size 32, eight output logits, seed 7 and seven fixed teacher
inputs `[12,25,38,51,64,77,90]`. Diagnostic runs use zero warmups and one repetition.

The transport is two local processes using explicit `loopback-test`. The
ordinary single-device model is the reference. Neither local multiprocess
timing nor deliberately overridden routing is performance evidence.

| Evidence | Executable SHA256 |
|---|---|
| Whole-model/loader integration and realistic-head fixture matrix | `a58bd541d460171c919b6fbc923831405a589190493c89bdf53e70a63cd5fde7` |
| Router captures, uninstrumented controls and composition check | `9191b9ed174b56c3be49b5615d498628f9c67f5b02820693b037c65ec52624e1` |
| Controlled baseline-router replay | `a7d01167ba5c0cdc30ecce91aebf47e05f6b9899faf503333d9fa2ac7a44526e` |

The replay runtime bundle manifest has SHA256
`5a5bbdc86a0ce83161bfb75023ee3bff4660fb82af36123f36ba456a43937a88`.
Raw private run directories retain executable/resource snapshots, rank
configuration, stdout/stderr, complete logits, traces and receipts. The replay
record also archives experiment sources and dependency revisions. These dated
results are bound to those builds, not automatically to later working trees.

## Whole-model comparisons

Relative RMS is computed separately for each 512-wide output-logit row against
the baseline row's energy. The table reports the largest row error; argmax
agreement does not replace numerical validation.

| Dtype / partition | Maximum absolute logit error | Maximum row relative RMS | Changed expert sets across 288 token/layer positions | Output argmax matches |
|---|---:|---:|---:|---:|
| F32 / FFN | 1.252e-6 | 6.622e-7 | 0 | 8/8 |
| F32 / full | 1.312e-6 | 7.024e-7 | 0 | 8/8 |
| BF16 / FFN | 0.03125 | 0.015830 | 1 | 8/8 |
| BF16 / full | 0.385254 | 0.245065 | 10 | 8/8 |

Both ranks have exactly equal router-input bytes, router-logit bytes, replayed
expert IDs/weights and final logits. Every traced output also exactly matches
its corresponding uninstrumented run on the same build and workload. The trace
uses actual captured router logits and the stock public MLX operations to
replay private routing; private expert IDs are not intercepted.

BF16 FFN-only changes one expert set at prompt position 51, layer 1, where the
selection boundary is tied. The full partition's first change is prompt
position 0, layer 1, with router-input relative RMS 0.007816 and no boundary tie.

At the largest output error, after teacher token 90 (processed position 71),
layer 1 changes expert 15 to expert 6. Its input relative RMS is 0.009049 and its
router-logit relative RMS is 0.008103, without a cutoff tie. Input differences
then reach 0.140846 at layer 2 and 0.163082 at layer 3; layer 3 changes another
expert. The final output row reaches 0.245065 relative RMS. Errors of this size
are not accepted merely because all eight argmax tokens agree.

## Controlled routing intervention

`--routing-replay-file` deliberately supplies the baseline's recorded router
logits at every matching layer/call. The partitioned hidden states still enter
the actual expert and shared branches. This holds expert selections and scores
to the reference while retaining the partitioned attention, GDN and expert
computations.

The intervention reproduces the ordinary baseline exactly. For full TP, it
reduces the maximum output-row relative RMS from **0.245065 to 0.014910**, and
maximum absolute error from **0.385254 to 0.03125**. Both ranks agree exactly.
Ordinary solo/full runs on the replay build also reproduce the earlier captured
logits exactly. Mismatched prompt identity and corrupt recorded logit hashes
are rejected before producing a result.

This demonstrates routing amplification as a contributor in this fixture. The
intervention overrides model behavior; it is not a serving implementation,
numerical fix or quality pass. It holds both selections and scores fixed, so it
does not separately attribute their individual contributions. It also does not
isolate every upstream rounding source. In the pinned kernels, tiny output
projections change K from 256 to 128 and cross QMV dispatch and BF16 split-K
rounding boundaries; those are code-backed candidates for further controls.

## Loader and adapter evidence

The Qwen MoE plan preserves global expert IDs and replicates router/shared-gate
weights while splitting routed/shared intermediate channels. Actual converted
35B checkpoint metadata uses split expert gate/up projections. Direct loading
selects each source's local rows before constructing a fused local projection.

Native composition checks compare 36 selections against CPU byte values across
U32 weights and F32/BF16 metadata, two files and both ranks. They verify compact
owned storage after overwriting/deleting the sources, reject 12 unsupported
selection axes and six malformed compositions. Tiny saved whole-model loader
fixtures separately check FFN/full plans, source/canonical tensor counts,
replicated routers and selected byte accounting.

Actual 35B weights have not been loaded. Metadata coverage does not establish
process RSS or actual loading peaks. Both selected source pieces can coexist
with a fused local array; `largestHostTensorBytes` describes one host read.

## Remaining qualification

Preserve these failures as regression cases while investigating arithmetic and
routing stability. Additional seeds, prompts, chunk boundaries, real artifacts,
long-context state and meaningful quality budgets remain necessary. The actual
35B optimized router is outside this H128/E16 stock-router fixture. Gemma has
operator-boundary evidence but no whole-model distributed qualification here.

The [active goal](../../../docs/design/distributed-inference-goal.md) still
requires qualified real-model execution, actual RDMA, measured M3 Ultra
performance and opt-in provider/setup/recovery integration. No TPS target has
been demonstrated by this record.
