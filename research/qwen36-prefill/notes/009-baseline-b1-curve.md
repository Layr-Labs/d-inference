# 009 — Official B=1 CBv2 prefill baseline (this M3 Max)

Status: kept (measurement)

Harness: installed Darkbloom 0.8.10, `--scheduler-prefill`, 3 iters,
contiguous, High Power, AC, stripe cfg 2048, after 128-token warmup.
JSON: `/Users/gaj/work/qwen36-prefill/results/baseline-scheduler-prefill.json`

| L | i1 ms/t (TTFT) | i2 | i3 | **median ms/t** | **median tok/s** | **median TTFT** |
|---:|---|---|---|---:|---:|---:|
| 512 | 0.698 (356.8) | 0.697 (356.0) | 0.695 (355.4) | 0.697 | **1,435** | 356.0 ms |
| 2048 | 0.655 (1340.9) | 0.596 (1220.7) | 0.599 (1225.3) | 0.599 | **1,669** | 1225.3 ms |
| 8192 | 0.643 (5263.7) | 0.643 (5265.6) | 0.642 (5261.2) | 0.643 | **1,555** | 5263.7 ms |

Canary L=512 was 1,217 tok/s (colder). Use this table, not the canary.

## Slope reading

- 512 → 2048 gets **faster** per token (1.44k → 1.67k): chunk/launch
  overhead amortized; 2048 is exactly one solo stripe.
- 2048 → 8192 gets **slower** (1.67k → 1.56k). 8K is **four** striped
  2048-token weight streams. 4 × 1225 ms = 4900 ms; measured 5264 ms
  (+7.4%). The extra is growing full-attn windows, not a new regime.

8K B=1 is **chunk-serialized weight traffic**, not an L² blow-up.

## 2.5× bars (B=1)

| L | baseline tok/s | 2.5× |
|---:|---:|---:|
| 512 | 1,435 | 3,588 |
| 2048 | 1,669 | 4,173 |
| 8192 | 1,555 | 3,888 |

One-shot 8K (single weight stream, if legal) has a physical shot at
the 8K bar. 4-bit packed roof at one stream is far above this.

## Burst preview (arrival-2048, i=1, still running)

Log line `aggregate 211.3 tok/s` is **decode** TPS (`generatedTokens-1`
over first-to-last token). Ignore it for this goal.

Makespan **4,926 ms** for 4 × 2048 prompt + 2 decode.

4 × 2048 / 4.926 s = **1,663 prefill tok/s ≈ 1.00× B=1 2048**.

Matches `notes/014` + `notes/008`: burst is 4 packed `[4,512]` steps
(step budget 2048), i.e. **4 full weight streams** — same bytes/token
as four solo 2048s. Packing fires; the budget/chunk split wastes it.

H0 outcome: **packing-on, tokens-per-weight-stream stuck at 2048.**
2.5× aggregate means ≥5120 tokens per weight stream (e.g. packed
`[4,2048]` in one step ⇒ `maxBatchedTokensPerStep ≥ 8192` and
`prefillChunkSize ≥ 2048` on bursts).
