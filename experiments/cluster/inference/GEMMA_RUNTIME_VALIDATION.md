# Gemma adapter and worker validation — 2026-09-13

The experimental Gemma 4 FFN plan now uses the same model-loading, transport,
storage-commitment and persistent-worker framework as Qwen. Tiny float32 models
match paired solo execution within the stated numerical bounds. **BF16 solo/TP
agreement is not qualified:** the observed logit differences include one changed
argmax under a controlled token history. No real 26B weights, two-machine RDMA
inference, or M3 Ultra performance are qualified by these results.

## Implementation scope

`ModelPartitionPlan` dispatches family-specific construction, tensor selections
and reduction attachment. `PartitionStorageCommitment` binds ordered rank
layouts and byte counts to a common source tensor manifest. Coverage validation
rejects overlapping or missing axis intervals even if their summed byte counts
would otherwise look correct. Report schema 6 and worker protocol 2 carry this
commitment; local layout hashes may differ only as declared by it. Qwen retains
its additional equal-half storage constraint.

Gemma's `GemmaPartitionPlan` preserves the global router, expert IDs and top-k
count, while splitting each dense and expert intermediate on quantization-group
boundaries. Dense 2,112 becomes 1,024/1,088 and expert 704 becomes 320/384. This
uniform plan is intentionally unequal; it is not a measured load-balancing
choice. Attention, normalization, expert scales, PLE and KV sharing replicate.

Each dense and sparse branch reduces before its own normalization. The sparse
collective has an explicit `MLX.depends` dependency on the dense collective of
the same layer. This orders the two otherwise independent graphs without
changing tensor values. CPU-stream FIFO alone does not define traversal order
for independent lazy graphs. The dependency is consumed during construction of
each layer call; it does not chain separate forwards or force an unused final
FFN during cache-only preparation. Requests remain serialized.

The direct loader accepts converted `gemma4` wrapper checkpoints with canonical
text names and split expert projections. It validates W4/W8 affine G64 policies
and reads only local selected ranges into owned arrays. Unsupported raw fused
layouts are rejected. A complete source manifest is required and checked before
loading; a source-byte counter is not a process-memory peak measurement.

## Build and retained evidence

The build uses base repository commit `e4df336bc8399f4fd0a46d1207b594d2514f14f5`
plus the uncommitted experiment sources. Pinned dependency commits are:

| Dependency | Commit |
|---|---|
| MLX | `3fa8f25e6451174d7b06be372c3a24272b77d88e` |
| MLX Swift | `6d6796d7a81b656d2749d39067e0a6bea2bc2986` |
| MLX Swift LM | `ce446cc5f76e013855fe0bde9002b6db1ac091b7` |

Validation ran on the local M4 Max development Mac, using two local processes
for cooperative cases. The executable SHA-256 is
`0ce0c8862e964e229abf01891520bcab258bb49b1b3b064407339cac53291081`;
the one-shot bundle-manifest SHA-256 is
`8cb5179ac1888a8a2e1df5cd26fa50bd6552537f64cce588ead22c2dc8123c68`.
The source-manifest SHA-256 captured before validation/documentation updates is
`9f4939ad5733dadaeab1538428b5a4e1b5e63cbcc9139044577ad07363b0f785`.
The code in that archive matches the tested code; subsequent edits to the
overview and protocol documentation are not part of that archived snapshot.

Private run directories are retained outside the repository under these names:

| Evidence | Contents |
|---|---|
| `gemma-whole-model-20260913` | Sixteen solo/TP executions, eight comparisons, raw logits, source archive, drivers and receipts |
| `gemma-persistent-workers-20260913` | Eight cohorts, 24 requests and eight fresh one-shot controls |
| `gemma-adapter-qwen-regression-20260913` | Six Qwen cohorts, 18 requests and six fresh one-shot controls |
| `gemma-native-failures-20260913` | Actual native cancellation and rank-command disagreement |

The final build log, metadata/protocol check outputs, direct-loader JSONL,
Python test receipt and checkpoint metadata audit are also retained outside the
repository. The regression driver initially used an unknown Qwen loader mode;
the native executable rejected it before loading. The corrected `loader-parity`
run passed. That driver error is retained in the log and receipt.

## Whole-model numerical observations

Two four-layer fixtures cover mixed W4/W8 and uniform W8, both with affine G64.
They use H128, vocabulary 512, four experts/top-2, unequal intermediate slices,
sliding/full attention, shared-KV tail layers, PLE and double-wide tail MLPs.
The actual 26B model has 128 experts/top-8, H2816 and 30 layers, with no PLE or
shared-KV tail. Its specialized kernel eligibility is not reproduced here.

For each profile and dtype, seed 7 uses 65 prompt tokens/chunk 32 and seed 31
uses 97/chunk 16. Eight output logits are compared with seven fixed teacher
inputs. Attention-output precision is native. TP uses explicit synthetic
loopback transport; both rank logits match each other exactly.

| Profile | Dtype | Seed | Worst row relative RMS | Matching argmax rows |
|---|---|---|---:|---:|
| Mixed W4/W8 | F32 | 7 | 0.000002380 | 8/8 |
| Mixed W4/W8 | F32 | 31 | 0.000002040 | 8/8 |
| Uniform W8 | F32 | 7 | 0.000002012 | 8/8 |
| Uniform W8 | F32 | 31 | 0.000001898 | 8/8 |
| Mixed W4/W8 | BF16 | 7 | 0.060147 | 7/8 |
| Mixed W4/W8 | BF16 | 31 | 0.228170 | 8/8 |
| Uniform W8 | BF16 | 7 | 0.036877 | 8/8 |
| Uniform W8 | BF16 | 31 | 0.057435 | 8/8 |

The four F32 pairs pass maximum absolute error <0.001, per-row relative RMS
<0.0001, and exact argmax agreement. All BF16 pairs are recorded as observed,
not numerically qualified. Argmax agreement alone does not make their logit
error acceptable. Controlled teacher inputs prevent a changed token from
altering the later history; these rows are not a free-running quality test.

These observations isolate a numerical problem in the FFN-only plan, but do
not establish its cause. BF16 partial projection rounding and route changes
are hypotheses requiring direct diagnosis. Casting an already-rounded local
output to F32 cannot recover lost precision. Any wider arithmetic candidate
must compare matched solo/TP policies and separately quantify its departure
from the ordinary baseline, storage changes, and communication cost.

## Storage and lifecycle checks

- Metadata planning: 9,158 accepted checks and 26 rejected fixtures, including
  constructed production-shaped W8 and mixed-policy layouts. These are not
  native loads of the actual 26B config or weights.
- Common storage commitment: eight rejected cases, including overlapping
  selections with apparently correct summed byte counts; independent unequal
  rank byte totals and loaded dtype/layout commitments agree.
- Direct loading: both Gemma profiles pass F32 metadata and FP16-to-BF16
  metadata fixtures. Every selected value, compact owned buffer, local byte
  count and rank layout is checked independently. Corruption is rejected on
  both ranks. Deleting the source files preserves loaded values/storage.
  Qwen MoE full-partition loading also passes both metadata cases.
- Persistent Gemma execution: all eight profile/dtype/solo-or-TP cohorts reuse
  one model load per rank for A/B/A requests. Both A results and fresh one-shot
  controls match exactly, all ranks agree, and every cohort closes. This proves
  request isolation for the exercised path, not solo/TP BF16 equivalence.
- Qwen regression: six dense/MoE/head-profile cohorts pass the same 18-request
  isolation and fresh-control comparisons under the new common protocol.
- Native failure checks: cancellation after the first delivered token retires
  the epoch and reaps all worker processes; later reuse is rejected. Two ranks
  given different prompts reject the command before `accepted` or token output.
- Protocol 2: 4,112 accepted and 91 rejected native fixtures. The canonical
  cross-language fixture SHA-256 is
  `a1f9e8e090c997ca792d217cd4b287520e7badd1210d862a7cbb26a25d9c4182`.
- Python: 137 tests pass, including real local process-lifecycle fixtures.
  Tested Python source hashes were rechecked against the working tree.

## Real-artifact metadata scope

The cached registry/config/index/header audit covers active `gemma-4-26b`
version `2026-05-25-r1` (W8) and QAT4 beta `2026-06-08-r1`. Both contain 1,339
text tensors and 358 excluded non-text tensors. Their 326 quantized text modules
resolve to all W8 for the active artifact, and 206 W4 plus 120 W8 dense/router
exceptions for QAT4. All text floating tensors are BF16.

| Artifact | Declared text bytes | Rank 0 selected bytes | Rank 1 selected bytes |
|---|---:|---:|---:|
| Active W8 | 26,810,869,820 | 13,282,242,620 | 15,505,418,300 |
| QAT4 beta | 14,467,688,508 | 7,167,602,748 | 8,352,688,188 |

These figures come from metadata and the uniform split policy. They are not
measured memory residency, load peaks, or verified weight payload hashes. Full
artifact loading/inference, BF16 quality, real RDMA, production CBv2 integration,
opt-in setup/recovery and the M3 Ultra prefill target remain open under the
[active goal](../../../docs/design/distributed-inference-goal.md).
