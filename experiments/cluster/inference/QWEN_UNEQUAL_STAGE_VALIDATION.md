# Unequal Qwen layer stages: correctness results

> Last updated: 2026-09-14 · commit `e4df336bc`

The short comparison and a separate two-process run passed with a 12+20 layer
split of the registered Qwen3.5 9B artifact. Both staged executions produced four
full-vocabulary BF16 logit vectors that exactly matched the full-model reference.
These are bounded correctness results on one GPU, with no distributed speed
measurement.

## Workload and results

Both checks used 65 prepared prompt tokens, chunks of 32 and four output
positions, with three fixed teacher tokens for the continuation. Each request
crossed six committed token frontiers: 32, 64, 65, 66, 67 and 68. The
[comparison runner](Sources/ClusterInference/QwenLayerStageComparison.swift)
released its full baseline before loading both stages. Stages retained the
existing full-width layer arithmetic and copied the native residual boundary.

| Check | Layer split | Owned text tensors | State components per frontier | Full logit pairs |
| --- | --- | --- | ---: | ---: |
| Tiny BF16 fixture with F16 layer metadata | 4+8 | 118 / 234 | 27 | 4 exact |
| Registered Qwen3.5 9B | 12+20 | 348 / 579 | 72 | 4 exact |

The real-model check ran in one process on one M4 Pro with 24 GiB memory,
14 CPU cores and 20 GPU cores. It used the existing CBv2 contiguous path,
BF16 weight policy, attention query block 128 and TF32 setting 1. Source text
tensors totaled 5,038,041,600 bytes, divided into 2,032,294,848 and
3,005,746,752 bytes. Inert replacements added 16,384 and 8,192 bytes.

An independent CPU auditor reconstructed all eight real-model logit rows from
their recorded values and checked four pairs of complete native bytes, each
covering 248,320 vocabulary entries. It also checked source/plan identities,
parameter ownership, frame order and state geometry/digests. Raw state arrays
were not exported: the state result rests on native per-entry digest equality
and independently reconstructed metadata and aggregate fingerprints.

## Execution controls and evidence

The real-model parent passed its unchanged source, bundle, raw input and full
artifact checks before and after execution. Native and SSH exits were zero,
the local SSH child was reaped, and no owned remote processes appeared in the
final observation. Fourteen memory samples reported pressure level 1 and zero
swap. Initial actual free memory was 10,277,093,376 bytes; the post-hash sample
reported 9,862,627,328 bytes. These samples do not establish peak process memory
or continuously available memory. Stderr was empty.

| Evidence | SHA-256 |
| --- | --- |
| Native executable used by both checks | `8e4596fe284f610eb7c2d5bda41cd50e448268127e40f43f443a839184a532ee` |
| Registered 9B artifact | `127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b` |
| Real 12+20 plan | `8c3fef079cc82295d70851ef9d9193954afc0d008ad09ce239baaa1a51391fed` |
| Real-model parent receipt | `2e86a72fef86c47d4a001a0b8b0efb694caae90ebbeff5f36f215dfc364538fe` |
| Real-model stdout | `6cfe70e292e0e09bdfa1e8c252251b5898f43ecff6e870729a02a1e406bcb4b9` |
| Real-model independent audit | `1be787ca5a7076dea8c35de91be548d8d94872f9ad8900c64607c9b9ec06b679` |
| Tiny independent audit, V2 | `1c576927029b713a54e13f94b4724d65f45571e1fb48f1b353dafb719666540a` |

The real-model numerical auditor was frozen before candidate execution and
passed unchanged. The tiny auditor's first version rejected receipt ordering:
it expected the Plan's norm/head order, while the
[loader](Sources/ClusterInference/QwenLayerStageInert.swift) emits path-sorted
head/norm receipts. After inspecting that failure, V2 corrected only the expected
receipt order; Plan identities and numerical checks stayed unchanged. The failed
V1 audit remains retained alongside V2. Its original tests and source review had
missed the ordering distinction; four added regressions cover it.

## Two-process 12+20 check

A subsequent run used two native processes on the same 24 GiB M4 Pro, connected
through loopback ring transport. It retained the registered artifact, numerical
policy, 65/32/4 workload and raw prompt/teacher files. Each process loaded only
its stage. The final stage's four complete BF16 logit vectors matched the
separately retained full-model reference exactly, covering 993,280 values per
side. The independent auditor also revalidated the earlier reference.

At each of the six frontiers, the stages owned 27 and 45 state components. The
auditor checked all 432 entries across the complete sequence, including global
ownership, compact local indices, geometry, byte counts and native digests.
It reconstructed frame headers and expected acknowledgements and checked the
peer boundary digests. Raw state, boundary and acknowledgement bytes were not
exported; these checks do not constitute independent byte replay of those arrays.

Both native and SSH exits were zero, both local SSH children were reaped, and
the final observation found no owned remote processes. Eight memory samples
reported pressure level 1 and zero swap. Initial actual free memory was
9,889,579,008 bytes; post-hash actual free was 9,724,805,120 bytes. Each process
emitted exactly the expected loopback warning. Source, bundle, artifact and raw
input identities passed before/after checks, and all 332 archived source files
were checked against their retained and live bytes after completion.

| Two-process evidence | SHA-256 |
| --- | --- |
| Native executable | `f82b05eb2d221152e49c8ecbffff0e091691795be76a20c78cd47d29a108fc23` |
| Parent receipt | `bb6c42a60ecbd5bc140075c999075aa3365fa36c312c9065d7a81e862e2958b1` |
| Rank 0 stdout | `70ae4acc7b77961acbccb92601a5d13cdd44e3c92687b2bcd1c6d42d6a7d30c2` |
| Rank 1 stdout | `ec18b1f767ada06fe5f4ff30ceb25ba6b2076272cf09743444d3f46ba47b0aa2` |
| Independent numerical audit | `a43019d23f4d6ee9f7bc970f6d110987372551c04ed3a45190ec05b871b1f5e5` |
| Source archive correlation | `a2a086b94273c1161cd94903a1bde7c76b7941a2bef29b872d737bca86a34c71` |

The 50-test numerical auditor and 25-test guarded launcher were frozen before
this run and passed unchanged. The new executable adds short-rank cut admission;
the earlier one-process reference remains bound to its original executable.
This private launcher result does not qualify the public Python model entry.

None of these runs used two physical devices or qualified TB/RDMA, 8K unequal execution,
27B numerics, other cuts, or the M3 Ultra throughput target. Native ownership and
release assertions remain source-bound. The archive checks are not an independent
rebuild. See [candidate plans](QWEN_LAYER_STAGE_CANDIDATES.md) for the current
selection API and [the goal](../../../docs/design/distributed-inference-goal.md)
for the broader acceptance criteria.
