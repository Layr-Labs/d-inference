# Production Cutover & Rollback (Milestones 7–8)

**Human-gated.** Agents must not deploy to EigenCloud / mutate prod.

## Prerequisites (architecture §24)

1. MicroMDM extracted to independently supervised service
2. Same-zone Postgres (or coordinator co-located with DB) meeting §16 budgets
3. Additive `rust_coord` migrations applied; no startup DDL pending
4. Rollback-safe Go image understands `rust_coord` + ownership epoch
5. Distinct Go/Rust ports; Caddy can switch consumer / provider WS / MDM independently
6. Encryption KID identical between Go and Rust

## Cutover sequence (serial)

1. Freeze Go fallback + Rust image digests
2. Confirm migrations/indexes applied
3. Capture baselines (capacity, TTFT, balances, Stripe, trust)
4. Freeze releases/models/enrollment/payouts/admin mutations
5. Drain Go; poll `/v1/admin/quiescence` to zero
6. Close Go sessions; release coordinator epoch; stop Go
7. Keep MicroMDM running
8. Start Rust passive; verify schema/secrets/KID
9. Acquire Rust epoch; enable provider WS + MDM callbacks first
10. Wait for trust/capacity thresholds
11. Switch Caddy consumer routes to Rust
12. Smoke plaintext+sealed, stream+non-stream
13. Unfreeze reads → inference → models → admin → Stripe

## Immediate rollback triggers

- Duplicate/unexplained money
- Plaintext/invalid encrypted provider traffic
- <90% model capacity after 5m / <95% aggregate after 10m
- 5xx +0.25pp for 5 consecutive minutes
- Fleet-wide MDM/APNs spike
- FleetActor / terminal worker / reconcile invariant failure

## Normal rollback (§26.1)

1. Drain Rust; quiescence to zero including fee-projection backlog
2. No `review_pending` rows; every external intent Go-reconcilable
3. Release Rust epoch; start rollback-safe Go passive
4. Acquire Go epoch; provider WS first, then consumer
5. Do **not** restore PostgreSQL for normal rollback

## Emergency

Use same-release Rust `recovery` subcommand/image — not an arbitrary older image.
Go must not serve new paid traffic over active Rust jobs unless explicitly fenced.

### Held start_authorized jobs (DECISIONS #16–17)

After a provider `start` failure post-`start_authorized`, the reservation is
**held** (not released). Quiescence reports:

- `held_start_authorized` — count
- `held_start_authorized_job_ids` — job IDs

Ops dry-runs (in-memory):

```bash
# Classify without moving money
darkbloom-coordinator recovery --confirm-same-release --demo-held-job JOB

# Force-settle a review amount and clear the hold
darkbloom-coordinator recovery --confirm-same-release --demo-force-settle-job JOB

# Idempotent Stripe deposit apply (DECISIONS #22)
darkbloom-coordinator recovery --confirm-same-release --demo-deposit-event evt_id
```

Production force-settle uses `force_settle_held` against Postgres once SQLx is
wired. Do **not** call `release` on start_authorized jobs.

### Deposit kill-boundary (DECISIONS #22)

`apply_stripe_deposit` validates amounts **before** consuming the
`(source, event_id)` key. If credit still fails after observe, `forget`
restores the key so a retry can succeed. Durable shape: `deposit_sql()`.

### Stream settle clamp (DECISIONS #23)

`settle_capped` charges `min(actual, billable_cap, reserved)`. Ops
`force_settle_held` uses the same clamp so an over-sized review amount
never fail-closes a held job. SQL: `settle_capped_sql()` / `force_settle_sql()`.

### Account bind + gated digests (DECISIONS #24)

Money-moving CTEs require `inference_jobs.account_id = caller`. Digest and
op-key inserts are `INSERT … SELECT … FROM guard|charge|calc` so a failed
settle cannot pin a terminal digest or poison an operation key.

### Terminal ingest attempt drift (DECISIONS #25)

`ingest_terminal` / `lookup_sql` prefer `(attempt_id, digest)` then fall back
to digest-only so empty or drifted attempt_id at settle still ACKs.
Go `ownership.IngestTerminal` mirrors this via optional `DigestTerminalLookup`.

### Reserve SQL job-first (DECISIONS #26)

`reserve_sql` inserts the job before debiting; debit/op only run when the job
row is newly created — job_id conflict never drains balances.

### Force-settle disposition (DECISIONS #27)

Ops force-settle records disposition `force_settled` (distinct from `settled`)
in both MemoryLedger and SQL for audit.

### Deposit forget SQL (DECISIONS #28)

Durable `forget_sql` deletes the external_events row only when no
`deposit:source:event_id` financial_operations row exists. `deposit_sql`
inserts that op key on successful credit so forget cannot undo a landed deposit.

### Outbox blocks quiescence (DECISIONS #29)

Quiescence `ready` requires `outbox_retryable == 0`. Deposit enqueue (and
requeue after failed delivery) keeps the coordinator not-ready until drain.

### Quiescence without ownership (DECISIONS #30)

`/v1/admin/quiescence` stays readable when not holding so cutover ops can
observe drain state (`ownership_holding=false`). Mutating admin routes
(deposits, terminal-ingest) still require ownership.
