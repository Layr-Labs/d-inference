# 022 — B=2 arrival harness + CBv2 budget knobs

Status: implemented, not yet rebuilt on the Mac

Reviewer 016 vetoed `keep=yes` until the arrival harness can emit B=2
and record harness-computed aggregate prefill tok/s. E2 also needs env
overrides for chunk/budget; those did not exist (017).

## Arrival harness (schema 6)

`--arrival-batch-size 1|2|4` (default 4). JSON records `batchSize`,
every row's submitted/first-token/completion timestamp, `prefillMakespanMs`,
`aggregatePrefillTokensPerSecond`, and the effective chunk/budget tuning:

```
tokens_per_row = prompt_tokens - 1
prefill_makespan = max(first_token) - min(submission)
aggregate = batch * tokens_per_row / prefill_makespan
```

Missing or invalid rows poison the cell. B=1 only runs `burst`.
Scheduler-prefill schema 5 adds canonical `tokenChecksum` (same FNV as arrival
rows), retains `firstTokenChecksum` as a schema-4 compatibility alias, and
records the effective chunk/budget tuning.

## Factory knobs

| Env | Default | Effect |
|---|---|---|
| `DARKBLOOM_CBV2_PREFILL_CHUNK` | 512 | `prefillChunkSize` |
| `DARKBLOOM_CBV2_MAX_BATCHED_TOKENS` | 2048 | `maxBatchedTokensPerStep` |

Unset / junk / non-positive keep the serving default. Solo stripe is
resolved after the effective chunk.

E2 candidate (not run yet): chunk=1024, budget=4096 → packed `[4,1024]`
= M=32768, which E1 proved the 0.8.10 metallib hits.
