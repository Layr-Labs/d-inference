# 022 — B=2 arrival harness + rejected CBv2 budget knobs

Status: harness kept; factory knobs reverted after E2

Reviewer 016 vetoed `keep=yes` until the arrival harness can emit B=2
and record harness-computed aggregate prefill tok/s. E2 temporarily added
env overrides for chunk/budget so the candidate geometry could be measured.

## Arrival harness (schema 6)

`--arrival-batch-size 1|2|4` (default 4). JSON records `batchSize`,
every row's submitted/first-token/completion timestamp, `prefillMakespanMs`,
and `aggregatePrefillTokensPerSecond`:

```
tokens_per_row = prompt_tokens - 1
prefill_makespan = max(first_token) - min(submission)
aggregate = batch * tokens_per_row / prefill_makespan
```

Missing or invalid rows poison the cell. B=1 only runs `burst`.
Scheduler-prefill schema 5 adds canonical `tokenChecksum` (same FNV as arrival
rows) and retains `firstTokenChecksum` as a schema-4 compatibility alias.

## Factory-knob verdict

E2's 1,024 / 4,096 geometry improved aggregate prefill only 1.034x and changed
greedy checksums for two of four rows. Gate 016 therefore vetoes the candidate.
The serving factory no longer recognizes `DARKBLOOM_CBV2_PREFILL_CHUNK` or
`DARKBLOOM_CBV2_MAX_BATCHED_TOKENS`; a regression test pins the shipping
512 / 2,048 defaults even if those names appear in the environment. See 027.
