# App Attest revocation-at-dispatch gap

> Last updated: 2026-09-15 · commit `605651bb9`

Review of the v0.9.4 App Attest revocation boundary. Revocation and receipt
readiness are sampled only after a successful assertion, normally every ten
minutes. If enforcement caches that verdict, a revoked provider can remain
eligible for protected traffic until the cache is refreshed or expires, so the
issue remains after enforcement is enabled.

## Scope and conclusion

This review assumes every provider has moved to macOS 27 and can supply the
required Apple measurements. Older-macOS compatibility is outside this
finding. The reviewed source is the exact v0.9.4 release commit
`605651bb95d71c1da9bb122107925143e9441973`.

The finding is prospective. v0.9.4 runs App Attest in shadow mode, and a
revocation currently changes prospective observations rather than serving
eligibility. Once enforcement consumes a cached eligible verdict, the same
design creates a security window: normal detection is approximately ten
minutes, while the cached verdict can remain valid for as long as the
15-minute assertion freshness deadline. Enabling enforcement without
dispatch-time lookup or immediate invalidation does not close that window.

## Evidence

| Evidence in v0.9.4 | What it establishes |
|---|---|
| `coordinator/api/app_attest_shadow.go:21-25` (`shadowAssertionInterval`) | Successful sessions schedule assertions every `10 * time.Minute`; the shadow session explicitly does not change trust. |
| `coordinator/api/app_attest_shadow.go:250-253` (`runAttempt`) | After a successful exchange, the timer is reset to `shadowAssertionInterval`. |
| `coordinator/api/app_attest_shadow_exchange.go:161-175` (`handleExchange`) | Readiness evaluation follows a successfully verified and committed assertion. |
| `coordinator/api/app_attest_shadow_policy.go:41-55` (`observeBuildPolicy`) | `GetAppAttestReadiness` reads revocation and the latest verified receipt once while building the prospective verdict. |
| `coordinator/store/app_attest_readiness.go:20-47` (`GetAppAttestReadiness`, `RevokeAppAttestKey`) | Revocation is durable in `app_attest_key_revocations`; the readiness query reads it from storage. |
| `coordinator/appattest/authorization.go:5-6,81-82,111-129` (`EvaluateAuthorization`) | The assertion freshness limit is 15 minutes. Revocation, receipt expiry and renewal readiness affect the verdict only through the evidence passed into this evaluation. |
| Production search for `GetAppAttestReadiness` | At this commit, the only production caller is `observeBuildPolicy`; registry selection and dispatch do not read current readiness. |

Suppose an assertion succeeds at time T and produces `eligible`. A revocation at
T plus a small delta does not mutate that already computed result. Under the
normal loop, the next successful assertion and readiness read occur around
T+10 minutes. An enforcement cache that honors `valid_until` can still accept
the old result until T+15 minutes. Failed or delayed assertions can prevent the
ten-minute refresh, leaving expiry as the only bound.

Receipt readiness has the same sampling shape. Expiration or an overdue renewal
that becomes true after evaluation is invisible to a cache unless dispatch
compares the current time with the stored deadlines. Revocation needs the
stronger property of immediate invalidation rather than waiting for a deadline.

## Failure after enforcement

1. A macOS 27 provider completes a valid assertion and receives an eligible
   prospective result.
2. An operator durably revokes the App Attest credential immediately afterward.
3. The provider remains connected and is selected for protected work.
4. Enforcement consults the cached eligible result without reading or receiving
   the new revocation state.
5. Protected traffic continues until another successful assertion refreshes
   readiness or the cached verdict expires.

The gate is enabled in this scenario, but it is enforcing the revocation state
that existed at assertion time.

## Required remediation

The dispatch boundary must apply current readiness. Either of these designs can
satisfy it:

- perform a fail-closed readiness lookup for the selected credential before
  protected dispatch, backed by a bounded coordinator cache whose revocation
  entries are synchronously invalidated or updated by the revocation write; or
- publish revocation generations into the live registry, bind each authorization
  to the generation it observed, and reject the authorization whenever its
  generation is no longer current.

In both designs, authorization remains tied to the current live connection.
The check occurs after provider selection and again before the coordinator
seals or sends the protected request, preventing a revocation race between
selection and dispatch. Unknown readiness, lookup failure, cache uncertainty or
generation mismatch fails closed. Receipt and renewal deadlines are compared
with the current clock on every dispatch.

The revocation transaction and invalidation must have a defined ordering. A
successful revocation response must mean that no later protected dispatch can
authorize the key under the earlier generation.

## Acceptance criteria

- A test establishes eligibility, revokes the key, and proves the very next
  protected dispatch is rejected without another assertion or reconnect.
- A concurrent revocation/dispatch test defines the linearization point and
  proves no dispatch beginning after successful revocation uses the key.
- Revocation propagates across coordinator replicas; a replica with an old
  cache fails closed until it observes the new generation.
- A readiness-store outage or invalidation-channel failure cannot reuse cached
  non-revoked state beyond its explicitly safe bound.
- Receipt expiration and `ReceiptRenewAt + 24h` are evaluated against the
  dispatch clock even when the assertion is still fresh.
- Selection, reselection, retries, speculative attempts and owner/self-route
  paths all apply the same final pre-send check.
- Metrics distinguish revocation rejection, stale readiness, lookup failure and
  receipt-deadline rejection without logging credential material.

## Validation limits

This is a source review. It does not change production behavior, turn on App
Attest enforcement or demonstrate a current shadow-mode serving bypass. It
defines a condition that cached enforcement must satisfy before revocation can
be treated as immediate.
