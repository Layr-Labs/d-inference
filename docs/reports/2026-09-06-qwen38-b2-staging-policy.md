# Qwen3.8 B2 backend parity passes; one warm SSD restore is skipped

> Last updated: 2026-09-06 · commit `56fa39501`

The three-cell Qwen3.8 B2 pilot completes, but its strict cache gate remains **failed**. Contiguous/cache-off and paged/cache-off produce identical measured outputs. The cache-on arm also matches each measured row's own cache-off output, but one repeated request falls back cold with `skipped_policy` instead of consuming an authenticated checkpoint. The other repeated request restores 5,120 tokens. No output mismatch, tolerance change, or accepted cache-performance claim is implied.

## Exact scope

The fleet artifact is `EigenLabs/Qwen3.8-27B-4bit-mtp`, aggregate `bbd0e0adcfe74e095073fefd0b9e116e4311d606ad9989cf81f8175e8ac18463`. All 14 files match the pinned manifest before execution; per-cell model/source/runtime audits are unchanged afterward. The [candidate runtime](2026-09-06-qwen-first-candidate-runtime.md) is parent `56fa3950160bb9e58d6702e9b751f2b0747ae3de`, native `f2d79145e040bbc28c6e0e355a19bc8923a70434`.

The arms run once, in order: contiguous/cache-off, paged/cache-off, paged/SSD. Each has two measured B2 cohorts and four measured rows with 5,523 prompt tokens, output cap 128, and 74 actual output tokens ending naturally. Normal MTP, the seven frozen serving settings and production-derived grants remain unchanged. Memory prefix caching is disabled and every inspected resident-bank budget is zero. All six measured cohorts satisfy the actual completed target-forward width check; queued requests or speculative columns are not substituted for B2.

## Retained results

| Comparison or row | Result |
| --- | --- |
| Strict cache-off backend comparison | Pass; all four same-ID output vectors equal |
| Cache-on measured outputs versus their own cache-off rows | All four output vectors equal |
| Strict cache integrity | Fail: `long-repeat-b0` has no authenticated restore |
| Replayed strict cache comparator | Fail: `missing_expected_long_prefix_hit` on `long-repeat-b0` |
| Forward-shape validation | No errors in any of the three reports |

| Repeated request | Paged off TTFT | SSD-arm TTFT | Stage disposition | Saved tokens |
| --- | ---: | ---: | --- | ---: |
| `long-repeat-b0` | 7.284830375 s | 7.350386834 s | `skipped_policy` | 0 |
| `long-repeat-b1` | 14.152235666 s | 7.350376792 s | `staged` | 5,120 |

The skipped stage takes 170.644792 ms; the successful stage takes 173.702292 ms. These are single ordered observations in a partially warm batch, not repeated latency or throughput evidence. Both requests preserve their 74-token output. The failed row still performs two prefill chunks, maximum 4,096; the hit performs one 403-token suffix chunk.

The reports alone do not identify which internal policy guard rejected the first stage. Source inspection identifies a concrete candidate: `SSDHybridCheckpointStore.readCheckpoint` updates file recency before full authentication, while `SSDAuthenticatedFileIdentity` rejects changes to mtime or ctime. A concurrent valid reader can therefore invalidate another reader's file snapshot without changing ciphertext. This requires a deterministic regression and a corrected-runtime replay; it is not a waiver of authentication or the missing-hit gate.

## Lifecycle and retention

All three native processes exit zero. Telemetry processes stop normally by their sampling shutdown signal. Owned wrapper/native/telemetry groups retire; the controller exits nonzero for the failed gate, with no missing post-audits and no automatic rerun. A subsequent read-only host observation finds no known or unexpected inference processes. Caller EOF and lease handling were independently tested before this run; the earlier rejected driver remains retained.

The [evidence manifest](evidence/qwen38-b2-staging-policy-2026-09-06/manifest.json) binds a 140-file compact capsule, original comparisons, independent replay summary and postflight. Seven cache payload files are excluded from the compact capsule. The complete 2,637,363,912-byte raw archive is verified separately at SHA-256 `e927b49bc1397dc2939a596796f271d66b60fedc0db4d213fe9f87d01115ef30` and is not published. Compact SHA-256: `0d8c44483aed18558d724689a5922dd23f26adabac5ef65d50bd3cc007302774`.

The next step is to reproduce and fix the staging coordination issue without weakening file authentication, TTL/restart behavior, cancellation or admission accounting, then repeat a freshly bound triad. Qwen 3.5/3.6 numerical validation, B4/sustained performance, broader lifecycle/HTTP, persistent restart and production activation remain separate open gates.
