# Coordinator cutover incident response

This runbook covers failures during the Rust pilot, canary, handoff, bake, or
Go-retirement window. Evidence collection is read-only. Any production drain,
traffic change, process stop/start, reviewed financial resolution, or rollback
is a human operation under the canonical deploy runbook.

## Prerequisites

- Identify the active gate and last valid signed authorization from
  [`coordinator-cutover.md`](coordinator-cutover.md).
- Identify the sole PostgreSQL ownership holder. Do not start a second
  coordinator or recovery process.
- Preserve the candidate image digest, pinned Go fallback digest, source
  reports, hashed logs, assessment, approval, and authorization.
- Have the production Datadog site and RDS read-replica credential files
  available. Do not use serving-process database credentials.

## Steps

1. Stop gate progression. Do not approve a new stage, change listener
   ownership, retire Go, or overwrite the failed evidence.
2. Collect a fresh signed `live_snapshot` for the current isolated, dedicated
   canary, or atomic production ownership mode.
   The collector uses only GET and PostgreSQL read-only operations
   (`scripts/cutover_readiness/clients.py` and
   `scripts/cutover_readiness/rds.py`).
3. Classify the stop:
   - ownership/readiness/checksum: preserve one owner and follow the serial
     handoff branch in `coordinator-deploy.md`;
   - `external_unknown`, review, terminal, outbox, fee, or projection count:
     do not replay or manually edit rows; let bounded recovery reconcile;
   - provider protocol/version/trust coverage: stop expansion and retain
     protocol-v1 fallback; never lower the hardware trust floor;
   - availability/latency/no-data: correlate the read-only Datadog result with
     `rust-coordinator-observability.md`;
   - stale, missing, future-dated, checksum-invalid, or unsigned evidence:
     treat the gate as unproven, not as a service failure.
4. If the candidate is already the owner and rollback is indicated, first
   require handoff drain and detailed quiescence. Run the pinned Go
   `rollback-check` exactly as described in `coordinator-deploy.md`. A nonzero
   rollback guard or failed check forbids fallback.
5. If the candidate cannot quiesce, leave it as the sole fenced/paused owner,
   preserve `/run/d-inference/automatic-rollback-refused`, and escalate. Never
   start Go concurrently.
6. After service recovery, restart the affected bake window from zero. Prior
   elapsed time is not credited across a gate incident or rollback.

## Verification

- Exactly one coordinator owns PostgreSQL and at most one serving container is
  running.
- `/readyz`, ownership health, schema versions/checksum, and supervisor state
  are conclusive.
- `external_unknown`, `review_pending`, `sent_unknown`, terminal conflict,
  external-event, outbox, fee, and fee-projection counts return to zero.
- Provider protocol counts equal total connected providers; every routed
  provider is at the minimum version and hardware trust floor.
- A replayed historical terminal receives its durable ACK before the incident
  is closed (`coordinator-rs/crates/server/src/pilot/provider.rs` and
  `crypto/terminal_store.rs`).
- A new assessment and new human approval are produced; the old authorization
  is retained as incident evidence, never edited.

## Rollback

Rollback means returning to the last explicitly approved isolated environment or the
metadata-pinned Go image through the serial handoff. It does not mean deleting
Rust durable state, reverting additive migrations, lowering provider protocol
or trust requirements, mutating evidence, or bypassing
`automatic-rollback-refused`. If Go `rollback-check` is unsafe, continue
bounded Rust recovery or a journaled reviewed resolution while Rust remains
the sole owner.

