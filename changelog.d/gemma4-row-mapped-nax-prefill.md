### Gemma 4 opt-in row-mapped NAX prefill

Adopt the native SDK's shared plain-greedy metadata shortcut and guarded Gemma 4
row-mapped NAX prefill route. The NAX route remains disabled unless exact
`DARKBLOOM_GEMMA4_NAX_ROW_MAP=1` reaches a directly launched foreground/local
process; the SDK pin and installed LaunchAgent do not enable it. Same-app M5 Max
comparisons in both orders measured 6–7% lower cold HTTP time to first generated
frame for uncached 4K/8K single requests, with exact paired outputs. A longer
warm decode control was neutral. These are not additive speedups or concurrency,
other-chip or clustering claims; attention, MTP, admission, prefix caching and
SSD-write policies are unchanged.
