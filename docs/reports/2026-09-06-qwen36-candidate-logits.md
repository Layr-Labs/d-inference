# Qwen3.6 candidate backend logits with SSD disabled

> Last updated: 2026-09-06 · commit `2eebb5412`

The rebuilt candidate still fails strict contiguous/paged token equality for Qwen3.6 with normal MTP and SSD disabled. Both backends complete coherently and reproduce their own outputs exactly. The captured decisions use different MTP verification widths, so these observations do not isolate attention as the remaining cause.

## Observed result

Both processes use the reviewed [combined candidate](2026-09-06-release090-candidate-build.md), the same exact model aggregate, identical 5,523 prompt tokens, and the same serving profile. Actual cache status is `disabled` with reason `config_disabled`; all seven completed long-prompt trajectories per backend have zero saved tokens and identical tokens within that backend. The diagnostic preserves all eight trajectories, including warmup, from the earlier candidate controls.

The first cross-backend difference remains output index 53, counted from zero. Contiguous produces 78 tokens and paged produces 83; both finish with `stop`. The full responses are coherent summaries with wording differences, rather than evidence by themselves of a wrong answer. Strict token equality remains failed.

| Observation at output index 53 | Contiguous | Paged |
|---|---:|---:|
| Confirmed token | 7244 | 2919 |
| Candidate 7244 logit | 27.25 | 27.125 |
| Candidate 2919 logit | 27.00 | 27.25 |
| Verification query width | 5 | 3 |
| Selected column | 1 | 2 |
| Cache offset | 5574 | 5573 |

Both captures are finite BF16 logits from `rectangular_verify`. The confirmed output prefixes are shared up to this decision, but the internal draft prefixes, query widths, and cache offsets differ. A target-only comparison is needed before attributing this result to ordinary single-query attention. The earlier [SDPA partial-precision fix](2026-09-06-qwen36-sdpa-partial-precision.md) is included; this result does not establish full-model closure for that fix.

## Evidence and retained failures

The [share-safe evidence](evidence/qwen36-candidate-logits-2026-09-06/evidence.json) binds the exact runtime, source, input, model, raw report hashes, terminal hashes, and decoded logit bits. It excludes prompts, response text, weights, credentials, and binaries. Both native processes exit zero with complete owned-process cleanup; source, runtime and model audits are unchanged before and after execution.

The initial paged validator incorrectly expected the class name `CBv2PagedKVBackend`; the actual native class is `PagedKVBackend`. Its original failed verdict is preserved. Offline revalidation corrects only that label and uses unchanged model reports, with no GPU rerun. The corrected validation does not change the failed cross-backend token comparison or constitute release acceptance.

## Scope remaining

This run does not exercise SSD restoration, concurrent requests, routing, or target-only parity. Existing D256 numerical tests and a separate target-only model pair are the next diagnostics. Qwen SSD restoration must be validated independently against the same paged cache-off behavior; a backend mismatch must not be relabeled as an SSD failure without that comparison.
