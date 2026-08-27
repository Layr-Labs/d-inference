# Routing retry amplification and structural fit — 2026-08-27

## Measured failure

A rolling one-hour Datadog snapshot showed:

| Model | Provider selections | `deadline_unreachable` attempts | Final deadline rejects |
|---|---:|---:|---:|
| `gemma-4-26b-qat-4bit` | 99,432 | 56,551 | 482 |
| `gpt-oss-20b` | 75,791 | 55,476 | 850 |

Most requests were eventually rescued, but only after large retry amplification.
The same window reported 44,117 Gemma and 34,902 GPT selections where the winner
was occupied while another eligible loaded provider was idle
(`routing.ttft_spread{would_redirect_to_idle:true}`).

The live public stats snapshot had 1,283 providers, 462 active requests, no
coordinator queue, 8.45% network utilization, and 0.49% token-budget utilization.
The problem was not aggregate capacity.

## Root causes

1. `dispatchState` set `lastFailedVersion` after every provider error
   (`coordinator/api/dispatch.go`). A deadline or capacity refusal on the dominant
   release therefore activated `RequestTraits.AvoidVersion`, and
   `scanCandidatesLocked` removed that whole version whenever any different
   version existed (`coordinator/registry/scheduler.go`). At measurement time,
   almost the entire connected fleet reported v0.8.13 while only a small
   long-tail ran older releases. A request-local deadline miss was incorrectly
   treated as evidence against the binary.
2. The occupancy-aware TTFT estimator existed only as a shadow diagnostic
   (`coordinator/registry/ttft_shadow.go`). Hard admission used an
   occupancy-free estimate, while the provider's serialized scheduler made an
   atomic decision from authoritative queue state and frequently refused the
   selected attempt.
3. Equal-cost/equal-load candidates ended in random choice. The selector did not
   preserve a constrained provider's structural size class for small requests,
   so a small request could consume capacity on a machine that future large
   requests uniquely needed.

## Change

- Version diversity now records only version-sensitive template, encryption,
  generation, and internal faults. Neutral failures retain an earlier valid hint
  but never create or overwrite one.
- `TTFT_ADMISSION_MODE=enforce` becomes a fail-open routing preference. Known
  deadline-fitting candidates beat known misses; if all known candidates miss,
  the minimum prediction gets first chance; unknown estimates stay eligible.
  The mode disables estimate-based TTFT rejection but preserves the absolute
  request clock and provider-side atomic admission.
- Existing near-cost, equal-load, cache-equivalent ties use bounded weighted
  rendezvous over structural token-budget class. If every budget is unknown,
  RAM class is the fallback. A constrained provider gets at most 2× an
  equivalent larger provider's share; mixed knowledge stays uniform.

The checked-in deployment configuration remains `shadow`. The version and structural-fit
corrections are unconditional because they only remove false evidence and refine
an already-equivalent tie. Occupancy enforcement requires a canary.

## Rollout checks

Compare equal traffic windows after deployment:

- `inference.error{reason:deadline_unreachable}` / `routing.provider_selected`
  decreases materially.
- Provider selections per successful request decrease.
- Final HTTP 429, 5xx, client-gone, and queue-timeout rates do not increase.
- `routing.ttft_spread{would_redirect_to_idle:true}` decreases when occupancy
  enforcement is canaried.
- Short requests shift toward smaller sufficient token/RAM classes without
  increasing first-content or completion latency; large-request capacity rejects
  do not increase.

Rollback occupancy routing by restoring
`EIGENINFERENCE_TTFT_ADMISSION_MODE=shadow`. The fault-only version classifier
and structural size-class tie-break are code changes and roll back with the
coordinator revision.
