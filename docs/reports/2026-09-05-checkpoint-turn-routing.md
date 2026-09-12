# Checkpoint routing across machines and turns

> Last updated: 2026-09-05 · commit `825696740`

The coordinator routes against actual committed checkpoint endpoints. A longer
checkpoint on machine B does not imply that B can restore an earlier recurrent
state held by machine A. This audit adds one test through the real receipt and
reservation path; no production code changes or model performance claims follow.

Existing coverage sends a 4,352-token original prompt to A, which publishes a
4,096-token checkpoint. B later publishes an 8,192-token checkpoint. When the
original prompt returns, only A has a usable checkpoint. B becomes eligible for
that earlier state only after separately publishing it. Busy holders can lose
to ordinary cold routing. Epoch changes, tenant scope, missing/corrupt files,
disconnects and invalid receipts have existing coverage.

The new regression sends a later 9,216-token request through
`PrepareCacheAttempt`, `ApplyPrefixCacheReadyV2` and `ReserveProviderEx`. With
synthetic equal prefill rates of 1,000 tokens/s, A offers its 4,096-token
checkpoint at 120 ms staging; B offers 8,192 tokens. B wins at 100 ms staging,
loses at 5,000 ms staging, and loses when its queue outweighs the extra saved
prefill. If both holders are busy, an eligible cold machine can win and receives
zero inherited cache credit. These values exercise decisions; they are not
measured hardware rates or tuned defaults.

The index uses exact scoped endpoint hashes. Turn numbers and conversation
affinity do not establish a hit, and an ancestor in a token tree cannot invent
a recurrent checkpoint. Each machine's longest executable endpoint is priced;
the current protocol does not let the coordinator select a cheaper earlier
endpoint on that same machine. Provider restore still verifies the advisory hit.

The broader audit passed 21 top-level tests and 39 subtests normally and under
the race detector. Review then removed a wall-clock-sensitive lower bound from
the new test's benefit assertion. Exact provider selection, positive bounded
benefit and cold-zero assertions remain. That final four-case table passed
normally and under races, with no failures or skips. Pure service-cost tests
retain the deterministic age arithmetic checks.

The [evidence manifest](evidence/checkpoint-turn-routing-2026-09-05/manifest.json)
preserves both source identities, commands, full output and the review. The parent
verified the final test, 12 unchanged reviewed source paths and every raw test
result before archiving. The implementation and current routing policy are
described in [cache-aware routing](../architecture/cache-aware-routing.md).
