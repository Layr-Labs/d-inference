# Qwen27B C256 memory and scheduling diagnostics

> Last updated: 2026-09-17 · commit `605651bb9`

Both 27B diagnostic requests complete across the 24 GB and 48 GB M4 Pro Macs,
matching all 128 reference tokens and retiring cleanly. With 256-token chunks,
one-chunk lookahead reduces internal first-token agreement from about 69.8 to
52.5 seconds. These measurements include instrumentation and do not qualify
product throughput, external TTFT or a larger weight shard.

The matched workload uses an 8,192-token prompt, 256-token chunks, 128 output
tokens, a 16/48 layer split, empty stop IDs and MTP off. Both cases use native
`379b413d…300230`, the same model and fresh ordinary reference, and distinct
membership epochs. There is one diagnostic request per scheduling policy.

| Measurement | Serial, 24 GB | Serial, 48 GB | Lookahead, 24 GB | Lookahead, 48 GB |
| --- | ---: | ---: | ---: | ---: |
| Request to first-token agreement, seconds | 69.8064 | 69.8349 | 52.4618 | 52.4889 |
| Request through retirement, seconds | 82.0366 | 82.0650 | 64.6785 | 64.7055 |
| Minimum external sampled free memory, bytes | 7,160,250,368 | 19,453,018,112 | 7,229,210,624 | 19,634,814,976 |
| Maximum sampled MLX active memory, bytes | 4,381,193,508 | 12,035,440,410 | 4,381,193,508 | 12,014,993,178 |
| Cumulative allocator peak, bytes | 4,985,520,098 | 12,513,675,816 | 4,985,520,098 | 12,513,675,816 |
| External resource samples | 340 | 343 | 281 | 283 |

Every external sample has normal pressure, zero swap and AC power. Root replay
checks actual-free arithmetic against the raw page counts. Sampled allocator
cache is zero. Native observations are discrete: their minimum free-memory
values are higher than the external minima, so they cannot prove a continuous
peak or establish additional placement headroom. Existing resource checks and
the 6 GiB minimum stay unchanged.

On rank 0, free memory falls by 1,399,668,736 bytes in serial and 1,412,415,488
bytes in lookahead between `loadComplete` and `requestBegin`, over about 3.065
seconds in each process. MLX active and cache bytes do not change in that
interval. Anonymous pages increase by 85,271 and 85,522 respectively, at
16,384 bytes per page; wired pages increase by 102 in each case. These are
system-wide observations. They locate a repeated interval but do not identify
the allocating process or prove the cause. VM categories overlap and must not
be summed as independent allocations.

Both native workers exit normally in each case. The original owners acknowledge
native cleanup and device release; diagnostic EOF and owner transport exits
complete; the original canonical journals are empty at collection. The temporary
Thunderbolt alias is restored only after cleanup. Separate maximum-profile Ready
capacities and actual C256 request reservations match the recorded admission
acknowledgments, remain charged through retirement, and reach zero after release.

The new ordinary C256 reference completes 128 tokens with 144 final state
entries and frontier 8,319. Its earlier attempt refuses its higher reference
free-memory requirement by 40,924,827 bytes and is retained as a failure. After
quiescent disk-cache preparation, the fresh retry passes without changing its
native binary, workload or resource thresholds. The observer runs compare all
token IDs to that accepted reference; they do not perform a new independent
full-vocabulary-row or state comparison.

The [evidence record](evidence/qwen27b-c256-phase-memory-20260917/review.json)
pins the reference, native package, both sidecars, raw resource logs, controller
results and matched comparison. Each timing subtracts timestamps from one
process only. Transport waits are not measured wire costs. No encrypted RDMA,
MTP, external SLA, M3 Ultra or new placement claim follows from these results.
The [earlier C512 profile](2026-09-17-cluster-qwen27b-phase-profile.md) uses a
different observer composition and is not a controlled C256/C512 comparison.
The [memory calibration](2026-09-17-cluster-qwen27b-memory-calibration.md) retains
the existing restriction on a larger 24 GB shard.
