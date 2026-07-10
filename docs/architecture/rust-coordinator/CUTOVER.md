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

### Account bind + gated digests (DECISIONS #24 / #31)

Money-moving CTEs and `mark_start_authorized` require
`inference_jobs.account_id = caller`. Digest and op-key inserts are gated so a
failed settle cannot pin a terminal digest or poison an operation key.

### Terminal ingest attempt drift (DECISIONS #25)

`ingest_terminal` / `lookup_sql` prefer `(attempt_id, digest)` then fall back
to digest-only so empty or drifted attempt_id at settle still ACKs.
Go `ownership.IngestTerminal` mirrors this via optional `DigestTerminalLookup`.

### Reserve SQL job-first + op-first (DECISIONS #26 / #33)

`reserve_sql` claims `financial_operations` from an eligible row, then inserts
the job and debits only when the op claim succeeded. Orphaned op claims (job
conflict) are deleted in-statement via `cleanup_op`. The same op-first pattern
applies to settle / settle_capped / force_settle / release / resize / mark_start.

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

### Critical outbox enqueue (DECISIONS #32)

Money side effects (`billing.deposit_applied`, `inference.settled`) use
`Outbox::enqueue_critical`, which extends past the bounded capacity so a full
queue cannot silently drop the entry. Quiescence still blocks on overflow.

### Op-key parameter bind (DECISIONS #34)

`MemoryLedger` records op type/job/account/amount/digest/cap per operation key.
Identical replay is idempotent; mismatched reuse is Conflict.

### Outbox claim until ack (DECISIONS #35)

`try_claim` moves entries to in-flight (SQL UPDATE-not-DELETE). Only `ack_done`
drops them; quiescence counts in-flight. The best-effort worker does not
auto-ack critical `billing.*` / `inference.*` kinds.

### Ownership heartbeat fence (DECISIONS #36)

`LocalOwnershipStore` CAS-acquires and heartbeats (SQL analogue). The heartbeat
loop releases the Gate on steal/mismatch so chat/deposits/terminal-ingest return
`ownership_lost`. SQLx replaces the local store with durable SQL.

### Deposit/settle/release SQL outbox atomicity (DECISIONS #37 / #38 / #43)

Durable `deposit_sql` enqueues `billing.deposit_applied` gated on credit+op.
`settle_sql` / `settle_capped_sql` / `force_settle_sql` enqueue `inference.settled`
gated on mark. `release_sql` enqueues `inference.released` gated on mark+credit
so money and the side effect commit in one transaction.

### Admin force-settle HTTP (DECISIONS #39)

`POST /v1/admin/force-settle` clears start_authorized held jobs after ops review
(ownership + pilot key). Idempotent replay returns `already_terminal`. Critical
outbox enqueue keeps quiescence blocked until drain.

### Admin recover-undispatched HTTP (DECISIONS #40)

`POST /v1/admin/recover-undispatched` releases reserved-not-started jobs.
start_authorized jobs are skipped — use force-settle instead. Critical
`inference.released` outbox enqueue keeps quiescence blocked until drain.


### Admin held-review HTTP (DECISIONS #41)

`POST /v1/admin/held-review` classifies start_authorized holds without moving
money. Use force-settle to clear after ops review.

### Disposition-first recovery (DECISIONS #42)

`force_settle_held` / `recover_start_authorized_held` / `recover_undispatched`
(and admin HTTP mirrors) check `job_disposition` before `funded_start` so a
disposed job is `AlreadyTerminal`, not `Skipped`. Shared classifier:
`classify_held_job`.

### Release SQL outbox atomicity (DECISIONS #43)

`release_sql` inserts `inference.released` into `rust_coord.outbox` gated on
successful mark+credit. Process-local paths use `Outbox::enqueue_released` /
`release_job_with_outbox` for admin recover, chat prepare-fail/timeout,
resize-authorize failure, and pre-start cancel so refunds cannot silently lose
their durable side effect.

### Live settle requires provider terminal (DECISIONS #44)

Live prepare/start must wait for a real `provider_terminal` (pending-buffer
safe). Timeout or missing `terminal_digest` leaves the reservation
`start_authorized` held for force-settle — the coordinator must never invent a
mock charge/digest on the live path.

### Terminal ingest job bind (DECISIONS #45)

Terminal dispositions are job-bound (Rust `MemoryTerminalStore` and Go
`ownership.TerminalDisposition`). Replay with a known digest but the wrong
`job_id` returns `disposition=conflict` — never a settled ACK and never a late
record that could confuse ops.

### Deposit payload param bind (DECISIONS #46)

Stripe/external deposit event ids bind a payload digest over
account/amount/withdrawable. Identical replay is a no-op; mismatched params
return Conflict (HTTP 409 `deposit_payload_conflict`) and never double-credit.
`deposit_sql` / `observe_sql` document a mismatch CTE before credit. Go
`ApplyStripeDeposit` (memory + Postgres) likewise errors on
account/amount/external_id mismatch for a known `event_id`.

### Money-boundary ownership fence (DECISIONS #47)

Ownership is re-asserted immediately before reserve, resize_authorize, settle,
release, and pre-start cancel release (not only at route entry). After fencing
loss, release is refused so a stolen coordinator cannot refund or settle
mid-flight work.

### Live terminal binding validate (DECISIONS #48)

Live settle requires a `provider_terminal` whose job/attempt/lease/epoch/nonce/
digest bind to the funded attempt, with non-negative token counts. Invalid
terminals leave the reservation held for force-settle.

### Stream settle after checkpoint (DECISIONS #49)

Streaming chat defers settlement until after the bounded chunk pipe updates
`ChunkCheckpoint`. Billable tokens are `min(provider_claim, content_len/4)` so
an inflated `completion_tokens` cannot overcharge past accepted content.

### Settle SQL writes lease_id (DECISIONS #50)

Durable settle/force_settle CTEs persist `lease_id` on `provider_terminals`
alongside attempt/digest so late ingest and audit can bind the funded lease.

### Settle SQL writes se_signature (DECISIONS #51)

The same CTEs persist `se_signature` (empty when absent) so Go rollback
terminal ingest can surface attestation material without moving money again.

### Job fencing epoch bind (DECISIONS #52)

Jobs bind the coordinator fencing epoch at reserve (`bind_fencing_epoch` /
`reserve_sql` `$5`). Later settle/release/resize paths call
`require_fencing_epoch` (and SQL guards `coordinator_epoch = $N OR 0`) so a
re-acquired coordinator with a new epoch cannot mutate an older job's money.

### Terminal ingest lease/SE bind (DECISIONS #53)

`MemoryTerminalStore.record_bound` (and Go `TerminalDisposition`) persist
`lease_id` + `se_signature` alongside `job_id`. Replay ingest with a known
digest but mismatched lease or SE signature returns `disposition=conflict`
and never settles or records late. `lookup_sql` binds `$4`/`$5`. Chat settle
records dispositions via `record_bound` so rollback ACK is lease-bound.

### Live settle ownership steal hold (DECISIONS #54)

If ownership is released after live `start` but before settle (stream or
non-stream), the chat path returns `ownership_lost` and leaves the reservation
`start_authorized` held. Never charge after a mid-flight fencing loss — even
when the in-process chunk checkpoint already advanced.

### Atomic reserve+epoch bind (DECISIONS #55)

Chat reserves via `reserve_with_epoch` so `fencing_epoch` is set in the same
critical section as the debit. Idempotent op-key replay with a mismatched
epoch is `OwnershipLost`. No unbound (`fencing_epoch=0`) window after a
successful funded reserve under an active coordinator.

### Fenced money API wrappers (DECISIONS #56)

Ledger money mutations used by HTTP go through `*_fenced` wrappers that call
`require_fencing_epoch` before settle/release/resize/mark_start. Route-entry
ownership checks remain, but a forgotten check cannot move money after an
epoch steal — the ledger itself refuses with `OwnershipLost`.

### Live SE signature on disposition (DECISIONS #57)

Live `provider_terminal.se_signature` is persisted on the terminal disposition
via `record_bound`. Replay ingest with a mismatched SE signature returns
`disposition=conflict` (never settled ACK).

### Force-settle records disposition (DECISIONS #58)

Admin `force-settle` persists a `force_settled` disposition via `record_bound`
so a reconnecting provider's terminal ingest ACKs without recording late.

### Fenced recovery helpers (DECISIONS #59)

`force_settle_held_fenced` / `recover_undispatched_fenced` refuse with
ownership loss when the job's fencing epoch does not match. Legacy unfenced
wrappers pass epoch `0` (safe only for unbound jobs). CLI demos bind epoch
at reserve time.

### Release records disposition (DECISIONS #60)

`release_job_with_outbox` (recover-undispatched, prepare-fail, pre-start cancel)
persists a `released` disposition with digest `release:{job_id}` so releases
are auditable and terminal-ingestable.

### Cancel release records disposition (DECISIONS #61)

Pre-start cancel uses the shared `record_released_disposition` helper (same
digest as #60) when a terminal store is supplied, so cancel refunds are
ingestable like recover/prepare-fail releases.

### Admin force-settle via recovery core (DECISIONS #62)

`POST /v1/admin/force-settle` calls `force_settle_held_on` — the same core as
CLI/recovery — so disposition-first classification, fencing, and reservation
clamping cannot drift between HTTP and in-process recovery.

### Admin recover via recovery core (DECISIONS #63)

`POST /v1/admin/recover-undispatched` calls `recover_undispatched_on` then
persists `released` disposition + critical outbox. Classification and fencing
match CLI/recovery; side effects stay on the HTTP path.

### Deposit money-boundary holding re-check (DECISIONS #64)

`POST /v1/admin/deposits` re-asserts ownership holding immediately before
`apply_stripe_deposit`, matching other money-moving admin routes.

### Live wait aborts on ownership steal (DECISIONS #65)

Live chat `select!`s between `wait_terminal` and an ownership poll. If the
gate is released mid-wait, return `ownership_lost` and leave the reservation
`start_authorized` held — never settle after a mid-wait fencing loss.

### Adopt job fencing after re-acquire (DECISIONS #66)

After ownership re-acquire with a new epoch, orphaned jobs still bound to the
old epoch cannot be recovered/force-settled. `POST /v1/admin/adopt-job`
rebinds `fencing_epoch` to the current owner (no money move); ops then call
recover or force-settle.

### Prepare/start ownership watch (DECISIONS #67)

Live `prepare` and `start` waits also `select!` with `watch_ownership_lost`.
On steal: return `ownership_lost` and leave the job reserved (prepare) or
`start_authorized` held (start) for adopt + recover/force-settle.

### Admin cancel-attempt HTTP (DECISIONS #68)

`POST /v1/admin/cancel-attempt` sends a provider cancel for `start_authorized`
jobs and returns `cancelled_await_terminal` without moving money. Reserved
jobs are `skipped` — use recover-undispatched. Ops clear holds via
force-settle after terminal or review.

### Adopt fencing SQL docs (DECISIONS #69)

`adopt_fencing_epoch_sql` updates `inference_jobs.coordinator_epoch` only when
the caller holds `coordinator_ownership` and the job is not disposed. No
balance CTEs — money moves stay on recover/force-settle after adopt.

### Prepare-steal adopt-recover e2e (DECISIONS #70)

When ownership is stolen during prepare, the reserved job stays bound to the
old fencing epoch. Ops re-acquire, `POST /v1/admin/adopt-job`, then
`POST /v1/admin/recover-undispatched` to refund. `MemoryLedger::active_job_ids`
supports orphan discovery.

### Start-steal adopt-force-settle + quiescence ids (DECISIONS #71)

Same orphan path after start-wait steal: adopt then force-settle. Quiescence
includes `active_job_ids` so cutover ops can list reserved/held orphans without
ledger internals.

### Bulk adopt-jobs (DECISIONS #72)

`POST /v1/admin/adopt-jobs` rebinds all active jobs (or an explicit `job_ids`
list) to the current fencing epoch. Quiescence remains readable without
ownership and lists `active_job_ids` for discovery after steal.

### Wait-steal adopt-force-settle e2e (DECISIONS #73)

After ownership steal during `wait_terminal`, ops discover the orphan via
quiescence `active_job_ids`, bulk-adopt, then force-settle. SQL:
`adopt_all_fencing_epoch_sql`.

### Stream wait-steal + adopt-jobs edges (DECISIONS #74)

Stream=true wait-steal uses the same adopt→force-settle recovery. Bulk
`adopt-jobs` accepts explicit `job_ids` and reports per-id failures (disposed /
unknown) without aborting the batch; concurrent bulk adopt is idempotent.

### CLI adopt-recover demo (DECISIONS #75)

`darkbloom-coordinator recovery --confirm-same-release --demo-adopt-recover-job JOB`
reserves under epoch 1, shows recover under epoch 2 fails, adopts, then recovers.

### Quiescence detail + CLI adopt-force-settle (DECISIONS #76)

Quiescence includes `active_jobs_detail` with fencing epoch, funded_start, and
reserved amounts for orphan triage. CLI `--demo-adopt-force-settle-job` covers
the held-orphan adopt→force-settle path.

### needs_adopt + recover-undispatched-batch (DECISIONS #77)

When holding, quiescence sets `needs_adopt=true` on jobs whose fencing epoch
differs from the current owner. `POST /v1/admin/recover-undispatched-batch`
releases all reserved-not-started jobs (skips held); use after adopt-jobs.

### force-settle-batch (DECISIONS #78)

`POST /v1/admin/force-settle-batch` force-settles all held start_authorized
jobs (default `actual_micro_usd=0` = full refund). Ops flow for mixed orphans:
quiescence → adopt-jobs → recover-undispatched-batch → force-settle-batch.

### clear-orphans one-shot (DECISIONS #79)

`POST /v1/admin/clear-orphans` collapses that flow into one call: adopt all
active → recover reserved → force-settle held (default full refund). Prefer
for cutover drain after re-acquire; use stepwise endpoints for partial triage.

### CLI demo-clear-orphans (DECISIONS #80)

`recovery --demo-clear-orphans --confirm-same-release` dry-runs the same
pipeline in-process for operator rehearsal without HTTP.

### orphan_summary + clear-orphans race (DECISIONS #81)

Quiescence includes `orphan_summary` (`needs_adopt_count`,
`reserved_not_started_count`, `held_start_authorized_count`). Concurrent
`clear-orphans` is money-safe (exactly one release/settle per job). After
clear, critical outbox still blocks `ready` until acked — drain outbox before
cutover.

### Admin outbox-drain (DECISIONS #82)

`POST /v1/admin/outbox-drain` claim+acks all pending/in-flight outbox entries
(pilot cutover). Cutover sequence: clear-orphans → outbox-drain → quiescence
`ready=true`.

### Outbox-drain race + deposit/clear conservation (DECISIONS #83)

Concurrent outbox-drain acks each entry exactly once. Deposit during orphan
hold then clear-orphans refunds reservations atop the deposit (money conserved).

### Cutover e2e + charged clear-orphans (DECISIONS #84)

Proven path: steal → quiescence `needs_adopt` → clear-orphans → outbox-drain →
`ready=true`. Optional `actual_micro_usd` on clear-orphans charges held jobs
(clamped to reserved) instead of full refund.

### Clear-orphans mid-flight ownership fence (DECISIONS #85)

`clear-orphans` and batch recover/force-settle re-assert OwnershipGate before
each money-moving phase/job. Mid-flight steal returns 503 `ownership_lost`
with partial progress (`adopted`/`released`/`settled` counts) and does not
continue charging/refunding under a stolen fence.

### Quiescence cutover_hint (DECISIONS #86)

Quiescence includes `cutover_hint` so ops know the next drain step without
parsing orphan_summary manually.

### Resume after mid-flight abort (DECISIONS #87)

If clear-orphans aborts mid-flight on ownership steal, re-acquire ownership and
re-run clear-orphans → outbox-drain. Jobs already adopted keep fencing until
the new owner rebinds via adopt inside clear-orphans. `drain_ack_all_sql`
documents the durable outbox drain CTE.

### Per-job account on clear/batch (DECISIONS #88)

clear-orphans and batch recover/force-settle refund/charge the job's own
`account_id` (not a single caller account). Optional request `account` filters
to that owner only — prevents silent no-ops when pilot account ≠ job owner.

### Single-job admin defaults to job owner (DECISIONS #89)

`POST /v1/admin/recover-undispatched` and `POST /v1/admin/force-settle` resolve
the job's `account_id` when `account` is omitted. An explicit mismatched
`account` returns 409 `account_mismatch` (never refunds/charges the wrong
ledger).

### Deposit vs clear-orphans conservation (DECISIONS #90)

Concurrent Stripe deposits and clear-orphans conserve money: each deposit
event applies once; reserved/held orphans clear exactly once; final balance
equals start + sum(deposits).

### held-review-batch + cutover-drain (DECISIONS #91)

`POST /v1/admin/held-review-batch` classifies held jobs without moving money.
`POST /v1/admin/cutover-drain` is the one-shot ops path: clear-orphans →
outbox-drain → `ready` (aborts without drain if clear returns non-OK).

### cutover-drain abort on steal (DECISIONS #92)

If ownership is stolen mid clear-orphans inside cutover-drain, the response is
the clear abort (503) and outbox is left untouched. Quiescence `cutover_hint`
is `cutover-drain` whenever active jobs remain.

### Resume cutover-drain + concurrent race (DECISIONS #93)

After a mid-flight cutover-drain abort, re-acquire ownership and re-run
cutover-drain to reach `ready`. Concurrent cutover-drain calls clear orphans
exactly once and leave outbox empty.

### CLI cutover-drain + deposit race (DECISIONS #94)

`recovery --demo-cutover-drain --confirm-same-release` dry-runs clear+outbox
drain. Concurrent deposits and cutover-drain conserve money (balance = start +
deposits; outbox empty).

### Multi-account + charged cutover-drain (DECISIONS #95)

cutover-drain uses per-job `account_id` for money moves. Optional
`actual_micro_usd` charges held jobs. Optional `account` filter scopes owners;
foreign orphans remain and `ready` stays false until a full (unfiltered) drain.

### Batch recover/force mid-flight steal (DECISIONS #96)

`recover-undispatched-batch` and `force-settle-batch` re-assert OwnershipGate
before each job. A steal after the first money move returns 503 and leaves
remaining orphans for adopt + cutover-drain.

### Batch abort partial + cutover resume (DECISIONS #97)

Batch abort responses include partial `settled`/`released` counts and amounts.
Ops re-acquire ownership and run cutover-drain to clear the remainder.

### Batch abort remaining ids + deposit/force race (DECISIONS #98)

Batch abort also returns `remaining_active_job_ids` /
`remaining_held_start_authorized_job_ids` for orphan discovery. Concurrent
deposits and force-settle-batch conserve money (exactly one settle; balance =
start + deposits).

