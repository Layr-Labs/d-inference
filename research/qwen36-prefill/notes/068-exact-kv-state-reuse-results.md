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
equal; B2 has the already-known second-token batch-geometry variation.

The construction request is reported separately. Amortized B1 exceeds
2.5× from the third use onward; B2/B4 exceed it after one construction
plus one warm batch.

## Simultaneous cold prompt fork

No prior cache entry: one leader computes the common prefix and forks
complete state to followers.

| Prompt | Workload | Native | Fork | Speedup |
|---:|---|---:|---:|---:|
| 512 | B4 identical | 1251.3 ms | 415.3 ms | **3.013×** |
| 8,192 | B4 identical | 21020.4 | 6459.8 | **3.254×** |
| 8,192 | B4, 75% common | 21073.4 | 10446.3 | 2.017× |
| 8,192 | B4, 90% common | 22070.0 | 8401.3 | **2.627×** |

First-token and finish parity pass. Cold B2 forking is bounded below 2×
after clone cost; B2 reaches the target through warm exact adoption.

## Safety validation

- exact cache ownership/LRU/layout: 3 tests pass;
- B1 repeat, B2/B4 warm adoption, cancellation: 3 tests pass;
- prompt-fork planner/ownership/cancellation broad suite: pass;
- provider exact-cache wiring: pass;
- release build: pass;
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

| Profile | B/workload | Native | Candidate | Speedup |
|---|---|---:|---:|---:|
| exact full-prompt hit | B1 | 5344.2 ms | 28.98 ms | **184.44×** |
| exact full-prompt hit | B2 | 10989.2 | 36.14 | **304.07×** |
| exact full-prompt hit | B4 | 20994.5 | 50.07 | **419.27×** |
| cold live fork | B4 identical | 20896.6 | 6225.6 | **3.357×** |
| cold live fork | B4 75% common | 20963.4 | 10239.1 | 2.047× |
| cold live fork | B4 90% common | 20927.1 | 7963.2 | **2.628×** |

Artifacts:

- `artifacts/e36-prefix-exact-8192-3x.json`
- `artifacts/e36-prompt-fork-8192-3x.json`
