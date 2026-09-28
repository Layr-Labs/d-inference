# Registered Qwen 8K prefill reference validation

> Last updated: 2026-09-14 · commit `e4df336bc`

One complete Qwen3.5-9B model processed an 8,192-token prompt in 16 chunks of
512 on a 24 GiB M4 Pro. The native run completed, and the unchanged CPU oracle
passed its source/input/schema checks and reconstructed the complete final
BF16 vocabulary row. This supplies a fresh reference for subsequent comparisons
using the same prompt, chunk size and arithmetic policy. It does not yet compare
another execution or establish inference speed.

The independent archive/provenance replay and separate remote process postflight
also passed. They bind this result to the archived executable and saved remote
controls; they do not reproduce a model forward or rebuild the executable.

| Property | Executed value |
|---|---|
| Host | One M4 Pro, Mac16,7, 14 CPU cores, 24 GiB; macOS 26.6.2 build 25G83 |
| Model and ownership | One full 32-layer Qwen3.5-9B model, one fresh CBv2 request; MTP disabled |
| Profile | `long_prefill_8k_v1`; batch 1; 8,192 input tokens; chunk size 512; output count 1 |
| Input | Pinned generated English prose with repeated paragraphs; first 8,192 of 16,385 tokenizer IDs; no chat template or added special tokens |
| Execution | `cbv2-contiguous`; native BF16 activation; BF16 conversion policy enabled |
| Arithmetic contract | Query block 128, BF16 policy 1 and TF32 permission 1; `MLX_METAL_GPU_ARCH` and `MLX_SDPA_BLOCKS` absent |
| Repetitions | One fresh process and request, zero warmups; no teacher tokens or decode forward |
| Completion | Native exit 0; exactly two JSONL records; empty stderr |

The [reference producer](Sources/ClusterInference/QwenLongPrefillReferenceProducer.swift)
loads the verified full artifact once. Its retained text inventory has 927 tensors
and 5,038,041,600 logical tensor bytes; the raw checkpoint inventory also contains
364 excluded vision/MTP entries. This retained source inventory has no Float16
tensors, so none were converted in this run. The initial ready record precedes model loading
and request-state creation. The terminal record contains the reference evidence
and two allocator observations. Both records retain `correctnessOnly=true` and
`throughputMeasurementValid=false`.

The 51 prospective CPU tests passed before the oracle first accessed candidate
output. Native execution had already begun while the oracle was being finished;
this was **not** a freeze before execution. The tests used synthetic numerical
records and the already pinned input, including signed zero, tied argmax values,
stale source/input/environment replays and malformed state/commit coverage.
The frozen helper was applied unchanged to the completed run.

| Numerical record check | Result |
|---|---|
| Commits | Exactly 16; frontiers 512, 1,024, …, 8,192 |
| Output narrowing | Fifteen `[1,1]` evaluation handles, then one `[1,248320]` logit row; BF16 |
| Final state | 72 component entries; 319,946,784 logical bytes |
| Final state fingerprint | `59659ed425cfadf4e184fcb8533f4c9fd16a4311f37b83df3f06fa48911009f6` |
| Final logits | Complete BF16 `[1,248320]`; 496,640 reconstructed bytes |
| Final logit SHA-256 | `4dea769bd622b97b34a914e2c488ffe599701884561f1a42b1d4ee9dfde6dfe6` |
| Native argmax and CPU crosscheck | Token 271; maximum 21.25; one maximum |
| Captures | No per-frame state/logit captures; one final state snapshot, one final logit capture, one native token selection |

The CPU oracle rebuilt the complete native BF16 final row from the exported
Float values, preserving signed zero, and matched its recorded byte hash. It
independently derived every state entry's layer, component, shape, dtype and
byte count, recomputed the combined state fingerprint, and reconstructed all
eight Int32 position-offset hashes at 8,192. The remaining 64 state-component
hashes expose no raw numerical values; their provenance remains tied to native
capture and the archived executable/source. There was no independent second
model forward. Native commits, finite argmax, retirement and weak model-release
checks are also source-bound assertions, rather than external profiler evidence.

The execution uses the explicitly admitted 128-token attention query blocks
within each 512-token prompt chunk. A future candidate must use the same
arithmetic contract and same-chunk full-model reference. The earlier 65-token
reference cannot stand in for this record. The generated repeated prose does
not establish a representative production workload.

The launcher retained full remote artifact verification before and after,
unchanged source/bundle/input identities, and a 300-second native deadline.
Its initial actual-free screen observed 7,440,465,920 bytes before bundle staging
and model hashing; the post-hash reading was 7,177,863,168 actual-free bytes and
16,167,337,984 estimated reclaimable bytes. These passed the respective screens;
they do not guarantee that memory remains available at inference time. All 24
saved pressure/swap observations and the separate postflight reported pressure
level 1 and zero reported swap. There was no reported new swap in these
observations.

| Memory observation | Bytes |
|---|---:|
| Native MLX peak since process start | 6,500,375,576 (6.50 GB; 6.05 GiB) |
| Active MLX after model release/cache clear | 4,016 |
| Cached MLX after model release/cache clear | 0 |
| Maximum of 20 sampled native RSS observations | 5,932,875,776 |

MLX allocator accounting and sampled process RSS measure different scopes. The
RSS maximum is the largest saved sample, not a proven process peak; missing
samples are not zero. The audit checked saved RSS values and unit accounting;
raw `ps` output was not retained for an independent reconstruction. The separate
745,345,056-byte admission estimate covers
named state/snapshot/boundary terms under a 768 MiB ceiling. It excludes model
weights and native workspaces and is not a whole-process memory bound. Legacy
admission limits remain unchanged.

The local SSH client was reaped. Both the final launcher inventory and the
separate root postflight found no processes matching the owned remote paths.
Independent remote `waitpid` proof is not asserted. The provenance replay
verified the frozen archive, saved control sequence, resource arithmetic and
raw input/origin hashes. It did not compare the later live source tree, reproduce
the build, rerun tokenization or independently re-read remote model payloads.
The saved before/after full-artifact results remain pinned-control attestations.

The executed binary is pinned by SHA-256
`7f779c52fff210fc49be26134763023ed04709ded21ceb0b0ab1accaba43a240`.
The private archive retains 266 source files, dependencies, bundle, arguments,
raw prompt and origin receipt, remote model metadata, observations and native
output. This identity applies to this reference run, not a later comparison
binary.

| Retained evidence | SHA-256 |
|---|---|
| Registered artifact aggregate | `127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b` |
| Raw prompt, 38,405 bytes | `ee6caf0be6391e00ec41df930f0fd6351613969622cbb247b1b4bdaf69afe997` |
| Reference fingerprint | `efe0731e85d5148ac82c9e439498fa0385ea13e38c5970eaa2b1f2232ee8a99b` |
| Native stdout, 2,510,725 bytes | `da85eb1e79a43c16575e6a8ffd48594ccb72306c16543a1e02c24903b89c154a` |
| Launcher receipt | `02a366c7e4d5c8acd2bfb7a3b69d42fa9de7b602c3885f9c7b5a64f1a0037854` |
| CPU audit execution receipt | `bff08ef62a84c2ebd950ef692989abe6c037773cb1cc2af50bf5a31acc63c14c` |
| Independent provenance audit | `e89378a2805ea35488eb631cdf494999cbf5c2379baaed058edab90d1b9cfc73` |
| Root postflight | `6922a449531644b44510c73ea227cf4ca8b76de7ffc56bee4c8f671edac4338c` |
| Frozen CPU helper | `e316c559f2827c539bd25f0c6baed226e21bc704df3e4facf0d889605914abd1` |
| CPU test receipt, 51 passed | `040d67f4bff6bdde62c10c5385b7e38d00f9a882382f8febbf06fe006f9c7bed` |

No timer or throughput measurement was requested. Neither wall-clock launcher
runtime nor resource-sample timestamps are used as inference TPS. This result
qualifies no distributed comparison, physical Thunderbolt/RDMA transfer,
decode continuation, 27B model execution or M3 Ultra performance. See the
[inference experiments](README.md) and
[distributed inference goal](../../../docs/design/distributed-inference-goal.md).
