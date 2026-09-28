# Experimental MoE partition boundaries

This document covers a reusable expert-weight partition and the enclosing
model's routing and normalization boundaries. Its local checks use synthetic
tensors and small actual model blocks. Their evidence does not qualify a real
artifact, whole-model distributed MoE inference, or inference performance.
Separate [whole-model Qwen MoE evidence](MOE_RUNTIME_VALIDATION.md) records the
subsequent runtime checks and the unresolved BF16 routing behavior.

## Shared expert primitive

[`ExpertPartitionPlan` and `QuantizedExpertPartial`](Sources/ClusterInference/QuantizedExpertPartition.swift)
partition the intermediate width of **every global expert**. Each rank retains
the same expert count and global IDs. The caller supplies an explicit interval,
SiLU or tanh-GELU activation, and per-projection affine W4/W8 quantization policy
with group size 64. Fused gate/up projections share one policy and select the
matching interval from both halves of their packed output layout.

The primitive accepts `[tokens, hidden]` inputs, global UInt32 expert IDs, and
routing weights. It uses the pinned public `SwitchGLU` and returns one weighted,
full-hidden-width local partial. It preserves supplied scores, including
non-unit sums and learned per-expert scales. Routing, score normalization,
all-reduce, shared branches, branch norms, and residuals belong to the caller.
The caller also guarantees valid expert IDs, finite scores, and complete,
nonoverlapping interval coverage across ranks.

Its reader interface requests named physical tensor selections and requires
compact, zero-offset storage. The source-`SwitchGLU` convenience initializer is
for synthetic/reference work; it starts from an already constructed full expert
bank. Verified checkpoint loading and distributed lifecycle management belong
to the enclosing model integration, not this convenience initializer.

Gemma's 704-wide expert intermediate contains eleven G64 groups. Equal 352-wide
halves would cut quantization groups, so the check uses `[0, 320)` and
`[320, 704)`: five groups and six groups. This is an unequal split of each
expert's inner width, not a division of expert IDs between ranks.

## Primitive check scope

[`checkExpertPartition`](Sources/ClusterInference/ExpertPartitionCheck.swift)
compares local partial sums with an unsplit public `SwitchGLU` oracle. Its
explicit synthetic cases are:

| Activation / layout | Projection bits | Activation dtype | Scale/offset dtype |
|---|---|---|---|
| SiLU, split gate/up | W4 throughout | Float32 | Float32 |
| SiLU, fused gate/up | gate/up W4, down W8 | Float32 | Float32 |
| tanh-GELU, split gate/up | W8 throughout | Float32 | Float32 |
| tanh-GELU, split gate/up | gate W8, up W4, down W8 | BF16 | BF16 |
| tanh-GELU, fused gate/up | W4 throughout | BF16 | Float32 |
| SiLU, fused gate/up | W8 throughout | Float32 | Float32 |

These fixtures exercise sorted/unsorted assignment sizes, skewed high global
expert IDs, non-normalized scores, and invalid contracts. They do not cover every
policy/dtype combination accepted by the primitive. All six primitive cases
passed the native operator run on 2026-09-13; that scope remains separate from
the actual model-boundary qualifications below.

## Actual model boundaries

[`checkQwenMoEBoundary`](Sources/ClusterInference/QwenMoEBoundaryCheck.swift)
invokes the actual private `Qwen35SparseMoeBlock` through `UnaryLayer`, replacing
its expert bank and shared-MLP projection children. Qwen combines each routed
partial with its shared-expert partial gated by the replicated sigmoid gate;
summing these block partials must reproduce the complete block. Both settings
of top-K score normalization are included.

[`checkGemmaMoEBoundary`](Sources/ClusterInference/GemmaMoEBoundaryCheck.swift)
executes the actual public `Gemma4DecoderLayer`. Its dense and routed branches
must each finish their reduction before their own post-branch RMSNorm:

```text
post_norm(dense_norm(sum(dense_partials)) + sparse_norm(sum(routed_partials)))
```

The check injects previously captured peer partials at the actual two RMSNorm
call sites and compares complete decoder outputs. It also includes a concrete
RMSNorm counterexample using `[3, 0]` and `[0, 1]`: normalizing the branches
separately and adding them differs from normalizing their sum.

These actual-block checks use affine W4/G64, hidden width 128, four experts,
top-K two, and one/33 input rows. The six Float32 cases retain maximum-absolute
and relative-RMS error limits of 1e-4 and passed the native operator run.
Private final routing IDs/scores are **not intercepted**. The Float32 path
derives them with an independent CPU oracle from captured actual logits.
Gemma's nonuniform per-expert scales and Qwen's shared gate remain exercised.
Peer reduction is local test replay, not a distributed collective; W8
primitive success does not extend this actual-block scope.

## BF16 boundary diagnostics

Four Qwen and two Gemma cases additionally convert floating parameters and
activations to BF16. They assert the actual output, router-logit, routing-weight,
and quantization-metadata dtypes. Gemma also checks its learned expert-scale
dtype. Every rank must reproduce the captured router logits byte for byte.

The BF16 routing path replays the stock public MLX operations in their original
order. Precise softmax uses wider accumulation but returns BF16. Qwen selects
and optionally normalizes those already-rounded probabilities; Gemma normalizes
selected logits and then multiplies by its actual BF16 per-expert scales. An
independent CPU calculation rounds at those same stages and provides separate
score diagnostics. Private routing results are still not intercepted.

In the 2026-09-13 native operator run, all six BF16 cases had zero selection
boundary ties, byte-identical replicated logits, and exact agreement between
the replayed routing weights and all 204 independently rounded CPU scores.
Unsplit Qwen gated/shared boundaries, Gemma routed boundaries, and Gemma's
individual local-expert replays also matched exactly. All 33-row fixtures
selected every global expert ID at least once. Gemma used the actual rounded
scale values `[0.69921875, 1.1015625, 1.6015625, 0.8984375]`.

Partitioned output diagnostics were:

| Actual block | Rows | Top-K normalization | Maximum absolute error | Relative RMS |
|---|---:|---|---:|---:|
| Qwen MoE | 1 | off | 0.00146484375 | 0.00514226 |
| Qwen MoE | 33 | off | 0.001953125 | 0.00505094 |
| Qwen MoE | 1 | on | 0.001953125 | 0.00524031 |
| Qwen MoE | 33 | on | 0.00390625 | 0.00499753 |
| Gemma decoder, either local rank | 1 | model routing | 0.03125 | 0.00407916 |
| Gemma decoder, either local rank | 33 | model routing | 0.03125 | 0.00339974 |

Before normalization, Gemma dense-branch relative RMS was 0.002294–0.002789;
routed-branch relative RMS was 0.004260–0.004352. Qwen routed-partial relative
RMS was 0.003952–0.004408. The maximum block/decoder absolute errors correspond
to one or two ULPs at each reference's peak magnitude, except Qwen's one-row,
unnormalized case at 1.5 peak ULPs. This is a reference-peak scale, not a bound
on every element's local ULP distance.

These partition errors remain **diagnostic-only, with unqualified numerical
budgets**. Records use `*_moe_boundary_diagnostics` and
`partition-budget-pending`; they do not assert partition numerical success.
The exact replay checks and strict Float32 checks remain enforced. The observed
BF16 errors are measurements from these tiny blocks, not acceptance limits or
real-artifact quality qualification.
