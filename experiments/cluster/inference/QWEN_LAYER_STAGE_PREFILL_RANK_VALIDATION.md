# Qwen stage prefill across two loopback ranks

> Last updated: 2026-09-14 · commit `e4df336bc`

Both v3 prefill schedules passed the registered Qwen3.5-9B check on one M4 Pro
with 24 GiB of memory. Two native processes exchanged real residuals, completed
the first-token protocol, and matched the independently recorded final state,
logit digest and selected token. These first single-shot runs qualify bounded
correctness; their diagnostic timings do not establish a scheduling speedup.

## Executed workload

The [v3 protocol](QWEN_LAYER_STAGE_PREFILL_RANK_PROTOCOL.md) runs one verified
whole-layer stage per process. The policies share the same wire and computation;
lookahead can prepare one next prompt chunk while the previous consumed ACK
is outstanding. Both use fresh request state after a validated start and return
the actual selected token before rank zero stops its clock.

| Property | Executed value |
|---|---|
| Host | M4 Pro, 14 CPU cores, 20 GPU cores, 24 GiB; Mac16,7 |
| Operating system | macOS 26.6.2, build 25G83 |
| Process/transport layout | Two processes on this one host; `loopback-test`, ring backend |
| Registered artifact aggregate | `127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b` |
| Input | Same saved natural-text prefix, 65 token IDs |
| Schedule | Chunk 32; committed frontiers 32, 64, 65 |
| Output | One selected token; no teachers or decode forward |
| Native execution | `cbv2-contiguous`, BF16, MTP disabled |
| Policies, in execution order | `serial_v1`, then `prompt_lookahead_one_v1` |
| Repetitions | One fresh process cohort per policy, zero warmups |
| Completion | Both native ranks exited 0 in each run; two JSONL records per rank |

Model loading, token preparation and readiness precede the measured interval.
The clock includes fresh state, start IO, all prompt frames, native selection
and validated token return, with existing checks/copies/fences and bounded trace
bookkeeping. Final captures and request/model retirement follow the stop. This
is not a pure kernel timer or a warmed resident-serving benchmark.

## Independent correctness result

The CPU oracle was frozen before reading either candidate run and passed 49
prospective fixture/mutation tests. The unchanged oracle passed both actual
runs against the [one-process prefill reference](QWEN_LAYER_STAGE_PREFILL_VALIDATION.md).

| Check | Both schedules |
|---|---|
| Host trace | Exactly 46 sender and 51 receiver actions, with policy-specific order |
| Prompt frames | Three exact shared v3 envelopes and matching commits |
| Prepared work ahead | Serial: zero; lookahead: two permitted next-chunk preparations |
| Final state | Complete disjoint union of 72 metadata/digest entries; 53,641,248 logical bytes |
| Final state SHA-256 | `5ae9b873bfaadec86d79dbec8785cccd1136029964c34e4c576773a74d48292a` |
| Final logits | `[1, 248320]`, BF16; 496,640 logical bytes |
| Final logit SHA-256 | `55c93eed36f83fd53404c045b949fd20a5e5cd55d0a6fedee4738d61fc65422c` |
| First token | 2526; reference unique maximum 18.875 |
| Token return | Exact packet bytes bind the agreement, final envelope and actual selection |
| Clock arithmetic | Exact UInt64 subtraction and finite derived rate pass |

Candidates export logit metadata/SHA, not full logit values. Unlike the
one-process comparator, this rank mode makes no private native-byte comparison
with a resident baseline; the independent check establishes digest agreement
against reconstructed reference bytes. State evidence likewise contains
component metadata/digests, not raw arrays. ACK hashes are independently derived
expectations bound to reported phase events; actual ACK bytes are not exported.
Native execution, wrapper release, clock placement and retirement remain
source-bound assertions, rather than independently observed profiler events.

## First diagnostic timings

| Policy | First-token interval | Derived prompt tokens/s | Post-stop through rank-zero request close |
|---|---:|---:|---:|
| Serial, executed first | 3.726663625 s | 17.441875 | 0.011324000 s |
| Lookahead, executed second | 0.228014625 s | 285.069434 | 0.011243292 s |

The large gap is confounded by run order and unqualified initialization,
driver/kernel cache and system-state effects. Two cold process cohorts do not
ensure equivalent cache state. No warmup, repeated pairing, reversed order or
same-interval solo baseline was performed in these runs. These values cannot
support a causal scheduling gain, a resident throughput estimate or an M3 Ultra
projection. The native reports retain `throughputMeasurementValid=false`.

## Resources and retained evidence

The frozen launcher passed 22 CPU failure tests before execution. Each run used
a fresh private epoch directory, a pinned executable/runtime bundle, verified
remote model bytes before and after, a 180-second cohort deadline and the same
resource gates. No model checkpoint files were copied or staged. Initial actual-free readings were
6,850,379,776 bytes for serial and 7,732,248,576 for lookahead, before bundle
staging/model hashing. Those readings do not promise equal free memory at launch.

All ten serial and seven lookahead resource samples reported pressure level 1
and zero swap. In both runs, the per-process MLX peaks were 2,700,848,602 and
2,701,118,800 bytes; after model release/cache clearing, the respective active
counts were 2,016 and 2,008 bytes, with zero cache. MLX accounting is not RSS.

Serial's largest simultaneous sampled native-only RSS sum was 6,360,809,472
bytes. Lookahead's three simultaneous observations reached a maximum of
157,843,456 bytes. These sparse samples never captured a footprint comparable
to loaded weights and cannot characterize inference memory or establish a
smaller footprint. Missing samples are not zero or peaks.
The local SSH clients were reaped. Saved postflights found no owned remote
processes; independently observed remote reaping is not asserted.

| Evidence SHA-256 | Serial | Lookahead |
|---|---|---|
| Launcher receipt | `13bc7992f5f10a5eaaa475da33b9503d1c3e50bc10af6436da595098ff827385` | `8b731727963d2358c810de4fdc27caf826a1a95b2e276d1ece7157bfea3ba522` |
| Independent correctness audit | `b2852cff2f3e0716d593e9afba26715d889d79deb1332b4904052402761ae862` | `b32bc4de6f7179118b9f8ba9b3f4a09135a921961141a881436e35dd8b5f7a15` |
| Independent provenance audit | `1a43c6696e00ac0293fe8ff946f62b3b7d632680f680ff777face93c1f41f259` | `b2b621413995bee7a5dee542f0ad74efacc8886eb1e9d4245d408f654311b78c` |
| Root postflight | `640cab6e437424ae1b73d51851cb246cd5ce1c3f77b0e22eb008254405d6da6e` | `654a7ee450882d04327ea53e162d97426fb23307aa77ef8b361b31ee1156b4ce` |

Both ran executable SHA-256
`9341ca3b3dc5190ffa6759cfd045300a29422a0094710c13b88dcc39afe8ca16`.
Each private archive retains 219 source files, dependency identities, native
stdout/stderr, input history, exact rank configurations, runtime bundle,
controls, remote model metadata and resource observations. The CPU provenance
audit recomputes archive hashes and resource arithmetic; it does not reproduce
the build or re-read remote model payloads. Credentials, addresses and private
archives are excluded from the repository.

No physical Thunderbolt/RDMA transfer, two-machine acceleration, long prompt,
decode continuation, target 27B model or M3 Ultra execution is qualified here.
Related: [isolated probe](README.md), [distributed goal](../../../docs/design/distributed-inference-goal.md).
