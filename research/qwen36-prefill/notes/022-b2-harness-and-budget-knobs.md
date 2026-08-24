# 022 — B=2 arrival harness + CBv2 budget knobs

Status: implemented, not yet rebuilt on the Mac

Reviewer 016 vetoed `keep=yes` until the arrival harness can emit B=2
and record harness-computed aggregate prefill tok/s. E2 also needs env
overrides for chunk/budget; those did not exist (017).

## Arrival harness (schema 5)

`--arrival-batch-size 1|2|4` (default 4). JSON records `batchSize`,
`prefillMakespanMs`, `aggregatePrefillTokensPerSecond`:

```
tokens_per_row = prompt_tokens - 1
prefill_makespan = max(first_token) - min(submission)
aggregate = batch * tokens_per_row / prefill_makespan
```

Missing rows poison the cell. B=1 only runs `burst`. Scheduler-prefill
schema 4 adds `firstTokenChecksum` (same FNV as arrival rows).

## Factory knobs

| Env | Default | Effect |
|---|---|---|
| `DARKBLOOM_CBV2_PREFILL_CHUNK` | 512 | `prefillChunkSize` |
| `DARKBLOOM_CBV2_MAX_BATCHED_TOKENS` | 2048 | `maxBatchedTokensPerStep` |

Unset / junk / non-positive keep the serving default. Solo stripe is
resolved after the effective chunk.

E2 candidate (not run yet): chunk=1024, budget=4096 → packed `[4,1024]`
= M=32768, which E1 proved the 0.8.10 metallib hits.
