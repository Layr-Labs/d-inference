# Qwen3.6 dispatch metadata reuse preserves outputs with small delivery gains

> Last updated: 2026-09-06 · commit `9ec095e7d`

All twelve matched runtime cells pass execution and integrity checks. With MTP
disabled, the three primary delivery-rate comparisons improve by 0.90%–1.77%.
Normal-MTP comparisons have mixed signs, from −3.29% to +3.95%, so this experiment
does not establish a consistent normal-MTP gain. TTFT remains effectively unchanged.

## Exact comparison

The [metadata cache change](2026-09-06-segmented-dispatch-metadata-cache.md) reuses
immutable segmented dispatch records and value offsets. The baseline probe is
`3de3086d924e38893c31583f47309f3345733364956e0972287fa1ef7a6966c7`, built from
parent `6790dea1c7044ca336cd6383aac7e6d27afb7359` and native
`b01e1af06902c82e22227bf923447cc71c47b148`. The candidate probe is
`ce01b60e20c8fc9b3f4d4c73aee9984a1dd9745a2a67820dca3bc81341b45c3f`, built from
parent `bd8dee80297f0d806b8f5c11bd204460536ca6f6` with native
`a317dde5d678e96cd85327d86cc49a99ca86805c`; its source matches the committed
`bc1819129` integration.

Provider and model-harness source bytes match between builds. Native differences
are the four production cache paths, two test paths and two additive standalone
replay SPI files. All six runtime resource files match exactly, including MLX
and paged Metal. The archive records both source identities and the actual
candidate compiler graph; it does not claim identical source across runtimes.

Every cell uses the original Qwen3.6-35B model and 5,523-token prompt, paged
attention, cache disabled, B1, the production KV grant and output cap 128.
Attention/logit/packet diagnostics are disabled. Each MTP mode has three pairs:
baseline then candidate, candidate then baseline, baseline then candidate.
Original host readiness guards precede every process.

All seven completed trajectories match exactly across the six cells of each
mode: prompt/output IDs, counts, finish and outcome. Canceled outputs remain
prefixes of their own recovery. MTP-off main outputs retain the historical
83 IDs. Normal MTP produces 79 IDs and verifies with the same inline assistant;
its output is compared within that mode. No off/on throughput ratio or
cross-backend token acceptance is inferred from these measurements.

## Primary measurements

The prespecified primary measurement is the second cache-off main row in each
fresh process. Delivered throughput is the number of tokens after the first
nonempty chunk divided by the interval from first to last nonempty chunk.
This excludes every token in the first chunk and accounts for MTP batching;
it is not an independently observed per-token kernel duration.

Positive interval savings mean the candidate delivered the remaining identical
output sooner. The table retains every pair, including the normal-MTP regression.

| MTP | Pair | Baseline tokens/s | Candidate tokens/s | Change | Delivery interval saved |
|---|---:|---:|---:|---:|---:|
| Off | 1 | 114.593 | 115.621 | +0.897% | 6.363 ms |
| Off | 2 | 113.430 | 115.442 | +1.774% | 12.598 ms |
| Off | 3 | 113.560 | 115.349 | +1.575% | 11.199 ms |
| On | 1 | 140.439 | 143.064 | +1.869% | 10.190 ms |
| On | 2 | 137.577 | 133.050 | −3.290% | −19.290 ms |
| On | 3 | 133.161 | 138.424 | +3.953% | 22.272 ms |

| Primary paired statistic | MTP off: median [range] | Normal MTP: median [range] |
|---|---:|---:|
| Delivered throughput change | +1.575% [+0.897%, +1.774%] | +1.869% [−3.290%, +3.953%] |
| Full delivery interval saved | 11.199 [6.363, 12.598] ms | 10.190 [−19.290, 22.272] ms |
| TTFT saved | 0.439 [−1.183, 1.987] ms | −1.346 [−1.794, 1.096] ms |
| First-chunk-to-prefix-62 interval saved | 7.430 [5.626, 9.928] ms | 3.901 [−28.921, 10.162] ms |

The prefix measurement uses the chunk that reaches token 62. A chunk that
crosses that boundary is explicitly marked with its actual delivered count;
no timestamp is interpolated inside an MTP chunk. Complete-output acceptance
is checked separately before timing interpretation.

## First rows and limits

First-row paired throughput changes are retained separately: MTP off
+1.687%, +2.152%, +1.628% (median +1.687%); normal MTP +2.129%, +5.229%, +6.243%
(median +5.229%). These do not replace the primary second-row result.
First-row baseline/candidate rates in the first normal-MTP pair are
71.588/73.112 tokens/s; later first rows range from 132.534 to 144.349 tokens/s.
The raw evidence includes all chunk boundaries, TTFTs, terminal tails, whole
wrapper durations and adaptive MTP depth/verification counters.

The evidence supports a small MTP-off delivery improvement for this prompt on
one M5 Max with B1. Three pairs do not establish a fleet-wide effect, a general
TTFT improvement or a reliable normal-MTP speedup. The experiment does not
measure an SSD hit, longer contexts, concurrent decode or model quality.
Earlier numerical backend comparisons remain separate acceptance evidence.

## Validation and preserved operations

The candidate optimized build passes all 25 argument checks and its complete
source/runtime verification. The existing native cache validation covers
69 functions/108 cases. Eight independent controller CPU tests pass, including
all twelve rendered guard paths and seven-trajectory fault coverage; eleven
unchanged wrapper tests pass on M5 before inference. An initial command naming
a nonexistent helper test module is retained separately.

The original entry guard rejects candidate MTP-off pair 3 before model launch
at 42.442 degrees C. Its four-file attempt is preserved, remote output absence
is verified, and the same command runs only after a fresh original guard passes
at 32.143 degrees C. Subsequent temperature-only cooling observations are also
retained. No completed cell is repeated and no threshold or token assertion is
relaxed. Final postflight records no owned jobs, GPU 32.072 degrees C, load1
1.237 and 350,142,382,080 free bytes; the M5 lane is then handed to the separate
two-host fixture.

The [manifest](evidence/qwen36-dispatch-cache-comparison-2026-09-06/manifest.json)
and [archive](evidence/qwen36-dispatch-cache-comparison-2026-09-06/payloads.tar.gz)
retain 341 payloads, including all twelve raw cells, fixed plans/commands,
analyses, compact optimized build/source/graph proof, source deltas, peer/root
reviews and preserved operational failures. Executables, runtime resources,
weights and keys are excluded.

Manifest SHA-256: `6528ad013d86c0954f9fb7ba8f76e277f7d9c817e83078c45adbeaff5933c59c`.
Archive SHA-256: `07d2b43959b02a101d4a89d65d9c396721f2d63bb05eacbd0bb188f8bf4c648e`
(1,489,390 bytes).
