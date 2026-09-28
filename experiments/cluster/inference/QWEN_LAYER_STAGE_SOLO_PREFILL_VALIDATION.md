# Registered Qwen solo prefill validation

> Last updated: 2026-09-14 · commit `e4df336bc`

The matched-chunk full-model control passed one registered Qwen3.5-9B request
on a 24 GiB M4 Pro. Its selected token and final state/logit metadata and digests
matched the independently audited reference. The recorded 242.524834 ms
first-token interval is a single diagnostic observation, not a qualified
throughput result or a paired comparison with the earlier stage study.

## Executed workload

The [solo reference contract](QWEN_LAYER_STAGE_SOLO_PREFILL.md) uses the production
CBv2 model adapter through the experiment's `CBv2RequestSession`, with fresh state
and matched prompt chunks. A private guarded launcher ran this check; there is no public solo
launcher. The existing public `prefill-ranks` command does not launch this mode.

| Property | Executed value |
|---|---|
| Host | One M4 Pro, Mac16,7, 14 CPU cores, 24 GiB |
| Operating system | macOS 26.6.2, build 25G83 |
| Native layout | One unpartitioned 32-layer model; no interprocess model transport |
| Registered artifact aggregate | `127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b` |
| Input and schedule | Same saved natural-text prefix: 65 token IDs, chunks 32/32/1 |
| Output | One selected token; no teacher tokens or decode forward |
| Execution | Native `cbv2-contiguous`, BF16 activation/conversion policy, MTP disabled |
| Repetitions | One fresh native process, one request, zero warmups |
| Completion | Native exit 0; two JSONL records; empty stderr |

The candidate loaded the full verified artifact and a CPU-only final reference.
It did not execute an additional baseline model forward in this run. The
reference producer separately validated the retained baseline evidence before
exporting the descriptor; its trust requirements remain part of the
[reference contract](QWEN_LAYER_STAGE_SOLO_PREFILL.md#guarded-inputs-and-reference-trust).

## Independent correctness result

The unchanged CPU oracle passed 54 prospective fixture/mutation tests before
reading this candidate. Its actual replay validated the reference export,
request/source identities, three ordered commits, final component coverage,
selection record and clock arithmetic.

| Check | Result |
|---|---|
| Prompt commits | Exactly three; frontiers 32, 64, 65 |
| Output narrowing | First two chunks return `[1,1]` evaluation handles; final chunk returns `[1,248320]` logits |
| Final state | All 72 component metadata/digest entries agree; 53,641,248 logical bytes |
| Final state SHA-256 | `5ae9b873bfaadec86d79dbec8785cccd1136029964c34e4c576773a74d48292a` |
| Final logits | BF16 `[1,248320]`; 496,640 logical bytes |
| Final logit SHA-256 | `55c93eed36f83fd53404c045b949fd20a5e5cd55d0a6fedee4738d61fc65422c` |
| Selected token | 2526; reference maximum 18.875 with one maximum |
| Capture placement | No per-frame state/logit captures; one final state and one final logit capture after stop |

The candidate exports metadata and SHA-256, not raw logit values or state
arrays. Only the separately recorded baseline row was independently
reconstructed. `nativeLogitBytesCompared=false` remains explicit: this result
establishes digest agreement with the pinned reference, not an independent
byte-by-byte comparison of two exported candidate/reference arrays. The tie
count is a reference annotation; the candidate did not compute a new tie count.
Native selection, commits, capture placement, request retirement and model
release are validated records tied to the inspected source, not independent
profiler observations or model-quality qualification.

## First diagnostic interval

| Field | Recorded value |
|---|---:|
| Start-to-selected-token interval | 242,524,834 ns (0.242524834 s) |
| Derived prompt tokens per first-token second | 268.01379029085325 |
| Post-stop through request close | 21,812,875 ns (0.021812875 s) |

The clock starts immediately before fresh request-state construction and stops
after all prompt forwards/commits, final norm/head, uncast native argmax,
all-logits-finite evaluation and scalar token readback. Bounded commit metadata
is included. Verified loading, input/reference preparation and readiness happen
before start; final state/logit captures, comparison and request retirement
happen after stop. The post-stop field ends at request close and excludes later
model release, cache clearing and report output. See
[QwenLayerStageSoloPrefillRequest.swift](Sources/ClusterInference/QwenLayerStageSoloPrefillRequest.swift)
(`runQwenLayerStageSoloPrefillRequest`).

This uses the corresponding fresh-state-to-token interval and chunk schedule
of the stage paths, with no artificial transport or ACK work added to solo.
It is not a pure prefill-kernel timer or a demonstrated fastest eligible solo
configuration. The [14-cohort stage diagnostic](QWEN_LAYER_STAGE_PREFILL_TIMING_DIAGNOSTIC.md)
used a different executable and had no timed solo control. This later single
point was outside that study's trial order and cannot be inserted as a matched
solo arm or used to infer a speedup. Fresh processes do not establish equivalent
driver/kernel-cache state or warmed resident serving. The native report retains
`throughputMeasurementValid=false`.

## Resource and process evidence

The guarded launcher passed 36 CPU/fake tests before execution. It used a new
owned directory, a pinned native/runtime bundle, exact input/reference pins,
remote full-artifact verification before and after, and a 180-second deadline.
No model checkpoint was copied. Initial actual-free memory was 7,780,712,448
bytes before remote bundle staging/model hashing, passing the 6 GiB screen.
The later post-hash sample reported 7,528,693,760 actual-free bytes and
16,244,080,640 estimated reclaimable bytes, passing the separate 8 GiB
reclaimable screen. The initial reading does not guarantee free memory at launch.
All eight saved memory samples and the root postflight reported pressure level 1
and zero swap.

The native MLX peak since process start was 5,281,957,248 bytes. After model
release/cache clearing, active MLX bytes were 4,016 with zero cache. These are
MLX allocator observations, not RSS or whole-process memory. The largest of
three sampled native RSS observations was only 45,760,512 bytes; these sparse
observations do not characterize the loaded/inference footprint or establish a
memory peak. Missing observations are not treated as zero.

The local SSH client was reaped. Both the final pinned control and a separate
root postflight observed no processes matching the owned remote paths.
Independent remote `waitpid`/reaping proof is not asserted. The provenance
replay verifies saved resource arithmetic and control-call order without
assuming that monotonic epochs from separate remote Python processes coincide.

## Retained identities and scope

The run used executable SHA-256
`9195a464d9d30784e7becc2c20c487847ef865696abc2d7de1c06ff18c75aaa5`.
The private archive retains 232 source files, dependency identities, the native
bundle, exact rank arguments, inputs, controls, remote model metadata and
stdout/stderr. The provenance audit passed separately from the numerical
oracle; it does not reproduce the build or independently re-read remote model
payloads.

| Evidence | SHA-256 |
|---|---|
| Launcher receipt | `e1081799689c20aed672c0f6dda5b0cbf5edee5ca8f750d72cd8a4da4aa3ef43` |
| Independent correctness audit | `0d74817cd8468839c75557abbcd6bc836f392a2d86cd48219ec42b60ebb623d3` |
| Independent provenance audit | `c703ef8f3d4b083518f4ef96ecec39ba0a70d084af22385e40c3a33321e6e0cd` |
| Root postflight | `d8cbb94c76ef81db21a2e5cc4051222e95595a3499af04e3d08f35f3c41b2fcf` |
| Original reference, 14,418 bytes | `782138cb276748af1b4a8d9f2d5d76461ae9973a5919e4f4317035c551b2976b` |
| Worker-staged reference, 15,528 bytes | `8a61a536778b1988196ec3621c83210859055c414d2c29b5d8abcf80933eb22a` |

The two reference encodings contain the same descriptor. The parent pins the
original bytes separately, then passes the exact worker-serialized file hash
to native admission. The independent audits verified both encodings and the
retrieved remote file; a descriptor-file hash alone is not proof of an honest
baseline producer. Addresses, credentials and private archive paths are omitted.

This check qualifies neither physical Thunderbolt/RDMA transfer nor two-machine
acceleration, 8K prompts, decode continuation, the target 27B model or M3 Ultra
execution. It adds a bounded solo control for subsequent same-binary, matched
experiments. Related: [inference checks](README.md),
[distributed goal](../../../docs/design/distributed-inference-goal.md).
