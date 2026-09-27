# App Attest live-dispatch authorization gap

> Last updated: 2026-09-15 · commit `605651bb9`

Review of the v0.9.4 App Attest authorization boundary. Durable prospective
verdict events exist, but the coordinator has no authoritative authorization
object tied to the live provider connection and re-evaluated at dispatch. If
enforcement merely accepts an archived `eligible` event, this security gap
remains after enforcement is enabled.

## Scope and conclusion

This review assumes every provider has moved to macOS 27 and can supply the
required Apple measurements. Older-macOS compatibility is outside this
finding. The reviewed source is the exact v0.9.4 release commit
`605651bb95d71c1da9bb122107925143e9441973`.

The finding is an enforcement blocker, not a claim of a current bypass. In
v0.9.4, App Attest runs in shadow mode and does not change trust or routing.
Turning on a gate does not by itself supply the missing live authorization
boundary. The gate must evaluate the current connection and endpoint against
current policy state at the point that protected work is dispatched.

## Evidence

| Evidence in v0.9.4 | What it establishes |
|---|---|
| `coordinator/appattest/authorization.go:8-13` (`AuthorizationBinding`) | The intended binding includes account, machine, credential, connection, endpoint, app and environment. Its comment explicitly says the binding belongs to one live connection and that a persisted eligible verdict is not a reusable lease. |
| `coordinator/api/app_attest_shadow_policy.go:13-18` (`observeBuildPolicy`) | The prospective evaluation binds `Connection` to the shadow session ID `x.id` and `Endpoint` to the current provider public key. |
| `coordinator/api/app_attest_shadow_policy.go:23-55` (`observeBuildPolicy`) | Release-catalog, revocation and receipt readiness are snapshots read while processing a successful assertion. |
| `coordinator/api/app_attest_shadow_exchange.go:161-175` (`handleExchange`) | `assertionAt` is updated in the in-memory shadow session, then `observeBuildPolicy` computes one prospective verdict. |
| `coordinator/api/app_attest_shadow_observation.go:55-79` (`observe`) | A `prospective_policy` observation, including `valid_until`, is written through `RecordAppAttestEvent`. |
| `coordinator/store/machine_inventory_schema.go:30-35` (`app_attest_shadow_events`) | Prospective observations are durable audit events indexed by provider session and time. |
| Production search for `GetAppAttestReadiness` and `EvaluateAuthorization` | At this commit, readiness and authorization evaluation occur only in the shadow policy path. The registry selection and dispatch paths do not perform either check. |

The durable event is therefore useful evidence, but it is not an authoritative
current authorization. Its `session_id`, `shadow_session`, `assertion_at` and
`valid_until` fields describe the observation that was made. Reading that row
later does not prove that the provider object selected for a request is the
same live connection, still controls the same encryption endpoint, or still
satisfies the current revocation and release catalogs.

Honoring `valid_until` limits reuse to at most the remaining verdict lifetime;
it does not restore connection or endpoint binding. Ignoring `valid_until`
would make the flaw unbounded, but expiry alone is not the fix.

## Failure after enforcement

A vulnerable enforcement implementation can take the following path:

1. A macOS 27 provider produces a valid assertion on connection A and the
   coordinator archives an `eligible` prospective event.
2. Connection A closes, changes endpoint, or ceases to satisfy a current
   revocation or release-catalog decision.
3. A dispatcher selects connection B or a changed provider object and consults
   the archived event as an eligibility cache.
4. Protected traffic is dispatched without proving that the selected live
   connection is the one authorized by the assertion.

The enforcement switch is active in that scenario, but it enforces stale audit
state rather than the live connection invariant.

## Required remediation

Enforcement needs a connection-owned authorization state in the live provider
registry. After a verified assertion, the coordinator may construct or replace
that state only when every binding field matches the registered connection. At
selection and again immediately before sealing or sending protected traffic,
the coordinator must:

1. compare the authorization's provider/connection identity and endpoint with
   the selected live provider;
2. reject anything except exact `eligible` policy output;
3. reject expired assertion, receipt or renewal deadlines using the current
   time;
4. apply current revocation and release-catalog state, through a current lookup
   or an invalidation mechanism with equivalent fail-closed semantics; and
5. discard the authorization when the connection closes, the endpoint changes,
   the credential changes, or any required state becomes unknown.

`app_attest_shadow_events` remains an append-only audit trail. Routing must not
read it as an eligibility cache.

## Acceptance criteria

- A provider cannot reuse an eligible event from an earlier connection, even
  when account, machine and App Attest credential are unchanged.
- Changing only the provider encryption endpoint makes the live authorization
  unusable before protected traffic is sealed or sent.
- Disconnecting a provider removes its connection-owned authorization.
- Revoking the key or removing its approved build invalidates dispatch without
  waiting for the next assertion.
- Expiry is evaluated from the current clock at dispatch; a previously eligible
  object fails closed after its earliest deadline.
- A store outage or policy lookup failure produces no protected dispatch.
- A regression test inserts a plausible archived `eligible` event and proves
  that it cannot authorize a live provider by itself.
- Tests exercise both ordinary selection and all owner/self-route dispatch
  paths, so no alternate protected route omits the gate.

## Validation limits

This is a source review. It does not change production behavior, enable App
Attest enforcement, or claim that the archived event is currently used for
routing. It identifies the boundary the enforcement implementation must add
before shadow observations become authoritative.
