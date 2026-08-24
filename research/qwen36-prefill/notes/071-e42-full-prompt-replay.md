# 071 — E42 full-prompt replay does not restore continuation parity

Status: **rejected; cached-frontier implementation retained**

## Hypothesis

Instead of sampling cached full-prompt frontier logits, restore the
previous 256-token exact boundary and replay the final prompt block. This
recreates the ordinary prompt-to-decode transition while retaining most
of the full-hit speed.

The experiment was explicit and default-off:

```text
DARKBLOOM_PREFIX_BENCH_CACHE_MAX_BYTES=2147483648
DARKBLOOM_PREFIX_BENCH_REPLAY_FULL_PROMPT=1
```

## 8K / 64-token / three-run result

| Workload | First-token speedup | Total makespan speedup | Full equality | Mean token agreement | Median equal prefix |
|---|---:|---:|---:|---:|---:|
| B1 full replay | 17.704× | 6.181× | 0% | 3.1% | 2 |
| B2 full replay | 24.445× | 8.991× | 0% | 1.6% | 1 |
| B4 full replay | 26.341× | 10.734× | 0% | 7.8% | 5 |
| B4 75% partial | 3.631× | 3.140× | 75% | 78.1% | 64 |
| B4 87.5% partial | 7.100× | 5.196× | 75% | 89.1% | 64 |

Replaying the final block improves only B4's common generated prefix
(two to five tokens). B1/B2 are unchanged and every full-hit sequence
still diverges. The cause is therefore not merely cached-frontier
sampling; adopted cache layout and/or subsequent decode scheduling
remains the active thread.

## Verdict

Reject the extra policy surface and replay cost. Keep the faster
cached-frontier implementation, retain E40/E41's explicit quality
blocker, and investigate decode-layout/scheduling parity directly.

Artifact:
`artifacts/e42-replay-full-2gib-decode64-3x.json.gz`.
