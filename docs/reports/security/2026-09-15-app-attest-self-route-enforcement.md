# App Attest enforcement and owner self-routing

> Last updated: 2026-09-15 · commit `605651bb9`

This review records a routing-policy hazard that remains when App Attest
enforcement is enabled unless the new authorization check is independent of
the existing owner trust relaxation. It assumes the enforced provider fleet is
entirely on macOS 27.

## Conclusion

Owner self-routing and prefer-owner routing set `selfRouteOwner` and lower the
legacy hardware-trust requirement to `TrustNone`. Turning on App Attest at that
legacy trust boundary would therefore preserve an owner-only bypass after
enforcement. App Attest eligibility must be a separate, nonrelaxable predicate
for every protected dispatch and reseal path.

This is not an App Attest cryptographic failure. It is an integration failure
that appears if enforcement inherits the existing `relaxTrust` semantics.

## Evidence

| Behavior | Source |
|---|---|
| An owned provider gets `relaxTrust=true` when a request uses either `SelfRouteOnly` or `PreferOwner`. | `coordinator/registry/scheduler.go` (`commitProviderReservation`, `scanCandidatesLocked`) |
| The common routing gate translates `selfRouteOwner` into `minTrust = TrustNone`. | `coordinator/registry/scheduler.go` (`providerRoutingGateReasonLockedEx`) |
| The precomputed dispatch-plan path makes the same owner/relaxation decision. | `coordinator/registry/dispatch_plan.go` (`tryReserve`) |
| The relaxation currently covers the legacy hardware-trust floor and private-only admission; other privacy checks continue to run. | `coordinator/registry/scheduler.go` (`providerPassesRoutingGatesLocked`, `providerRoutingGateReasonLockedEx`) |
| App Attest has only a shadow configuration in v0.9.4, so no independent dispatch predicate exists yet. | `coordinator/api/app_attest_shadow_config.go` (`AppAttestShadowConfig`) |

At v0.9.4 lines 721–735 and 1160–1193, `scheduler.go` computes owner
relaxation for both the commit and scan paths. Lines 1565–1573 lower the trust
floor. `dispatch_plan.go` lines 416–425 repeat the owner decision during plan
commit.

## Why enforcement alone does not remove the issue

A global “App Attest enforcement enabled” setting does not change the meaning
of `selfRouteOwner`. If the implementation represents App Attest eligibility as
another hardware trust level, or skips it whenever `relaxTrust` is true, an
owned macOS 27 provider can still receive protected traffic without current App
Attest authorization.

The same risk exists in `PreferOwner`, not only explicit “my machine” routing.
It also exists in every alternate admission path that reconstructs
`selfRouteOwner`, including reservation rechecks and dispatch plans. Adding a
check to only the initial candidate scan is insufficient because later commit
paths are authoritative.

## Required enforcement invariant

For protected traffic, the dispatch decision is:

```text
legacy routing gates pass
AND current live-connection App Attest authorization is eligible
```

The second predicate does not receive or inspect `relaxTrust` and cannot be
bypassed by ownership, `SelfRouteOnly`, `PreferOwner`, breaker fallback,
preflight, or a cached dispatch plan.

The authorization must bind the account, current provider connection, current
endpoint encryption key, credential, app identity, environment, and unexpired
assertion. It must also use current revocation and approved-build state at
dispatch or reseal.

## Acceptance evidence

Enforcement is not ready until tests demonstrate all of the following:

1. A public request rejects an owned or unowned provider whose App Attest
   outcome is missing, unknown, stale, revoked, or ineligible.
2. `SelfRouteOnly` rejects the same provider despite ownership and
   `minTrust = TrustNone` on the legacy path.
3. `PreferOwner` does not select an App Attest-ineligible owned provider and may
   fall back only to another currently eligible provider.
4. Dispatch-plan commit and reservation recheck repeat the App Attest predicate
   after locks are acquired.
5. Request resealing uses the same current connection and endpoint binding that
   passed authorization.
6. A reconnect cannot reuse the prior connection's eligible observation.
7. A provider that becomes revoked between candidate selection and commit is
   rejected before protected work is sent.

Because the assumed fleet is macOS 27, this report makes no compatibility
recommendation for older operating systems. It requires the same App Attest
authorization for public, self-route, and prefer-owner protected traffic.
