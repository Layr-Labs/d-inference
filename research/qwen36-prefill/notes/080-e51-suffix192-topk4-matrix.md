# 080 — E51 suffix192 + top-k4 cold-prefill matrix

Status: **quality PASS and long-prompt speed PASS; short B1 remains below 2.5×**

## Candidate

```text
DARKBLOOM_QWEN35_PREFILL_ARTIFACT_ONLY=1
DARKBLOOM_QWEN35_PREFILL_FRONTIER_TOKENS=192
DARKBLOOM_QWEN35_PREFILL_MOE_TOP_K=4
full layers: 0-3
artifact history: 4-39
full-depth suffix: final 192 prompt rows
decode/MTP/vision: native
```

All target weights remain immutable. Historical rows construct every K/V and
GDN boundary; the 192-row suffix executes every skipped layer once. Top-k4 is
prefill-only.

## M3 Max throughput

| Cell | Candidate tok/s | Locked baseline | Speedup |
|---|---:|---:|---:|
| B1×512 | 2,213.1 | 1,434.6 | 1.543× |
| B1×2,048 | 3,931.8 | 1,671.4 | 2.352× |
| B1×8,192 | 4,696.8 | 1,546.8 | **3.036×** |
| B2×8,192 | 4,527.2 | 1,500.7 | **3.017×** |
| B4×2,048 | 4,468.2 | 1,695.8 adjacent | **2.635×** |
| B4×8,192 | 4,896.7 | 1,557.4 | **3.144×** |

B2/B4×8K use three-run medians. Their sampled two-token checksums match the
locked native rows exactly.

## Blind 128-token quality

Suffix192 + top-k4 scores **217/300** versus native **225/300**, retaining
**96.44%**:

- 7 ties, 1 candidate win, 4 native wins;
- zero candidate-only fatal failures;
- zero corruption cases;
- all mean-dimension losses remain below the explicit 1.0 limit.

The profile passes the named approximate-policy quality screen. It is not
native numerical parity: token-position agreement is 35.35%.

## Decision

This is the first non-reuse cold candidate to pass both quality and the
long-prompt B1/B2/B4 aggregate speed target. It does **not** complete the full
matrix: B1×512 and B1×2K remain below 2.5×.

The fixed 192-row quality reserve dominates short prompts (37.5% of a
512-token prompt). The next optimization must reduce short-prompt suffix work
without reintroducing the chronology/factual failures observed at suffix64/128.

Artifacts:

- `artifacts/e50-suffix192-topk4-e4-b4-2048.json.gz`
- `artifacts/e51-suffix192-topk4-b1.json.gz`
- `artifacts/e51-suffix192-topk4-b2-8192.json.gz`
- `artifacts/e51-suffix192-topk4-b4-8192.json.gz`
- `artifacts/e50-quality-suffix192-topk4-e4-128.json.gz`
- quality rubric: `notes/079-suffix64-e4-blind-quality-gate.md`
