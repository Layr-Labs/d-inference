# App Attest enforcement retry-freshness review

> Last updated: 2026-09-15 · commit `605651bb9`

Review of the macOS 27 App Attest refresh and recovery timings in v0.9.4.
Turning on enforcement does not correct these timings: the existing retry
ladder can leave a healthy provider without a fresh assertion after two
transient refresh failures, and a third failure schedules the next attempt an
hour later.

## Scope and conclusion

This review assumes every provider runs macOS 27, has an enrolled App Attest
key, and starts with a successful assertion. It evaluates the v0.9.4 behavior
that an enforcement gate would consume. The reviewed release records verdicts
in shadow mode, so the availability effect begins when protected dispatch
requires a current `eligible` verdict.

The defect remains after enforcement is enabled. Enforcement turns the
existing timing mismatch into lost serving eligibility; it does not change the
ten-minute refresh cadence, fifteen-minute freshness requirement, retry
delays, attempt spread, or response timeout.

## Evidence

| Mechanism | v0.9.4 behavior | Source |
|---|---|---|
| Normal refresh | A successful exchange resets the assertion timer to `shadowAssertionInterval = 10 * time.Minute`. | `coordinator/api/app_attest_shadow.go` (`shadowAssertionInterval`, `appAttestShadowSession.runAttempt`) |
| Freshness gate | `AssertionFreshness = 15 * time.Minute`; an assertion at or beyond that age produces `assertion_stale_or_missing`, and an eligible verdict expires at `AssertionAt + AssertionFreshness`. | `coordinator/appattest/authorization.go` (`AssertionFreshness`, `EvaluateAuthorization`) |
| Recovery ladder | Consecutive retryable failures wait one minute, five minutes, then one hour. A success resets the failure counter. | `coordinator/api/app_attest_retry.go` (`appAttestRetryDelay`, `appAttestShadowSession.runRecovering`) |
| Attempt spread | Every new `runAttempt` waits an integer 0–29 seconds before sending `prepare`. Recovery invokes `runAttempt` again, so this delay also applies to retries. | `coordinator/api/app_attest_shadow.go` (`appAttestShadowSession.runAttempt`) |
| Exchange timeout | A pending response can consume `shadowResponseTimeout = 90 * time.Second` before the attempt fails. | `coordinator/api/app_attest_shadow.go` (`shadowResponseTimeout`, `appAttestShadowSession.runAttempt`) |
| Retryable results | Timeouts, Apple availability results, key recovery results, and coordinator storage/send/verifier results all enter this ladder. | `coordinator/api/app_attest_retry.go` (`retryableAppAttestOutcome`) |
| Existing regression coverage | The recovery test fixes the observed sequence at one minute, five minutes, and one hour, but it does not compare those waits with assertion expiry. | `coordinator/api/app_attest_rollout_test.go` (`TestAppAttestRecoveryRotatesSessionAndReloadsWithoutDisconnect`) |

The lower-bound timeline requires no timeout or attempt-spread overhead:

| Time from last success | Event | Eligibility consequence |
|---|---|---|
| `00:00` | Assertion succeeds. | Eligible until `15:00`. |
| `10:00` | Scheduled refresh fails immediately. | First retry is scheduled for `11:00` or later. |
| `11:00` | First retry fails immediately. | The next retry waits five minutes. |
| `15:00` | The last success reaches the freshness boundary. | `EvaluateAuthorization` returns `unknown`. |
| `16:00` | Earliest next attempt starts, before its additional 0–29 second spread is included. | The provider has already been ineligible for at least one minute. |
| After a third failure | Recovery waits one hour. | The stale interval extends for roughly another hour, plus spread and exchange time. |

The exact outage begins sooner if enforcement replaces a still-fresh successful
verdict with `unknown` as soon as a transient refresh fails. A correct gate can
retain the last successful evidence until its `ValidUntil`, but even that
choice cannot close the timeline above.

## Post-enforcement impact

A healthy, correctly signed macOS 27 provider can lose protected work because
two refresh attempts encounter retryable failures. It recovers only after a
later assertion completes; the WebSocket can remain connected throughout.
Correlated coordinator or service failures can affect many providers at once,
but this review does not establish that one failure guarantees a fleet-wide
outage. One transient failure can recover within the remaining five-minute
margin.

The issue is high availability risk under enforcement because the policy's
freshness deadline is stricter than its own recovery schedule.

## Required remediation

1. Derive every retry deadline from the last successful assertion's
   `ValidUntil`. Never schedule a refresh attempt beyond that deadline while a
   provider still has valid evidence.
2. Reserve enough time for attempt spread and the 90-second response budget.
   The normal assertion cadence and retry budget must fit inside the
   fifteen-minute window with an explicit safety margin.
3. Retain a still-valid successful authorization through transient refresh
   failures. A transport or service failure is not negative attestation
   evidence.
4. After freshness expires, use a bounded rapid-recovery schedule rather than
   the one-hour probe for a connected provider that can answer assertions.
5. Keep failure attribution separate so coordinator backpressure does not
   consume a provider or credential failure budget.

## Acceptance criteria

- A fake-clock test begins with a successful assertion, injects retryable
  failures at the ten-minute refresh and first retry, then proves another
  attempt is scheduled and can complete before `ValidUntil`.
- The test includes the maximum 29-second attempt spread and 90-second response
  budget; no configured wait crosses the freshness deadline.
- A still-fresh successful verdict remains usable after a retryable refresh
  failure, while cryptographic rejection, binding mismatch, revocation, and
  expiry still fail closed.
- Three transient failures followed by recovery do not impose a one-hour
  ineligible interval on a connected healthy provider.
- An enforcement integration test dispatches protected traffic only with an
  exact live `eligible` result and restores eligibility immediately after the
  successful recovery assertion, without requiring reconnect.

## Verification limit

This is source and timing analysis at commit `605651bb9`. It does not claim an
observed production outage because App Attest was shadow-only at that commit.
The timeline is the behavior produced when enforcement consumes the existing
freshness rule without changing the recovery implementation.
