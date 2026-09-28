# Qwen27B prefill phase measurements

> Last updated: 2026-09-17 · commit `605651bb9`

Two diagnostic requests on the 24 GB and 48 GB M4 Pro Macs show that chunk
overlap reduces internal request-to-first-token agreement from 67.5 to 49.8
seconds. The 48 GB Mac's 48-layer stage spends 48.6 seconds consuming the
prompt, making its computation the principal measured bottleneck. Both requests
preserve all 128 expected greedy output IDs and complete bilateral cleanup.

The registered Qwen3.8 27B four-bit artifact uses a 16/48 whole-layer split,
8,192 input tokens, 512-token chunks, 128 output tokens, no stop conditions and
MTP off. One request runs serially and one permits a single chunk of lookahead.
These are local monotonic wall-clock intervals, including recorder and runtime
overhead. They exclude loading and admission; they are neither GPU kernel
timings nor externally measured HTTP TTFT. No cross-machine clock subtraction
is used.

| Local interval, seconds | Serial | One-chunk lookahead |
|---|---:|---:|
| Rank 0 request to first-token agreement | 67.517992 | 49.785775 |
| Rank 1 request to first-token agreement | 67.544873 | 49.801864 |
| Rank 0 prompt preparation, summed | 17.298422 | 16.525324 |
| Rank 1 prompt consumption, summed | 49.728140 | 48.615481 |
| Rank 1 waiting for frame headers, summed | 17.357328 | 1.112699 |
| Rank 0 request through retirement | 79.951901 | 62.117866 |

Overlap removes most of the consumer's wait for prompt chunks. The remaining
consumer computation limits this split. Moving layers to the smaller Mac is a
candidate optimization, but its memory margin needs actual qualification.
Fresh cache purges provide 13.70–13.84 GB of actual free memory there; the
existing conservative 32/32 weight-plus-8K-request requirement is 14.67 GB.
Passing the initial weight-load threshold alone would not prove request fit.
An intermediate 24/40 split is a subsequent candidate, with no performance or
memory-fit result in this report.

| Resource observation | Serial | One-chunk lookahead |
|---|---:|---:|
| Minimum actual free bytes, 24 GB Mac | 6,510,379,008 | 6,627,573,760 |
| Minimum actual free bytes, 48 GB Mac | 19,084,492,800 | 19,161,956,352 |
| Raw resource samples, rank 0 / rank 1 | 334 / 337 | 269 / 271 |
| Total admitted request reservation, bytes | 5,540,781,514 | 5,551,431,113 |

Every sample retains AC power, normal pressure, zero swap and the six-GiB
actual-free floor. The fixed recorder budget is included in both readiness
reports and admission. Each request seals 143 frames at frontier 8,319, writes
its bounded sidecar synchronously, and releases the phase buffer before capacity
is reused. Each reservation is retained through retirement and then released
to zero. Native cleanup, authenticated owner lease release, natural owner exit,
complete output EOF, process absence, the same empty canonical journals and
restoration of the temporary Thunderbolt alias are all observed.

The profiler adds 16 passing Foundation groups, four schema controls and eight
comparison-join tests. Its native executable and controller are built from
recorded unchanged inputs. This experiment checks all output IDs but does not
repeat the separate full-logit-row and state comparison. It is one diagnostic
request per policy, without a throughput cohort, percentile, encrypted-RDMA
overhead or external SLA qualification. The earlier
[matched 27B timing](2026-09-16-cluster-delivery-progress.md) retains its own
measurement scope; the [lookahead correctness report](2026-09-16-cluster-qwen27b-lookahead-correctness.md)
retains the full-row and state evidence.

Evidence is retained under `/Users/developer/DarkbloomDev/cluster-research/`:

| Evidence | SHA-256 |
|---|---|
| `resident-generation-phase-root-review-20260916/actual-phase-summary.json` | `165e534c11bf7f3200cc8eae24663236d352d97be4b53dfd15e69852f9a0b49a` |
| `resident-generation-phase-root-review-20260916/serial/phase-comparison.json` | `f0b4520d06febe086aa8f8a483a6202892c04c299468e8d0c05466b483bc49cc` |
| `resident-generation-phase-root-review-20260916/lookahead/phase-comparison.json` | `e82baab52081f012fe8c185836bee6e4b3230a0e7ee95f713920bc6691da1477` |
| Phase native executable | `649544175053810f804a662232bdfce43d5321b8fda0b3618959d94f1ad60182` |
| `qwen27b-phase-cut-memory-audit-20260916/audit.json` | `0030f15c823659df58bf0ec27903ad37829efe25aa3b9ddfbe6e79da88baca9e` |
