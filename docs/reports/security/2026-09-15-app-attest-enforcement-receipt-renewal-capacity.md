# App Attest enforcement receipt-renewal capacity review

> Last updated: 2026-09-15 · commit `605651bb9`

The v0.9.4 receipt-renewal path has a fixed per-coordinator throughput ceiling
that enforcement does not repair. This review assumes every provider has moved
to macOS 27 and therefore isolates renewal capacity from unsupported-OS policy.
Fail-closed enforcement turns a renewal backlog older than 24 hours into lost
protected-serving capacity even when the affected Macs and App Attest keys are
otherwise healthy.

## Scope and conclusion

One `appAttestReceiptWorker` runs in each coordinator process. It takes at most
one job on each one-second tick and completes that job synchronously before it
can receive another tick. The theoretical ceiling is therefore 86,400 renewal
attempts per day per coordinator replica. Apple or database latency, operation
timeouts, and retries make sustainable throughput lower.

This is a capacity defect for an enforced rollout, not evidence of a universal
86,400-provider fleet limit. PostgreSQL leases and `FOR UPDATE SKIP LOCKED`
allow multiple coordinator replicas to claim different jobs, so aggregate
capacity can scale horizontally. The unsafe condition is an oldest-due backlog
that reaches 24 hours under the deployed replica count and observed Apple
latency.

## Source evidence

| Claim | Evidence at the reviewed commit |
|---|---|
| Exactly one renewal loop starts per coordinator process | `coordinator/api/app_attest_receipt_worker.go:22-36` (`startAppAttestReceiptWorker`) creates one worker goroutine when receipt credentials are configured. |
| The worker admits at most one attempt per second | `coordinator/api/app_attest_receipt_worker.go:30-35` creates a one-second ticker; `appAttestReceiptWorker.run` at lines 55-78 handles one claim synchronously for each received tick. |
| Service latency reduces realized throughput | `appAttestReceiptWorker.run` wraps one attempt in a 30-second operation; `renewAppAttestReceipt` uses the supplied HTTP client, configured with a 20-second timeout. While that attempt is running, the loop cannot claim another job. |
| Receipt scheduling comes from verified Apple receipt data | `coordinator/api/app_attest_receipt.go:35-66` (`verifyReceiptRecordMode`) records `ExpiresAt` and sets `NextAt` from the verified receipt's `NotBefore`, with a one-minute lower bound. |
| More replicas can divide due work | `coordinator/store/postgres_app_attest_receipts.go:34-58` (`ClaimAppAttestReceipt`) orders due jobs and claims one with `FOR UPDATE SKIP LOCKED`, then writes a two-minute lease. |
| A late renewal removes readiness | `coordinator/appattest/authorization.go:116-129` (`EvaluateAuthorization`) returns `unknown` when the receipt is invalid or expired, renewal is unconfigured, the risk metric is absent, or `ReceiptRenewAt + 24h` is no longer in the future. |
| Enforcement does not add renewal capacity | Authorization only consumes the stored receipt state. It does not change the worker count, claim cadence, Apple-request concurrency, or backlog age. |

At the theoretical maximum:

```text
1 attempt/second × 86,400 seconds/day = 86,400 attempts/day/replica
```

That arithmetic counts attempts rather than successfully refreshed keys. A
slow request occupies the only worker, and failed attempts are rescheduled, so
the required deployed capacity must be based on measured completion latency and
error rates rather than this upper bound.

## Enforcement impact

Enforcement should admit protected traffic only for an exact `eligible`
authorization result. Once the oldest due job exceeds the 24-hour readiness
allowance, `EvaluateAuthorization` produces `unknown`. The provider then loses
protected-serving eligibility until a successful renewal restores current risk
receipt data.

The failure is coordinator-side availability loss. It does not show that the
provider forged an assertion, that macOS 27 App Attest failed, or that
enforcement accepted stale evidence. Fail-closed enforcement behaves correctly
for the evidence it sees; the renewal pipeline failed to supply that evidence
on time.

## Remediation

1. Replace the single synchronous loop with bounded configurable concurrency,
   while retaining one active lease per key and respecting measured Apple
   service limits.
2. Export due, leased, succeeded, retried, and failed job counts together with
   oldest-due age and renewal completion latency. Alert well before oldest-due
   age approaches 24 hours.
3. Size worker concurrency or replica count from the observed renewal arrival
   rate, Apple latency, failure rate, and explicit headroom. Do not use 86,400
   successful renewals/day as the capacity estimate.
4. Retain the fail-closed readiness deadline. Coordinator overload must be
   repaired by supplying renewal capacity rather than treating stale risk data
   as current.
5. Use failure-class-aware backoff so an Apple outage does not create a tight
   retry storm, and so local storage failures are visible separately from Apple
   rejections.

## Acceptance criteria before enforcement

- A load test seeds more than one renewal interval's expected fleet demand and
  uses a delayed mock Apple service. At the production replica and concurrency
  settings, oldest-due age remains below a documented SLO with rollout
  headroom.
- Increasing coordinator replicas or configured worker concurrency increases
  successful completion throughput as predicted until the configured Apple
  limit is reached.
- Concurrent replicas never renew the same key simultaneously; lease expiry
  recovers a worker that dies while holding a claim.
- Metrics and alerts expose queue depth, oldest-due age, attempt latency,
  success rate, and failures by fault domain.
- A policy test proves that a receipt more than 24 hours past `NextAt` remains
  non-eligible, while a successful refresh restores eligibility.
- The enforcement rollout checklist records measured daily renewal capacity,
  current key count, expected renewal cadence, replica count, and minimum
  headroom. A macOS 27-only fleet does not waive this gate.

## Review boundary

This source review establishes the serial worker, the per-replica upper bound,
horizontal claim semantics, and the fail-closed consequence. It does not
measure Apple's production latency or rate limits, the deployed coordinator
replica count, fleet renewal distribution, or current backlog age. Those
operational measurements are required to quantify when the defect becomes an
outage.
