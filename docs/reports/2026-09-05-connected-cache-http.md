# Connected HTTP prefix-cache validation harness

> Last updated: 2026-09-05 · commit `06af2f585`

The opt-in connected test now exercises the real coordinator HTTP endpoint,
two authenticated provider WebSocket connections and the supervised Rust prompt
sidecar. It records actual routing decisions, accepted cache receipts and native
saved-token usage. Its helper tests pass; real-provider/model execution remains
pending and no speedup or rollout completion is established by this commit.

## Behavior and isolation

Ten sequential cases cover cold donation, repeat, tenant isolation, continuation
on a second provider, the original prompt with both providers eligible, forced
tools, supported vision staying cold, cancellation after restore, recovery and
sidecar-unavailable cold serving. Candidate membership is controlled for the
necessary donor placement; the original-prefix case uses normal routing with
both eligible. Matched positions must have been explicitly advertised by the
selected provider. Merely having a longer prompt does not prove a shorter
checkpoint is reusable.

The input pins exact catalog and manifest data, prompt artifacts, provider and
Metal binaries, sidecar, normal MTP and the Gemma assistant. Two actual loaded
capacity slots must report the requested backend without fallback. Profiles
must prove actual MTP mode; SSD cases require positive native reuse and accepted
coordinator lookup counters. A naturally finished request cannot satisfy the
restored-cancellation gate.

The transparent loopback relay retains bounded typed observations without
keys, receipt nonces, scopes, token-chain hashes or encrypted request bodies.
HTTP content and reasoning use authored fixtures. Terminal usage, selected
provider and scheduler decisions are correlated by request ID. Receipt arrival
and coordinator acceptance are checked separately.

The fixture uses in-memory coordinator storage and fresh local credentials.
Runtime, configuration, PID/state, cache, temporary and updater paths belong to
the fixture. It requires an existing unchanged canonical config and an unentitled
provider binary; it refuses host artifacts that startup would otherwise remove.
It uses explicit ephemeral SSD keys and existing testbed trust overrides.
Persistent key repair and attestation are not exercised.

The pair comparator requires matching final artifact identities, backend,
concurrency, normal MTP, request bytes and UTC date, with completed passing
cells. It compares served content/reasoning, decoded tools, finish and native
and HTTP token counts. Timing-dependent partial cancellation lengths are
retained separately and are not treated as token-parity measurements.

## Validation

The frozen source has **16 paths**, with the canonical developer procedure
merged as a separate additive section. Go race checks pass 14 helper functions
and 21 cases, plus 11 shared-regression functions/cases, with no failures or
skips. Four Python comparator tests pass. Root verified every frozen source,
patch and validation hash, the raw Go counts, the unchanged coordinator/shared
test baseline between the candidate base and integration base, and every
resulting source hash.

This fixture does not itself establish cross-machine capacity, latency,
persistent-key restart, old-provider echo handling, expiry/eviction, reconnect,
queued revocation or expensive-holder decisions under real-model traffic.
Those remain separate release gates or explicitly scoped coordinator tests.
Heartbeat memory/read observations are snapshots, not continuous peaks or
per-request authenticated-read measurements. No new serving default is enabled.

## Evidence

The [manifest](evidence/connected-cache-http-2026-09-05/manifest.json) and
[archive](evidence/connected-cache-http-2026-09-05/payloads.tar.gz) preserve
32 source, patch, validation and review payloads. No compiled binaries
are included.
Manifest SHA-256: `41982e341afbe6a0195a4898b424661d203b49bdc6bde8a0071a99ddb5e3196b`.
Archive SHA-256: `54b800a767068d5c077a6412da5fb80d97663401cd9b39ad03308c723e5a74a3`.
Source freeze manifest: `06cf8634acfc8c2f05f510e5c129dbd71bce21575f4947bb0d3a8788828a3a4c`.

Related: [connected test procedure](../developer/test.md#connected-coordinatorprovider-http-cache-gate),
[production-grant benchmark](2026-09-05-production-grant-harness.md),
[cache routing](../architecture/cache-aware-routing.md).
