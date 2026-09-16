# App Attest enforcement coordinator-backpressure review

> Last updated: 2026-09-15 · commit `605651bb9`

Review of how v0.9.4 attributes coordinator-side App Attest failures during a
macOS 27 rollout. Turning on enforcement does not correct the attribution:
verifier, storage, archive-write, and outbound-send failures consume the same
provider recovery ladder as assertion failures and can make healthy providers
lose eligibility.

## Scope and conclusion

This review assumes every provider runs macOS 27 and protected dispatch accepts
only a current App Attest `eligible` verdict. The reviewed release records
verdicts in shadow mode, so verifier and storage refusals do not yet remove
serving capacity. That containment ends if enforcement consumes the existing
outcomes without changing recovery.

The defect remains after enforcement is enabled. Enforcement gives the
existing coordinator-local outcomes an availability consequence; it does not
add queueing, fair admission, fault-domain-specific retry state, or a recovery
schedule bounded by assertion freshness.

## Evidence

| Outcome | Origin in v0.9.4 | Why it is not negative attestation evidence |
|---|---|---|
| `verifier_busy` | `appAttestShadowSession.runAttempt` uses a non-blocking send to `Server.appAttestShadowSlots`; a full channel rejects the reply before verification. `NewServer` creates four slots per coordinator process. | No proof has failed verification. The coordinator declined to run it. |
| `storage_busy` | `appAttestShadowSession.acquireStorage` uses a non-blocking four-slot channel per coordinator process. `appAttestShadowSession.handle` stops when no permit is available. | The proof is rejected by local admission before its archive/verification path completes. |
| `write_failed` | `appAttestShadowSession.handle` sets this result when `BeginAppAttestEvidence` fails. | The archive write failed; the provider's assertion was not shown invalid. |
| `send_failed` | `appAttestShadowSession.send` sets this result when the coordinator cannot enqueue the control message to the provider. | The coordinator-to-provider control path failed before assertion evaluation. |

All four values are retryable in
`coordinator/api/app_attest_retry.go` (`retryableAppAttestOutcome`).
`appAttestShadowSession.runRecovering` therefore advances the same one-minute,
five-minute, then one-hour ladder defined by `appAttestRetryDelay`.

The concurrency bounds are independent and local to each coordinator process:

- `coordinator/api/server.go` (`NewServer`) creates four verifier slots.
- `coordinator/api/app_attest_shadow_storage.go`
  (`appAttestShadowSession.acquireStorage`) lazily creates four storage slots.
- `coordinator/api/app_attest_shadow_storage_test.go`
  (`TestAppAttestStorageBoundsBusyAndStoppedSessionsThroughCompletion`) proves
  excess work is refused while four archive operations are held.
- `coordinator/api/app_attest_rollout_test.go`
  (`TestAppAttestSendFailureSchedulesFreshRecovery`) proves `send_failed`
  enters the provider recovery path.
- `coordinator/api/app_attest_enrollment_retry_test.go`
  (`TestAppAttestCompletionFailureReentersRecovery`) proves a storage completion
  failure enters that recovery path.

## The two jitter mechanisms are different

The App Attest path waits an integer 0–29 seconds at the start of every
`appAttestShadowSession.runAttempt`. This spreads initial and recovery attempts,
but it does not reconnect the provider and does not queue work when either
four-slot pool is full.

The provider's WebSocket reconnect loop is separate.
`provider-swift/Sources/ProviderCore/Coordinator/ExponentialBackoff.swift`
(`ExponentialBackoff.nextDelay`) uses equal jitter over half-to-full of an
exponential delay, starting at 0.5–1 second and capped at 15–30 seconds.
`provider-swift/Sources/ProviderCore/Coordinator/CoordinatorClient+Connection.swift`
(`CoordinatorClient.runLoop`) applies it after connection failures. The App Attest
recovery comment and implementation explicitly retry without disconnecting, so
the WebSocket reconnect jitter cannot be credited as protection for these
four-slot refusals.

## Post-enforcement impact

A coordinator restart or another synchronized cohort can produce more than
four near-concurrent proof replies or storage operations. Excess work fails
immediately instead of waiting for capacity. Providers that collide again on
their retries advance to the five-minute and one-hour waits; once their last
assertions exceed the fifteen-minute freshness limit, exact-`eligible`
enforcement removes them from protected serving despite valid hardware,
software, and credentials.

The verified risk is correlated herd starvation and avoidable loss of serving
capacity. Per-attempt spread and multiple coordinator replicas reduce the
probability, while the four-slot limits preserve a hard per-process collision
point. This review does not establish a self-amplifying traffic loop in which
reduced inference capacity itself creates more App Attest verifier load.

## Required remediation

1. Classify verifier saturation, storage admission, archive-write failure, and
   outbound-send failure as coordinator/control-path failures. Do not increment
   provider, credential, or cryptographic-failure counters for them.
2. Replace immediate non-blocking refusal with bounded, fair admission whose
   wait is limited by the exchange and assertion-freshness deadlines. Preserve
   the four-worker execution bound if that is the measured safe capacity.
3. Retry coordinator-attributed failures with capacity-aware randomized delay
   inside the current assertion's validity window. Do not advance them to the
   one-hour provider probe.
4. Preserve the last successful authorization until its real `ValidUntil`.
   Coordinator backpressure cannot manufacture negative attestation evidence.
5. Emit distinct metrics for verifier saturation, storage saturation, archive
   failure, outbound control failure, provider response failure, and
   cryptographic rejection. Alerts and rollout gates must use those fault
   domains separately.

## Acceptance criteria

- A deterministic test occupies all four verifier slots, submits additional
  valid macOS 27 assertions, releases the slots, and proves every admitted
  connection receives a verification opportunity before assertion freshness
  expires.
- The same test exists for all four storage slots and proves the execution
  concurrency bound remains four while excess work waits or receives a
  capacity-aware retry.
- Injected `verifier_busy`, `storage_busy`, `write_failed`, and `send_failed`
  outcomes do not advance a provider or credential failure ladder and cannot
  schedule a one-hour wait.
- A still-fresh successful authorization remains eligible during those
  coordinator-attributed failures; expiry and actual negative evidence still
  fail closed.
- A restart-herd test with more than four providers and maximum timing overlap
  eventually verifies the entire cohort without reconnect and without stale
  gaps caused by repeated slot collisions.
- A separate reconnect test proves the Swift equal-jitter schedule applies only
  to WebSocket reconnection and is not assumed by App Attest recovery tests.
- Enforcement telemetry identifies the responsible fault domain and can block
  rollout when coordinator saturation would make the fleet ineligible.

## Verification limit

This is source and failure-path analysis at commit `605651bb9`. It does not
claim an observed production outage or a proven positive-feedback traffic
spiral. The availability consequence follows when enforcement makes the
existing prospective authorization outcome authoritative for protected
dispatch.
