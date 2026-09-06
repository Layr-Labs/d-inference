# Qwen3.5 passes native B1 backend and SSD validation

> Last updated: 2026-09-06 · commit `2eebb5412`

The exact `qwen3.5-35b-a3b` artifact passes the three native B1 cells on the reviewed correctness candidate: contiguous cache-off, paged cache-off and paged SSD cache-on. Both backend migration and same-paged SSD comparisons produce identical 79-token normal-MTP outputs for the retained prompt.

## Scope and results

Run `114-qwen35-retained-b1` uses the [candidate build](2026-09-06-release090-candidate-build.md), a 5,523-token prompt, production-derived KV grants and one active sequence on the 128 GiB M5. The native benchmark explicitly selects each backend/cache mode and enables the model's embedded MTP. Runtime104 remains version `0.8.16`; this is candidate validation for the planned release, not a tested `0.9.0` binary.

| Native cell | Ordinary first/repeat outputs | Result |
|---|---|---|
| Contiguous, cache off | 79 tokens each, `stop` | Pass |
| Paged, cache off | Exact match to contiguous | Pass |
| Paged, SSD cache on | Exact match to paged cache-off | Pass |

All three cells pass actual forward-width, request integrity, accounting, tenant-isolation, cancellation and drain checks. Four requests in the SSD cell report actual staged hits with 4,096 matched and saved tokens: the ordinary repeat, cancellation donor, restored cancellation and recovery. Three complete with the same 79-token output; the cancellation completes after five output tokens with `cancelled`. Cache keys use the isolated ephemeral test mode; no persistent-key restart is tested.

## Evidence and limits

The [verified summary](evidence/qwen35-b1-validation-2026-09-06/evidence.json) records both passing comparisons, the four hits and complete cleanup. Root verification covers 332 original evidence files, excludes nine encrypted payload files from the collected projection, and confirms all three before/after source, runtime and full-model audit pairs match exactly. The [capsule](evidence/qwen35-b1-validation-2026-09-06/evidence.tar.gz) preserves 15 selected original reports, inputs, metadata, verdicts and retirement records; its [archive receipt](evidence/qwen35-b1-validation-2026-09-06/archive.json) binds the copied archive bytes. Complete audits and the original full archive remain separately retained, with their identities recorded in the summary.

This closes the tested native B1 comparison only. B2/B4 concurrency, sustained load, representative answer quality, persistent restart, routing and release-wide acceptance remain separate. [Default HTTP behavior](2026-09-06-qwen-default-http.md) has its own evidence and is not inferred from these explicit native switches.
