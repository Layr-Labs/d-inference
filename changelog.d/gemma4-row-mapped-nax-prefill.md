### Gemma 4 row-mapped NAX prefill

Adopt the native SDK's shared plain-greedy metadata shortcut and guarded Gemma 4
row-mapped NAX prefill route, enabled by default within its existing hardware,
shape and evaluation guards. Exact `DARKBLOOM_GEMMA4_NAX_ROW_MAP=0` restores the
original graph, with the override forwarded when creating a LaunchAgent job.
Same-app M5 Max comparisons in both orders measured 6–7% lower cold HTTP time to first generated
frame for uncached 4K/8K single requests, with exact paired outputs. A longer
warm decode control was neutral. These are not additive speedups or concurrency,
other-chip or clustering claims; attention, MTP, admission, prefix caching and
SSD-write policies are unchanged.
