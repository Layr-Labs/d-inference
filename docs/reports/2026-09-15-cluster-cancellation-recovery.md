# Two-Mac cancellation and fresh-epoch recovery

> Last updated: 2026-09-15 · commit `605651bb9`

Two controlled cancellation cases completed on the 24 GB and 48 GB M4 Pro Macs.
Each retained its reservation until retirement, completed native and owner cleanup,
and then returned the expected 128-token sequence from a fresh Pair and epoch.
Provider HTTP recovery and broader peer-failure qualification remain open.

## Scope and observed behavior

Both cases use registered Qwen3.5 9B 4-bit, JACCL over Thunderbolt RDMA, cut 4/28,
B1, the pinned 8,192-token diagnostic prompt, 512-token chunks, 128 greedy outputs,
empty stop tokens and MTP off. The existing lookahead worker and wakeup owner
modules are unchanged from the [lookahead correctness/timing runs](2026-09-15-cluster-lookahead-generation-and-timing.md).

| Case | Observed cancellation point | Recovery |
|---|---|---|
| Before first token | Zero tokens; cancel 0.530562541 s after request start, after the configured 500 ms delay | Fresh Pair/epoch; all 128 expected IDs |
| After first decode | Second selected token, ordinal 1; prefix `[271, 8839]`, before another token decision | Fresh Pair/epoch; all 128 expected IDs |

The first case identifies a controller event interval, not an active GPU kernel.
Both requests were unretired at cancellation, withdrew Pair readiness and produced
no clean-finish callback. The early release attempt retained all 2,216,442,591
reserved bytes; the charge became zero only after actual retirement. This is a
request allowance, not measured physical memory. Cleanup may use owned fencing;
cooperative-only cancellation is not established.

Each recovery starts after both native-cleanup and authenticated owner-lease ACKs
for the preceding incarnation. All four request IDs and membership epochs differ.
Both recoveries finish with `length`, retire, release their charge and complete
native/owner cleanup. Postflight finds empty journals and no retained children;
the temporary alias is removed with interface/bridge/management state preserved.

## Resource observations and limits

| Case | 24 GB: samples / minimum actual free | 48 GB: samples / minimum actual free |
|---|---:|---:|
| Before first token | 123 / 6.186157 GiB | 125 / 9.997696 GiB |
| After first decode | 178 / 6.150406 GiB | 181 / 10.478683 GiB |

All 607 samples reproduce raw free-page arithmetic and report AC power, zero swap,
pressure level 1 and at least 6 GiB actual free memory. Samples are not continuous
peak-memory proof. The fresh recovery UUIDs receive a selected-sequence guard,
without a new full-logit/state comparison. Same-epoch reuse, external HTTP TTFT,
sustained performance and general-model serving are outside this result.

The prospective CPU audit was frozen before either physical record was read.
Both comparisons pass unchanged policy `5c60354d21d34fc561d276a836c3a6b25683dfb95d70d606c3faebec095b4d13`.
Before-first comparison: `0f971ab1abed9dcd097b62c7ef9c1ce33f4102e477852298c8e2042cbe6718b0`.
After-decode comparison: `57038f4a293f7e8d7d67bca79683f0c680364c4b19ec3a3a06c5a6604dccad53`.
Retained results: `owner-cancellation-physical-audit-results-20260915`.
The [execution plan](../design/distributed-cluster-execution-plan.md) remains in progress.
