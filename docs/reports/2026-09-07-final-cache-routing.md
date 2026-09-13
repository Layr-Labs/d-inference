# Final cache routing checks

> Last updated: 2026-09-07 · commit `dbf2b73cf`

Qwen 3.8 passes all twenty connected HTTP cases across the final cache-OFF and SSD-enabled routing runs. Both runs use paged attention, normal MTP and two isolated provider processes on the M5. SSD routing selects the original prefix holder when both providers are candidates, and four requests each restore 4,096 tokens from SSD.

## Results

| Check | Cache OFF | SSD enabled |
| --- | --- | --- |
| Cold donor A | Pass; no reuse | Pass; cold miss and donation |
| Same prompt A | Pass; no reuse | Pass; 4,096-token hit |
| Other tenant | Pass; no reuse | Pass; isolated cold miss |
| Continuation on provider B | Pass; distinct provider | Pass; cold miss and separate donation |
| Original after continuation | Pass; two routing candidates | Pass; two candidates, original donor A selected, 4,096-token hit |
| Tool call | Pass | Pass |
| Vision | Pass; cold-only | Pass; cold-only |
| Cancellation | Pass; one cancelled completion token and retired attempt | Pass; 4,096-token hit, cancellation and retired attempt |
| Request after cancellation | Pass | Pass; 4,096-token hit |
| Sidecar unavailable | Pass; cold fallback | Pass; cold fallback with no cache scope |

The SSD arm records eight lookups: four hits and four misses, with three accepted donations. The four hits save 16,384 prompt tokens in total. Their lookup receipts and terminal usage agree on the restored prefix; recomputation is zero. The original-after-continuation case has two actual routing candidates and selects donor A's SSD prefix. Other constrained cases establish the specified holder, tenant, capability or fallback behavior rather than an unconstrained routing contest.

Both tool responses finish with one `record_color` call and parsed arguments `{"color":"blue","count":2}`. Both vision responses finish naturally after 30 tokens and describe the white/light-gray cube cluster against a black background. The executing reviewer and root inspect the returned text against the original image. The short 64-token text cases often stop inside reasoning; their routing and accounting results do not establish answer completion or general model quality.

## Runtime and scope

The native runtime is the [verified 0.9.0 build](2026-09-07-release090-final-build.md). Its executable, colocated resources, model manifest and canonical host configuration pass the existing before/after checks. A freshly built Go test helper includes the signed startup-logging change; request contents, normal admission, cache security and owner controls are unchanged. The SSD activation binds the actual accepted OFF verdict, with fresh scope review and complete OFF retirement before launch.

These are functional checks with two isolated providers on one physical Mac and one request at a time. They do not establish cross-machine capacity or performance, production signing/attestation, or authenticated SSD reuse across a signed-process restart. Coordinator receipt-expiry, disconnect and queued-revocation tests pass separately under the race detector; those are distinct from this live fixture's coverage.

## Preserved failures and cleanup

The earlier 143 run registered only one of two providers before its three-minute startup deadline. No HTTP case ran. Its failure remains preserved; the final 146 logging change retains startup diagnostics and is not claimed as a causal fix for that intermittent startup failure. Both providers register successfully in each final 146 arm. The earlier 134 outer catalog-serialization failure also remains separate.

After the accepted OFF worker retired, its immediate collector refused the temperature/load entry guard. Collection resumed from the unchanged, already fetched archive after a fresh ready-host observation. A subsequent summary-only error came from reading an optional `scope` field omitted by the schema-1 report; original worker, archive, receipt and cleanup validation had already passed. The publication summary uses the exact bound plan's scope. Both issues are retained separately and no model run, assertion or original report is rewritten.

Both final workers exit successfully, all owned process groups retire, and the final host observation has no owned or unexpected model processes. All 203 original files across the two collected manifests verify. The M5 is released cleanly.

## Evidence

The [result summary](evidence/final-cache-routing-2026-09-07/evidence.json) includes all twenty cases, provider selection and candidate counts, cache receipts, terminal usage, semantic observations and exact runtime identities. The [selected original evidence capsule](evidence/final-cache-routing-2026-09-07/evidence.tar.gz) contains reports, before/after audits, complete startup logs, manifests, verdicts, retirement, source/runtime identities, root review and preserved failures. Its [manifest](evidence/final-cache-routing-2026-09-07/manifest.json) binds all 76 members; full original archives remain retained and the publication projection does not claim their original file modes.

Related: [acceptance criteria](../design/release-090-acceptance.md), [final tool and vision checks](2026-09-07-final-capabilities.md), [final default checks](2026-09-07-final-defaults.md).
