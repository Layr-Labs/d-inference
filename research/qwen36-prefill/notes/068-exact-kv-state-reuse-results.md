# 068 — Exact KV+GDN state reuse exceeds 2.5×

Status: **measured success profile**

## What is cached/forked

One atomic Qwen boundary contains:

- all ten attention layers' BF16 K/V through the prompt;
- all thirty GDN BF16 conv tails and FP32 SSM states;
- model position;
- frontier logits.

Every adopter/follower receives independent request-owned state. Weight
bytes, model arithmetic for construction, routing, and decode are
unchanged.

## Warm full-prompt reuse

| Prompt | B | Cold makespan | Warm makespan | Speedup |
|---:|---:|---:|---:|---:|
| 512 | 1 | 359.8 ms | 23.5 ms | **15.33×** |
| 512 | 2 | 628.1 | 26.4 | **23.78×** |
| 512 | 4 | 1189.9 | 35.4 | **33.63×** |
| 2,048 | 1 | 1235.7 | 24.5 | **50.37×** |
| 2,048 | 2 | 2517.0 | 29.1 | **86.59×** |
| 2,048 | 4 | 4784.7 | 39.1 | **122.23×** |
| 8,192 | 1 | 5300.7 | 28.4 | **186.82×** |
| 8,192 | 2 | 10957.1 | 34.2 | **320.21×** |
| 8,192 | 4 | 20895.5 | 51.9 | **402.93×** |

All warm rows report exact full-prompt hits and all prompt tokens saved.
First tokens are equal in every cell. B4 full generated sequences are
equal for the configured two-token generation window; B2 has the
already-known second-token batch-geometry variation and therefore reports
`fullTokenEqualityRate = 0`. No 64-token parity artifact is archived.

The construction request is reported separately. With partial-boundary
donation enabled, one 8K donor takes about 8.0 s versus 5.3 s without
snapshotting. Amortized B1 exceeds 2.5× on the fourth total use; B2 needs
two warm B2 batches after construction; B4 exceeds it after one warm B4
batch.

## Simultaneous cold prompt fork

No prior cache entry: one leader computes the common prefix and forks
complete state to followers.

| Prompt | Workload | Native | Fork | Speedup |
|---:|---|---:|---:|---:|
| 512 | B4 identical | 1251.3 ms | 415.3 ms | **3.013×** |
| 8,192 | B4 identical | 21020.4 | 6459.8 | **3.254×** |
| 8,192 | B4, 75% common | 21073.4 | 10446.3 | 2.017× |
| 8,192 | B4, 90% common | 22070.0 | 8401.3 | **2.627×** |

First-token, two-token sequence, and finish parity pass for the reported
B4 fork cells. Cold B2 forking is bounded below 2× after clone cost; B2
reaches the target through warm exact adoption, with the identical-B2
second-token caveat above.

## Safety validation

- exact cache ownership/longest-match: 5/5 pass;
- full/partial B1/B2/B4 adoption and cancellation: 5/5 pass;
- provider benchmark/report: 9/9 pass;
- provider usage wiring: 7/7 pass;
- full provider suite: 2,202 tests pass;
- release build: pass;
- prompt-fork planner/ownership/cancellation is **not** archived as a pass:
  `e32-prompt-fork-tests.txt` stops at a missing default `metallib` before
  the selected XCTest completes.
- real 35B donation bug fixed by binding recurrent conv dtype to the
  dequantized embedding output (BF16), not packed uint32 storage.

## Scope

This success is exact but reuse-dependent. Distinct cold prompts remain
at the native baseline. Durable cache now supports longest exact
256-token hybrid boundaries; live prompt forking supports arbitrary
simultaneous common prefixes. See note 069 for partial sequential hits.

Artifacts:

- `artifacts/e32-prefix-exact-512-v2.json`
- `artifacts/e33-prefix-fork-{2048,8192}.json`
- `artifacts/e34-prompt-fork-cold-{512,8192}.json`

## Decision-grade 8K medians (three iterations)

Each speedup below is `median(cold makespan) / median(candidate
makespan)`, not the median of three paired ratios. Both sides use the same
effective-throughput numerator: all requested prompt tokens in the burst.
The durable-cache candidate excludes its separately reported donor;
the live-fork candidate includes leader compute and follower cloning in
its makespan.

| Profile | B/workload | Native | Candidate | Speedup |
|---|---|---:|---:|---:|
| exact full-prompt hit | B1 | 5344.2 ms | 28.98 ms | **184.44×** |
| exact full-prompt hit | B2 | 10989.2 | 36.14 | **304.07×** |
| exact full-prompt hit | B4 | 20994.5 | 50.07 | **419.27×** |
| cold live fork | B4 identical | 20896.6 | 6225.6 | **3.357×** |
| cold live fork | B4 75% common | 20963.4 | 10239.1 | 2.047× |
| cold live fork | B4 90% common | 20927.1 | 7963.2 | **2.628×** |

The durable benchmark reserved 19,477,509,628 bytes for the cache and
retained 4,829,189,120 bytes after its 32-boundary donor. This is bounded
and charged, but it is not the default deployment posture. E41 reruns the
matrix at the default-off 2 GiB hard ceiling: 75%/87.5% boundaries remain
hits above 2.5× while 25%/50% boundaries are evicted and miss.

The fork report records cache misses but no prompt-fork activity counters,
and its `policyEnvironment` omits both activation flags. Its timing is
consistent with a live fork, but the JSON alone is not execution proof.

Artifacts:

- `artifacts/e36-prefix-exact-8192-3x.json`
- `artifacts/e36-prompt-fork-8192-3x.json`
