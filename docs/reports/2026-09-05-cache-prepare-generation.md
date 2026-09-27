# Cache plans and dispatch attempts across configuration changes

> Last updated: 2026-09-05 · commit `a9eee7871`

Cache routing now rejects plans and queued cache metadata from a retired
configuration. It preserves the ordinary encrypted request and its remaining
deadline when cache participation is revoked before writer dequeue. The change
also removes four duplicate mutable request fields; no routing default changes.

## Change

Planning captures a small configuration generation before sidecar I/O, then
revalidates it. Holder queries and captured cost hints carry that same generation
through scan and reservation. Prepare records one tracker and publishes its
immutable nonce owner only after checking configuration, connection, capability
revision and the request's preparation ticket again.

The queued frame reads this owner at dequeue. Configuration changes, Forget,
terminal cancellation and disconnect revoke queued cache scope without taking
registry locks across JSON or socket I/O. An already accepted cache write may
finish after revocation and remains excluded from ordinary latency calibration.
Terminal owners retain the existing bounded authenticated-ready receipt grace.
Cleanup acts on the original tracker and nonce; it cannot clear a later attempt.
Quarantine validates the current connection and capability under the established
registry → provider → tracker lock order before mutating evidence.

`PendingRequest` no longer duplicates `CacheReceiptNonce`, `CacheScope`,
`PrefixCacheProtocol` or `CacheReceiptBoundaryMode`. The protocol-0 encrypted-body
cache-bust key still has a production consumer and is retained. The earlier
signed restore-cost routing behavior remains intact.

## Validation

| Check | Result |
|---|---|
| Final isolated registry/API/protocol suite | 2,568 top-level tests and 1,524 subtests passed; two existing opt-in skips |
| Focused cache/checkpoint/writer race run | 154 top-level tests and 220 subtests passed |
| Combined race against this parent and signed-cost changes | 160 top-level tests and 240 subtests passed |
| Baseline regression reproduction | Seven expected failures: two stale sidecar returns and five stale queued-scope scenarios |

The two skips are `TestPerfE2E_ChatCompletions` and
`TestVerifyProviderViaMDM_TimeoutTransient`. Root verified every frozen payload,
independently counted the final raw JSON test records, and checked all 28
integrated Go file hashes against the combined race source. Integration applies
the exact patch, preserves later signed-cost additions, and binds the existing
stage-cost test's synthetic plan to the current generation.

Five 200 ms samples on an Apple M3 Max with Go 1.25.0 measured ordinary frame
construction at 383.5 → 389.6 ns/op and prepared frames at 505.5 → 515.0 ns/op.
Both retain three allocations, at 448 and 640 bytes respectively. These small
shared-host CPU diagnostics are not live network/model latency evidence.

## Lifecycle audit and limits

Production WebSocket connections receive fresh UUIDs and cannot register twice.
Synthetic direct Registry calls that reuse an ID can still let delayed legacy
ID-scoped disconnect cleanup erase replacement cache metadata. Exact provider
pointer and nonce checks prevent cross-connection proof; cleanup does not cancel
or refund the replacement's requests. This pre-existing metadata-loss case was
recorded without introducing a global-lock tracker sweep.

Primary dispatch, retry and speculative backup construct separate pending
requests. Promotion retains a still-active backup; it does not reopen a terminal
owner. Full multi-provider cache-routing latency and the exact five-model paged
release matrix remain required and unmeasured by these tests.

## Retained evidence

The [manifest](evidence/cache-prepare-generation-2026-09-05/manifest.json) and
[archive](evidence/cache-prepare-generation-2026-09-05/payloads.tar.gz) retain
61 payloads: exact source, baseline fixtures, prior/final raw runs,
microbenchmarks, lock/lifecycle audit and root integration checks.
Manifest SHA-256: `4626633ec4e25fe2ae30a678e6359912d53caa14b1102037f15a6327ec1c7cc6`.
Archive SHA-256: `c2c64c5801a830244c426df5a2d0101f9f836df14522a81e83977f7863adc764`.
Source freeze SHA-256: `472b31a26b75197395cfb3f935301ce0b455cc7520f0248f02b7f5e9b2b273f4`.

Related: [cache routing](../architecture/cache-aware-routing.md),
[signed restore cost](2026-09-05-cache-stage-cost.md).
