# Gemma boundary diagnostics — 2026-09-13

Bounded synthetic traces confirm that Float32-to-BF16 branch casts amplify small
solo/TP differences under `--ffn-branch-precision float32`. The local two-rank
reductions match independent Float32 sums, and reconstructed expert selections
stay unchanged. **This locates a numerical mechanism; it does not fix the two
remaining BF16 failures or qualify real-model quality, RDMA or throughput.**

## Controlled execution

The final binary ran four cases, each with solo and two-process loopback TP,
under three schedules: ordinary execution, explicit diagnostic execution without
captures, and the same diagnostic execution with captures. All 24 logical runs
completed. Each uses eight output logits with identical teacher inputs; seed 7
uses 65 prompt tokens/chunks of 32, and the other seeds use 97/chunks of 16.
All use the Float32 FFN branch candidate from
[the preceding precision experiment](FFN_BRANCH_PRECISION.md).

| Fixture / floating parameters / seed | Worst output-row relative RMS, solo vs TP |
|---|---:|
| Mixed W4/W8 / BF16 / 7 | 0.0154484852 |
| Uniform W8 / BF16 / 101 | 0.0150698348 |
| Mixed W4/W8 / BF16 / 31 | Exactly equal |
| Mixed W4/W8 / Float32 / 7 | 0.0000023791 |

In all eight solo/TP control groups, captured logits equal untraced diagnostic
logits exactly, diagnostic logits equal ordinary logits exactly, and ordinary
logits equal the preceding immutable precision archive exactly. The two ranks'
output logits also agree exactly. This verifies that these captures reproduce
the previously observed discrepancy without changing the compared outputs.
It is evidence for these workloads, not a guarantee for every schedule or model.

The synthetic profiles have hidden width 128, four layers, four experts/top-2,
vocabulary 512, shared KV in two tail layers and PLE width 64. They do not
reproduce the registered 26B checkpoint's geometry, weights or specialized
production kernels. See [profile definitions](README.md#synthetic-profiles).

## Reduction and rounding evidence

Across the four cases, shared boundaries are byte-exact between peers. All
384 branch reductions match an independent CPU sum of the captured rank-local
Float32 arrays. The comparator reconstructs native bytes, adds two Float32
values in wider host arithmetic, then rounds once to Float32. Rank-local
partial outputs are expected to differ; peer equality applies to replicated
or reduced boundaries. This checks the tested loopback collective arithmetic,
not physical RDMA or equality with an unpartitioned matrix multiplication.

Every case first differs from solo at layer 0's dense Float32 branch reduction,
with maximum absolute error `5.960464477539063e-8` in that first boundary.
An independent integer-bit nearest-even audit checks all 860,160 captured BF16
cast values and 221,184 Float32 identity-cast values across solo and both ranks,
with zero failures. These counts include replicated peer values.

For uniform W8/BF16 seed 101, layer 0 dense branch, token 10/channel 56:

| Boundary | Solo | TP |
|---|---:|---:|
| Float32 reduced output | -0.17529296875 | -0.1752929538488388 |
| BF16 input to branch output norm | -0.17578125 | -0.1748046875 |
| Branch output norm result | -1.671875 | -1.6640625 |

Solo lands exactly on the BF16 midpoint. TP is `1.4901161193847656e-8` above it.
Both cast correctly, but the post-cast difference is `0.0009765625` and survives
normalization. This directly establishes local cast amplification.

Mixed BF16 seed 7 also has verified flips. Its earliest flip, token 10/channel
79, merges again at the following normalization. A later coordinate in the same
first branch, token 25/channel 24, remains different after normalization.
Mixed BF16 seed 31 develops intermediate BF16 differences but its compared
output logits reconverge exactly. Thus an early flip is not sufficient to
explain an entire final-logit error; propagation and subsequent rounding matter.

Replaying the stock expert-selection operation on the captured router logits
finds zero expert-set or order changes in these four cases. The capture does
not intercept private selected-ID arrays. Router logits/weights can change
while selected IDs remain the same. The evidence does not support attributing
these particular residual failures to changed expert selection.

## Diagnostic implementation and guards

`GemmaDiagnosticExecution.swift` evaluates each prompt chunk's full logits and
pending captures together, checks the outer MLX error handler immediately, and
drains values before the next forward. Ordinary Gemma preparation evaluates
cache state only and can prune several FFNs, including shared-KV tail branches.
Saving those lazy graphs and evaluating them after the request could insert old
collectives into a later collective sequence. The explicit diagnostic schedule
avoids that ordering hazard and remains separate from ordinary execution.

`GemmaBoundaryTrace.swift` bounds pending arrays, shapes, dtypes, total values
and token coverage; writes native hashes plus finite values; and refuses to
overwrite a capture file. Traces bind configuration, prompt, teacher history,
precision, chunk size and rank/partition identities. Capture wrappers preserve
the numerical policy and stored parameters. Reports remain schema 7; diagnostic
fields are optional and emitted only when enabled. Workers remain protocol 3.

Eight invalid CLI configurations fail before model construction. Two native
negative cases reject mismatched schedule or capture settings on both ranks
before inference. The ordinary launcher rejects either diagnostic field by
presence, including false/null/malformed values. The 148-test Python suite and
seven standalone comparator tests pass. Two persistent Gemma BF16 cohorts
(solo/FFN) pass six A/B/A requests and two fresh-process controls with exact
outputs, one model load per rank and closed lifecycle state.

## Reproducibility and limits

The immutable local evidence directory is `gemma-boundaries-final-20260913`.
It contains the copied executable/resources, source snapshot and manifest,
24 execution receipts, raw traces/logits and CPU comparison/cast receipts.
Auxiliary receipts cover CLI rejection, mismatched ranks and worker regression.
The source base is `e4df336bc8399f4fd0a46d1207b594d2514f14f5` plus the captured
experimental worktree. Documentation changes after the snapshot do not change
the tested native or Python implementation.

| Evidence | SHA-256 |
|---|---|
| Native binary | `d39cf2ec2e8c75d1af31532f593458e7894750d2e2d272e0bdaf536622ac8635` |
| MLX metallib | `2129f6132794d84243c02631bc7478417dba0e0dbd10467beab56c11bf20bdd2` |
| Source manifest | `700c113f85c21ea702b5b157bb083e76c241d5206ccfb66e4246a15ec627ccdb` |
| Native matrix driver | `ecca6c21d082d2421e8491e593bbc5f779d1fe9d9e52ee217a4934b01b3718dc` |
| CPU comparator | `253d472b130176ff85402fa7ae0ac7506a9affb7f887f4dc6b904d0fd8102b53` |
| Independent cast auditor | `8499f9e2899321a93ae9af0a7042c82c999ae7cee7bf77b9bae9e529c7b640d2` |
| Cast audit result | `f7f3a88fa0622d93e50734d42bd17189680e50d68795bff5165808cedc13f359` |

No tolerance was relaxed, routes were not forced, and the default numerical
policy remains native. A wider boundary policy needs matched solo/TP and native
comparisons, output-quality evaluation and memory/latency measurements. These
tiny loopback runs establish none of the two-M3-Ultra 800/1000 prefill-TPS target,
real checkpoint quality, production continuous-batching integration, or opt-in
cluster setup and recovery requirements.
