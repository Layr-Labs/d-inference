# Gemma decode improvements — 2026-09-20

The measured two-Mac Gemma decode rate improved from **22.212 to 32.010 tokens/s (44.1%)**. Prefill is 454.477 tokens/s versus 452.192 originally. Both optimizations preserve exact generated tokens, complete final logits and KV state bytes.

These are the existing M4 Pro Macs (14 CPU / 20 GPU cores, 24 GB + 48 GB), Gemma 4 26B 4-bit, BF16 residuals, P4096/C64/O16, layers 7/23, greedy generation, MTP off and plaintext lab RDMA. Each arm has one excluded warmup and three measured fresh requests. Decode counts 15 continuation tokens per request, 45 measured per role. Rates are measured tokens divided by total native duration; pair values use the lower rank. Loading and external HTTP latency are outside these timings.

| Implementation | Pair decode TPS | Pair prefill TPS | Matched solo decode TPS |
|---|---:|---:|---:|
| Original | 22.212 | 452.192 | 44.866 |
| Reuse timestamp formatter | 28.545 | 459.769 | 47.770 |
| Also combine control prefix and body | 32.010 | 454.477 | 47.068 |

The final framing cohort is -1.15% below the timestamp-only cohort in prefill and 0.51% above the original. These short, fixed-prompt cohorts do not establish a workload-wide latency distribution. Solo remains faster for a single decode stream: the latest matched solo is 47.068 TPS.

## What changed

The resource reader previously constructed a fresh ISO8601 formatter at every observation. The new helper reuses only the formatter, with all mutable access inside a private lock. The wall-clock value and every OS, allocator, power, thermal and deadline observation remain fresh. Every global and per-request guard count and budget matched the original exactly in the first hardware comparison. The helper, one call site and the byte-identical CPU fixture are now in the main development checkout; see [integration receipt](main-integration/receipt.json). Qwen uses that shared reader, but no new Qwen TPS result is claimed.

Each Gemma control previously sent its length and JSON body as two completed transfers. A reusable bounded envelope now carries both in one 16-KiB record. It rejects invalid lengths and nonzero padding, then uses the unchanged strict JSON, scope, rank, ordinal and acknowledgement validation. The five controls plus one residual now take six completed transfers per decode token instead of eleven. Completion fences, ownership validation, fault checks and resource checks around every remaining transfer remain. The stage budget adds 32,767 bytes of actual native allocation bound for the 16,384-byte frame plus 32,768 host bytes. Existing reserves and 6/4/2-GiB requirements were not reduced. This framing change is qualified in the private cluster runtime; product and other-model integration remain.

## Verification

- Timestamp helper: Swift 6 build, 13 date cases, 4,096 concurrent comparisons. Formatting-only local microbenchmark fell from about 41 microseconds to 0.7 microseconds per call; this is separate from measured model speed.
- Framing: 18 Foundation controls covering payload limits, truncation, complete padding checks and the existing DTO; 16 independent comparison-policy controls. Timestamp comparison has 10 policy controls.
- Each new pair exactly matches its new solo across all four output sequences, four complete final logit rows and 360 combined KV components, including warmup. The final cohort also matches each earlier same-role cohort across eight rows and 720 state components per baseline (2,351,268,800 state bytes per baseline).
- All phase/global counts match the explicit source change, including all startup probes and lifecycle checkpoints. Pair decode guards fall from 105/103 to 65/63 per token because five prefix operations disappeared; freshness policy is unchanged. Every complete four-request stage removes exactly 1,108 prefix transfers and 8,864 logical guard invocations.
- Both physical parents and native groups retired, canonical leases stayed empty with the same identity, and the temporary Thunderbolt alias was restored. AC, pressure level 1, zero swap and actual-free/resource requirements passed. No native job is left running.

The retained same-process profiles show logical guard time fell from about 17.1–17.3 to 5.5–5.9 ms per pair token. These intervals overlap owner and transport measurements. The remaining wire interval includes peer computation and synchronization; it is not isolated network latency.

## Evidence and next work

[Original profile](profile/REPORT.md), [timestamp comparison](review/actual-timestamp-1/REPORT.md), [final comparison and phase profile](review-padded/actual-padded-1/REPORT.md). The final machine-readable receipt is [comparison.json](review-padded/actual-padded-1/comparison.json), SHA-256 `0d7a84f40302cf9c1dd82b7ed51781539d77e25677930944d173ab081293382d`. Native identities are original `6115f51d…`, timestamp `84cbea53…`, and final `d7859728…`. Builds and both deployments are retained under `build`, `harness` and `harness-v2`.

Next decode work is longer generation and prompt coverage, matched Qwen remeasurement with the shared optimization, and resident MTP-on/off timing. A measured prefill-to-decode placement decision can address the remaining serial stage dependency when one member can hold the full model and imported state. This remains to be implemented and measured. Encrypted admitted inference, full-model EP speed, true TP numerical qualification and release integration remain part of the wider delivery goal.
