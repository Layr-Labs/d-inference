# Preserve measured SSD restore cost across Ready refreshes

> Last updated: 2026-09-05 · commit `06b02df7a`

The coordinator now retains a measured SSD restore cost when a later cache Ready
message refreshes the same live checkpoint. A Ready estimate no longer replaces
that measurement or extends its original expiry. Routing still accounts for
ordinary queue, decode and admission costs.

## Change and boundaries

A 4,096-token checkpoint on a 5,000-token/s provider can lose to a cold
4,800-token/s peer when restoring it costs 900 ms. Previously, a later Ready
estimate of 100 ms could incorrectly reverse that decision. The inverse could
also discard a useful measured 100 ms hit when Ready estimated 900 ms. Both
outcomes are covered through validated receipts and `ReserveProviderEx`.

Each holder has an optional immutable sample containing measured milliseconds,
its original lookup expiry and the exact capability. A positive validated SSD
hit replaces the sample. Ready retains it only for the same keyed content,
tenant, connection, anchor, recompute count and capability while both holder and
sample are fresh. It updates the fallback estimate and availability separately.
Normal misses, eviction, invalidation and holder retirement discard the sample.
There is no extra global map, timer or lock.

The holder query captures its timestamp. After binding the current capability,
the hint uses the unexpired measurement or the latest estimate. An attached
sample from a different capability rejects the old holder, including when that
sample has expired: its fallback can also belong to the old contract. This
closes the interval between capability publication and tracker cleanup. A new
valid Ready establishes a current fallback. Scan and reservation share the
same immutable numerical hint.

Unmeasured endpoints in a cumulative Ready message still share the provider's
conservative maximum-file estimate. The current protocol can carry ordered
singleton Ready messages with distinct costs, but the provider sequencer would
also need to retain bounded per-endpoint evidence before lookup. This commit
does not change that producer or sequencer. It corrects the earlier audit's
suggestion that per-endpoint pricing inherently requires a wire expansion.

## Validation

The full registry/API/protocol run passes **2,583 top-level tests and 1,557
subtests**, with two existing opt-in skips. The focused race run passes
**169 top-level tests and 253 subtests**, without skips. The eight new tests
include 13 subcases covering winner reversals, original expiry, replacement
lookups, endpoint/tenant/connection/capability isolation, concurrent Ready/query,
and frozen query time.

The final regression file fails seven tests and four subcases on the old
implementation; nine isolation subcases and one positive-control test pass.
Root review found that the first draft still resolved cost before capability
binding. Its fresh and expired query-before-cleanup cases fail before the
correction. These negative controls and superseded runs are retained separately
from final acceptance.

Root verified all 26 frozen payloads, independently counted the raw Go events,
and applied the seven-file patch. All five Go files match the tested candidate;
the canonical page is restamped and the changelog preserves the previous
capacity milestone. No serving default, protocol or provider code changes.

## Evidence and limits

The [manifest](evidence/cache-stage-measurement-2026-09-05/manifest.json) and
[archive](evidence/cache-stage-measurement-2026-09-05/payloads.tar.gz) retain
35 payloads, including final source, raw test events, negative controls,
and the root integration record.
Manifest SHA-256: `98618244daa4677cc57866343d774f61073217d9c67a16d46a1ce8ee93d83bb1`.
Archive SHA-256: `f1ad91111b5ecd3edcf9e000bd8a256f5f9ff6be195e621b45414490091779aa`.
Source freeze: `61307ecd3c40d5db2efd716bc0174104537e7ad065a3a706ff67a5488584710d`.

These tests establish cost selection and ownership behavior. They do not
establish a model or network latency improvement. Exact-model paged serving,
connected HTTP routing, repeated performance and release promotion remain
separate gates.

Related: [cache-aware routing](../architecture/cache-aware-routing.md),
[signed restore costs](2026-09-05-cache-stage-cost.md),
[attempt generation ownership](2026-09-05-cache-prepare-generation.md).
