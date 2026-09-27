# Qwen3.8 B2 passes after authenticated-read coordination

> Last updated: 2026-09-06 · commit `35fea6d0`

The fresh Qwen3.8 B2 triad passes both unchanged strict comparisons: contiguous versus paged with caching off, and paged cache-off versus SSD-enabled. Both warm rows now consume authenticated 5,120-token checkpoints and preserve their own complete output vectors. This closes the exercised missing-restore regression; it is not full-fleet or release approval.

## Source and unchanged experiment

The runtime is parent `35fea6d0e3b05ff65d60d9675ab480159913ac62`, native `f2d79145e040bbc28c6e0e355a19bc8923a70434`. The [coordination implementation and build report](2026-09-06-ssd-read-coordination-runtime.md) records the encrypted-read reproducer, path-alias review, 324 fresh test cases and source/artifact audit. No model arithmetic, sampling threshold, memory grant or oracle was changed to obtain this result.

The exact fleet target remains `EigenLabs/Qwen3.8-27B-4bit-mtp`, aggregate `bbd0e0adcfe74e095073fefd0b9e116e4311d606ad9989cf81f8175e8ac18463`. A fresh 14-file audit passes. All three arms run once on M5, with 5,523 prompt tokens, cap 128, 74 actual tokens ending naturally, normal MTP, the same seven serving settings and production grant **101,448,498,719 bytes**. Resident prefix caching stays disabled; inspected bank budgets are zero.

The controller, ownership, comparison and input contracts are unchanged from the [failed pilot](2026-09-06-qwen38-b2-staging-policy.md), apart from the reviewed source/runtime binding. All arms are fresh; no earlier result substitutes for a new control. The earlier failed archive remains unchanged.

## Results

| Gate | Result |
| --- | --- |
| Contiguous/off versus paged/off | Pass; all measured same-ID output vectors equal |
| Paged/off versus paged/SSD | Pass; all measured same-ID output vectors equal |
| Actual B2 target-forward width | Pass in all six measured cohorts |
| Required authenticated warm restores | Both repeated rows hit and save 5,120 tokens |
| Shutdown and ownership | All three native processes exit zero; no known or unexpected inference processes remain |

| Repeated row | Paged/off TTFT | SSD TTFT | Stage duration | Saved tokens |
| --- | ---: | ---: | ---: | ---: |
| `long-repeat-b0` | 7.284435541 s | 0.713489042 s | 155.160667 ms | 5,120 |
| `long-repeat-b1` | 14.156686292 s | 1.310516917 s | 309.630542 ms | 5,120 |

These are individual observations from one ordered triad, not medians, sustained throughput, or a general performance guarantee. Same-file staging queues intentionally; stage duration includes that wait. The second hit has a longer stage duration but no longer forces the batch through a full cold prefill. Each hit prefills only the 403-token suffix. Cold-row scheduling can differ within a concurrent cohort, so first-row latency is not treated as a controlled capture-overhead estimate.

All post-shutdown process owner/closing-owner counts and charged/materialized/unmaterialized bytes are zero. This is ownership retirement, not a claim that allocator cache or RSS becomes zero. Fresh postflight shows no known live PIDs or unexpected inference work.

## Evidence and limits

The [manifest](evidence/qwen38-b2-coordinated-reads-2026-09-06/manifest.json) binds independent comparator replay, the raw summary and a 143-file exact-content capsule. Seven cache payload files are excluded from the capsule. Its SHA-256 is `194cbcb211f5fec4a3ec3b9f456e7211d95e189bc40bf35a8f5492a28f7c97a1`. The complete raw archive remains on the M5 test host and was independently rehashed there: **2,637,398,462 bytes**, SHA-256 `134060b093c9b2c0ea8e6b1d13883d1f37cfa233f3dd6f12b9afc83554d5ab36`.

The source fix and deterministic encrypted-read test explain the eliminated recency/authentication race. Both file identity and authentication checks remain enforced. This experiment does not prove every concurrent-file mutation safe or replace the separate cancellation, corruption and epoch tests.

Still open: Qwen3.5/3.6 numerical/backend validation, B4 and repeated/sustained measurements, real shared-admission pressure, broader HTTP/lifecycle/two-host coverage, signed persistent restart, final publication/review and authorized activation. No production setting, service or traffic was changed.
