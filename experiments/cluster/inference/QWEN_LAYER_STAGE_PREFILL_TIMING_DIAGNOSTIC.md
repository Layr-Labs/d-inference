# Qwen prefill timing diagnostic with fresh process cohorts

> Last updated: 2026-09-14 · commit `e4df336bc`

A prospectively ordered 14-cohort diagnostic completed on one 24 GiB M4 Pro.
All cohorts passed their saved correctness, provenance and cleanup checks.
The measured median first-token intervals were **259.701 ms for serial** and
**229.299 ms for lookahead** on one fixed 65-token prompt. These are descriptive
observations; they do not establish a causal scheduling speedup or qualified
cluster throughput.

## Executed design

This is a separate experiment from the [two-run pilot](QWEN_LAYER_STAGE_PREFILL_RANK_VALIDATION.md).
Its plan and order were frozen before execution. The native binary, private
guarded launcher and independent validators remained unchanged throughout.
The first two cohorts primed A then B and were excluded from the measured sample
by design. The remaining twelve cohorts formed six pairs: AB, BA, BA, AB, AB, BA.
All fourteen observations are retained; none was trimmed, replaced or retried.

| Property | Executed value |
|---|---|
| Host | One M4 Pro, Mac16,7, 24 GiB; macOS 26.6.2 build 25G83 |
| Model | Registered Qwen3.5-9B, same verified artifact as the pilot |
| Process layout | Two fresh native processes per cohort, both on this one GPU |
| State and execution | Fresh request state; native BF16, `cbv2-contiguous`, MTP off |
| Workload | Identical 65 prompt IDs; chunks 32/32/1; one output; no teacher/decode forward |
| A | `serial_v1` |
| B | `prompt_lookahead_one_v1` |
| Native per-cohort options | One repetition, zero warmups; 180-second active-cohort deadline |
| Between launches | No added delay; the same staging, hashing and admission procedure |
| Native completion | 14 cohorts, 28 rank exits of zero; fresh epoch for each cohort |

Each cohort reloaded verified stage weights and constructed new request state.
Priming was performed by separate complete process cohorts, not by extra
requests on resident weights. Fresh processes do not establish identical or
cold Metal driver, kernel, filesystem or host cache state. The archive name
contains “cold”; that name is not a measured cache-state classification.
The earlier pilot's two intervals were not added to this sample.

## Interval and correctness gates

The unchanged [v3 protocol](QWEN_LAYER_STAGE_PREFILL_RANK_PROTOCOL.md) defines the
interval. Rank zero starts immediately before start-send and stops after the
final consumed ACK and returned selected token are validated. This includes
fresh state, all prompt chunks, native compute/evaluation/commit, residual
checks/copies/fences, bounded bookkeeping, final norm/head and token selection.
It excludes model loading, input preparation and readiness, then excludes
post-stop release, final diagnostics and retirement. Exact UInt64 nanoseconds
are retained; no cross-rank clock subtraction is used.

[QwenLayerStagePrefillRankRequest.swift](Sources/ClusterInference/QwenLayerStagePrefillRankRequest.swift)
(`runQwenLayerStagePrefillRankRequest`) owns those clock reads and the post-stop
order; [QwenLayerStagePrefillRankResult.swift](Sources/ClusterInference/QwenLayerStagePrefillRankResult.swift)
(`QwenLayerStagePrefillRankTiming`) defines the report. The interval is not
pure kernel time or warmed resident-serving latency.

All 14 independent comparisons passed the complete final state metadata/digest
union, final native-logit digest against the reconstructed reference row,
selected token 2526, exact envelope/token bindings, host action order and clock
arithmetic. Candidates export final state/logit metadata and hashes, not raw
candidate arrays or full logit values; the corresponding [evidence limits](QWEN_LAYER_STAGE_PREFILL_RANK_VALIDATION.md)
remain unchanged. Source-reported completed phases are not a GPU-overlap trace.

The unchanged resource screens required initial actual-free memory before
hashing, post-hash reclaimable headroom, pressure at most two and no additional
reported swap. All 105 saved memory observations reported pressure one and zero
swap. Every postflight found no owned remote processes; local SSH clients were
reaped. Absence in a remote process inventory is not a separate remote reaping
proof. No cohort remained live when the next one began.

## Every observed interval

A is serial and B is lookahead. Milliseconds are rounded only for display;
integer nanoseconds are the recorded observations.

| Trial | Role | Pair | Policy | Elapsed ns | Elapsed ms |
|---:|---|---:|---|---:|---:|
| 1 | priming | — | A | 259,606,958 | 259.607 |
| 2 | priming | — | B | 229,258,333 | 229.258 |
| 3 | measured | 1 | A | 259,733,542 | 259.734 |
| 4 | measured | 1 | B | 235,319,500 | 235.320 |
| 5 | measured | 2 | B | 227,027,834 | 227.028 |
| 6 | measured | 2 | A | 259,668,125 | 259.668 |
| 7 | measured | 3 | B | 226,171,250 | 226.171 |
| 8 | measured | 3 | A | 254,302,208 | 254.302 |
| 9 | measured | 4 | A | 261,627,875 | 261.628 |
| 10 | measured | 4 | B | 232,177,375 | 232.177 |
| 11 | measured | 5 | A | 259,738,625 | 259.739 |
| 12 | measured | 5 | B | 226,101,667 | 226.102 |
| 13 | measured | 6 | B | 231,570,375 | 231.570 |
| 14 | measured | 6 | A | 258,227,334 | 258.227 |

## Six measured pairs

Each ratio divides that pair's serial duration by its lookahead duration. It is
a descriptive latency ratio, not a causal acceleration estimate.

| Pair | Order | Serial ms | Lookahead ms | Serial − lookahead ms | Serial / lookahead |
|---:|---|---:|---:|---:|---:|
| 1 | AB | 259.734 | 235.320 | 24.414 | 1.1037 |
| 2 | BA | 259.668 | 227.028 | 32.640 | 1.1438 |
| 3 | BA | 254.302 | 226.171 | 28.131 | 1.1244 |
| 4 | AB | 261.628 | 232.177 | 29.451 | 1.1268 |
| 5 | AB | 259.739 | 226.102 | 33.637 | 1.1488 |
| 6 | BA | 258.227 | 231.570 | 26.657 | 1.1151 |

| Summary | Serial | Lookahead |
|---|---:|---:|
| Measured cohorts | 6 | 6 |
| Median ms | 259.701 | 229.299 |
| Minimum–maximum ms | 254.302–261.628 | 226.102–235.320 |

The median of the six paired ratios is **1.1256**, with range **1.1037–1.1488**.
The three AB pairs have median ratio **1.1268**; the three BA pairs have median
**1.1244**. No significance test, percentile estimate or adaptive stopping was
performed. The two priming observations are visible above and excluded only
because the prospective plan specified that exclusion.

## Interpretation and limits

These observations narrow the follow-up question to reproducible timing under
matched process/cache conditions. They do not isolate driver/cache effects,
prove simultaneous GPU work or measure a scheduling effect independently of
those conditions. Both ranks shared one GPU. There was no timed solo control,
no resident-weight repeated-request cohort, and no long-prompt or generated
decode workload in this study. Six pairs from one prompt cannot qualify model
quality, production serving, physical TB/RDMA transfer, two-M3-Ultra scaling or
the 27B prefill target. All throughput and resident-warmth qualification flags
remain false.

The native runs used the frozen private guarded launcher. The later optional
[public `prefill-ranks` command](../runtime/stage_checks/README.md) has CPU/fake
and saved-schema compatibility coverage; this study does not count as native
execution of that public entry. Its numerical/action/wire/timing audit remains
a separate step. The historical pilot record is preserved without revision.

## Frozen evidence identities

The private archive is named `qwen-prefill-cold-cohort-study-20260914`. It retains
the prospective plan, all fourteen launch/provenance/comparison/postflight
receipts, raw rank output and the descriptive analysis. Each study row binds
its individual receipts; the analysis preserves that complete chronological
row list. These records are external evidence, not files distributed in Git.

| Evidence | SHA-256 |
|---|---|
| Prospective plan | `5c139f3cac933564717cef67e32256d12010a91ae14c5c2f195fe63bf46af107` |
| Completed study receipt | `f29f4d2d73dac1309338b966f94ee1a6a603f18d74f1a9e180bea97d9b5c0cab` |
| Descriptive analysis | `8d71a4d334fcc744650eab54d1894a1a8e132202b7c60ed88231f743e1879866` |
| Native executable | `9341ca3b3dc5190ffa6759cfd045300a29422a0094710c13b88dcc39afe8ca16` |

The native record is bound to commit `e4df336bc` plus its frozen dirty-source
snapshot and dependency identities, not to the commit alone. The descriptive
analysis is tied to the completed study receipt; neither substitutes for its
per-cohort evidence or expands the study's admitted workload.
