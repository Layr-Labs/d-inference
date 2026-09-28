# Qwen9B resident solo and two-Mac comparison

> Last updated: 2026-09-15 · commit `605651bb9`

For the matched 8K-prompt, 128-output-token workload, balanced distributed
Qwen3.5 9B reaches 814.42 effective prompt tokens/s against an optimized resident
solo control at 439.85: a 1.85× improvement. Distributed decode is slower,
24.68 versus 37.68 tokens/s. This report records the comparison and its limits.

## Workload and boundaries

The solo host is the 48 GB M4 Pro. The distributed hosts are the 24 GB and
48 GB M4 Pro Macs; both have 14 CPU and 20 GPU cores, with macOS 27.0 build
26A428. Distributed execution uses the previously qualified Thunderbolt/RDMA
path with 16/16 layers and one chunk of prefill lookahead.

Both cohorts use the same registered 4-bit artifact, all 8,192 prompt IDs,
512-token chunks, greedy generation, an empty stop-token set and 128 output
tokens. MTP and prefix reuse are off. Each loads once, excludes one warmup and
measures three requests with fresh state. All eight request outputs match the
same 128 expected token IDs. These are the internal diagnostic prompt, not the
different source-text prompt used in the HTTP observation.

Effective prompt rate is 8,192 divided by request-start-to-first-token time.
Decode rate is 127 divided by first-to-last-token time. Solo timing starts
after source/resource admission and before fresh state construction, and
includes finite argmax and per-forward ownership validation. Distributed timing
starts at the controller's start call after reservation and additionally
includes control/transport. Both exclude model loading. No cross-machine clocks
are subtracted, and neither measure is external HTTP TTFT or pure kernel time.

## Measured results

| Configuration | Median internal first token | Effective prompt tokens/s | Decode tokens/s |
|---|---:|---:|---:|
| Optimized solo, 48 GB | 18.624509 s | 439.850526 | 37.679017 |
| Distributed, 16/16 layers | 10.058654 s | 814.423069 | 24.682603 |

Balanced distributed execution increases effective prompt rate by 85.16% and
reduces internal first-token latency by 45.99%. Its decode rate is 34.49% lower.
The comparison supports the prefill-first direction while identifying decode
as a separate optimization target; it does not establish why each part of the
decode overhead occurs.

| Measured request | Solo first token | Distributed first token |
|---|---:|---:|
| 1 | 18.624508833 s | 10.057397291 s |
| 2 | 18.607915875 s | 10.061356750 s |
| 3 | 18.625035166 s | 10.058654167 s |

The excluded solo warmup takes 20.398079 seconds to first token. Its actual
dispatch observation records 24 fused projection modules, 384 native GDN
prefill calls, 3,048 native decode calls and zero operations fallbacks or
invalid geometries. The observer is removed before measured requests. Query
block size 128 is configured but not independently counted at dispatch. This
confirms these optimizations are active, not that all possible solo policies
have been searched.

## Correctness and cleanup

The solo native report records all four request states retired and the one
loaded model released. Every request completes 143 forwards at committed
frontier 8,319. Full vocabulary rows and state snapshots are not collected in
this timing path. The separate distributed final-logit and complete-state
comparison is recorded in the [balanced qualification report](2026-09-15-cluster-balanced-prefill-http.md).

The solo process exits zero with complete EOF and empty stderr. Its parent
reaps the native process, finishes owned-group cleanup and rechecks pinned
inputs. Collection verifies nine output files and independently observes no
native process and an empty canonical lease journal. The parent completes in
96.542 seconds; the outer SSH operation completes in 97.028 seconds. Those
whole-run durations are not inference throughput measurements.

Independent replay validates all 358 retained parent resource samples from raw
macOS output. Minimum actual free memory is 24,679,743,488 bytes; AC power,
zero swap and normal pressure hold throughout. Native code separately reports
7,009 observations and a 25,127,911,424-byte minimum; those individual native
snapshots are not independently replayed. Neither sampling stream establishes
a continuous whole-process memory peak. No compiler, transfer or competing
remote operation overlaps the timed cohort.

The distributed timing sidecars have now also been collected separately:
16 files across both prior cohorts, with exact request, stage, Plan, storage,
token and schedule joins. This follow-up adds no new numerical comparison or
timing measurement and leaves the original records unchanged.

## Reproduction and scope

Evidence resides under `/Users/developer/DarkbloomDev/cluster-research/`:

- `qwen9b-resident-solo-generation-build-20260915`: build, argument checks and
  the matched three-file native/resource bundle.
- `qwen9b-resident-solo-supervisor-draft-20260915`: strict four-request result
  validation and ten Python checks, including five actual child processes.
- `qwen9b-resident-solo-physical-20260915/run-1`: deployment, actual execution,
  exact returned bytes and `root-comparison-review.json`, which independently
  replays both cohorts' raw timestamps/tokens and the solo resource records.
- `qwen9b-balanced-timing-sidecars-20260915`: the subsequent identity and
  schedule joins for all eight distributed timing requests.

Solo native SHA-256 is
`8952b0f260502b06f7dbe7eb9e0cbef1b41564001570ad52a3c2739a247252d3`.
The final comparison review is
`c21a76730e4208ad412c5f31e3458329b21e6e06767c91577336d57c6f3c2c1a`.
Build checks preserve all 3,290 source and 9,502 dependency file pins; the native
minimum deployment target is macOS 26.2. The installed Provider/default
configuration is unchanged by the private solo run.

One prompt and three measured requests do not establish latency percentiles,
representative external SLA compliance, long-running service or general
scaling. The separate 10.503-second HTTP observation remains as reported in
the [balanced report](2026-09-15-cluster-balanced-prefill-http.md). Qwen27B,
Gemma, actual MTP off/on comparisons and M3 Ultra projections remain work under
the [delivery plan](../design/distributed-cluster-delivery.md). This 9B result
does not establish the 27B throughput target on M3 Ultra.
