# Qwen3.8 retained B4 passes both backend and SSD comparisons

> Last updated: 2026-09-06 · commit `35fea6d0`

The fresh Qwen3.8 B4 triad passes the unchanged strict backend and cache comparisons. All four warm requests restore authenticated 5,120-token checkpoints, with identical same-ID outputs and no resident prefix bank. Both measured cohorts in all three arms show actual completed width-four target forwards. This is one retained B4 experiment, not full-matrix or release approval.

## Scope and provenance

The artifact remains `EigenLabs/Qwen3.8-27B-4bit-mtp`, aggregate `bbd0e0adcfe74e095073fefd0b9e116e4311d606ad9989cf81f8175e8ac18463`, with a fresh complete 14-file audit. The runtime is unchanged from the [successful B2 retest](2026-09-06-qwen38-b2-coordinated-reads.md): parent `35fea6d0e3b05ff65d60d9675ab480159913ac62`, native `f2d79145e040bbc28c6e0e355a19bc8923a70434`.

Three fresh processes run contiguous/cache-off, paged/cache-off and paged/SSD in order. Each arm has two measured four-request cohorts, with 5,523 prompt tokens per request, cap128, natural stop at74 output tokens, normal MTP, the same seven settings and production-derived grants. Existing output, authentication, memory, ownership and actual-width gates are unchanged. No B1/B2 call, lookahead column, padding or admission peak substitutes for B4 target execution.

The full 108-cell/72-edge Qwen plan and exact cell/input objects remain intact. Only the reviewed execution schedule moves this B4 triad first. The earlier B2 success is verified as a prerequisite, not copied into a new result arm. Preparation passed 53 plan and 58 driver CPU tests; independent review confirmed unchanged lease, cleanup, natural-EOS and comparison logic.

## Result and individual timing observations

Both strict comparisons pass with no errors across all eight measured same-ID output vectors per arm. Required-width and integrity validators also return no errors. All warm rows report `staged`, `hit`, and 5,120 saved tokens.

| Repeated request | Paged/cache-off TTFT | Paged/SSD TTFT | Saved tokens |
| --- | ---: | ---: | ---: |
| `long-repeat-b0` | 7.490894459s | 2.016875333s | 5,120 |
| `long-repeat-b1` | 14.934933250s | 2.652559791s | 5,120 |
| `long-repeat-b2` | 29.039251792s | 0.739167833s | 5,120 |
| `long-repeat-b3` | 22.256823291s | 1.381264209s | 5,120 |

Task admission/order within a concurrent cohort is not a fixed per-index schedule. These are individual measurements, not per-row causal speedup estimates, medians, or sustained throughput. In this pair, the warm request TTFT range is0.74–2.65s versus7.49–29.04s without caching. The output cap and natural EOS were not overridden to manufacture a longer sample.

The native processes exit zero, the foreground controller accepts the complete triad, all owned groups retire and final postflight has no known PIDs or unexpected inference workers. The previous B2 policy-miss result remains preserved separately; this run neither rewrites it nor changes its failed verdict.

## Evidence and remaining work

The [evidence manifest](evidence/qwen38-b4-coordinated-reads-2026-09-06/manifest.json) binds independent comparator/width replay, raw summaries and the compact exact-content capsule. The capsule has153 files, excludes seven cache payloads, and hashes to `33eac5d9c5857fa8a9bd64ba95a5edd1da800fbbc945cf9cab7476eddaf6fafd`. The full archive remains on the M5 test host and was independently rehashed there:2,637,722,385 bytes, SHA-256 `b39ac77013899785cb40935b39e25a17c4062214c101d5afa4b5fa3aa6046bd5`.

This does not close Qwen3.5/3.6 numerical/backend gates, repeated and sustained long-context performance, shared-admission pressure/co-residency, current-source HTTP/default-path coverage, signed persistent restart or physical two-host validation. It authorizes no production activation. The binaries remain the ad-hoc validated test runtime; old-source signing infrastructure evidence is separate.
