# Rust Coordinator — Explicit Decisions

Status: active during migration  
Date: 2026-07-10

## Open decisions (§29) — locked for execution

| # | Decision | Choice |
| --- | --- | --- |
| 1 | Public consumer pricing | Provider-independent public price per model |
| 2 | Provisional reservation | Coordinator upper bound from request shape + max_tokens + model price |
| 3 | One-phase pre-funded fast path | Out of scope until property tests exist |
| 4 | Prepared-lease TTL / ACK | TTL 15s; abort/cancel ACK wait 5s |
| 5 | Internal queue | None for public/OpenRouter; 429 + Retry-After |
| 6 | Terminal journal | Encrypted local file, 10k entries / 64 MiB |
| 7 | Terminal canonicalization | Domain-separated canonical JSON + SE signature |
| 8 | Protocol-v2 fleet floor | Explicit capability flag (not semver) |
| 9 | DB placement | Same-zone Postgres required before Milestone 5 |
| 10 | Emergency Go before Rust reconcile | No |
| 11 | Prepare hedge | p95 prepare trigger; ETA miss vs remaining TTFT; 5% global budget |
| 12 | Binary payload header | Fixed 64-byte header + ciphertext |
| 13 | Half-open recovery admits | `AdmitRequest.allow_half_open_probe`; general traffic stays Healthy\|Suspect only |
| 14 | Sequential alternate after prepare expiry | At most **one** alternate; second PrepareExpired finalizes (no attempt ladder) |
| 15 | Job ID reuse | **Forbidden.** `MemoryLedger.reserve` / start_authorized reject existing or disposed `job_id` (new UUID per job) |
| 16 | Release after start_authorized | **Forbidden.** Must settle (or recovery-review); prevents refund of funded attempts |
| 17 | Force-settle held jobs | Ops-only `force_settle_held` / `--demo-force-settle-job`; charges review amount, clears hold |
| 18 | Resize + authorize | One-round-trip `resize_and_authorize` (MemoryLedger + documented SQL CTE) atomically adjusts reservation and marks `start_authorized`; idempotent on operation key |
| 19 | Ownership fencing | Process-local `OwnershipGate` mirrors Go `ownership.Gate`; refuse-on-rust + recovery mode; durable CAS against `coordinator_ownership` lands with SQLx |
| 20 | Outbox + external events | Process-local `Outbox` (SKIP LOCKED analogue) + `ExternalEventInbox` / `apply_stripe_deposit`; quiescence waits for retryable outbox drain |
| 21 | Terminal ingest | `ingest_terminal` ACKs known dispositions or records `late` — never double-settles (mirrors Go `ownership.IngestTerminal`) |
| 22 | Deposit kill-boundary | Validate amounts **before** `ExternalEventInbox.observe`; on post-observe credit failure call `forget` so the event id is not poisoned |
| 23 | Stream settle clamp | `settle_capped` charges `min(actual, billable_cap, reserved)` so a checkpoint/provider claim above the provisional reservation never fail-closes a hold |
| 24 | Account bind on money moves | `settle` / `release` / `resize_and_authorize` / `mark_start_authorized` / SQL CTEs require `inference_jobs.account_id = caller account`; mismatch is Conflict and does not poison op keys. Digest/op inserts are gated on successful guard/charge so failed settles cannot pin digests |
| 25 | Terminal ingest attempt drift | Lookup prefers `(attempt_id, digest)` then falls back to digest-only so empty/mismatched attempt_id at settle still ACKs without marking late |
| 26 | Reserve SQL job-first | `reserve_sql` inserts the job row before debiting; debit/op gated on successful insert so job_id conflict never drains balances |
| 27 | Force-settle disposition | Memory + SQL record disposition `force_settled` (distinct from normal `settled`) for audit |
| 28 | Deposit forget SQL | Durable `forget_sql` deletes the external_events row only when no `deposit:source:event_id` financial_operations row exists — pairs with deposit_sql op insert |
| 29 | Outbox blocks quiescence | Quiescence `ready` requires `outbox_retryable == 0`; deposit enqueue makes ready=false until claim+ack (or requeue keeps retryable) |
| 30 | Quiescence without ownership | `/v1/admin/quiescence` remains readable when not holding (reports `ownership_holding=false`) so cutover ops can observe drain; mutating admin routes still require holding |
| 31 | Mark-start account bind | `mark_start_authorized(job_id, account)` refuses wrong-account callers (Conflict); SQL binds `account_id = $2` so knowing a job id alone cannot advance the funded-start kill boundary |
| 32 | Critical outbox enqueue | Money side effects (`billing.deposit_applied`, `inference.settled`, `inference.released`) use `Outbox::enqueue_critical` which extends past the bounded capacity so a full queue cannot silently drop the entry; quiescence still blocks on the overflow |
| 33 | SQL op-key gates money | Durable ledger CTEs claim `financial_operations` **before** debit/credit/digest/mark; money CTEs require `EXISTS (SELECT 1 FROM op)`; orphaned op claims (digest/job conflict) are deleted in-statement via `cleanup_op` |
| 34 | Op-key parameter bind | `MemoryLedger` stores an `OperationRecord` (type/job/account/amount/digest/cap) per op key; identical replay is idempotent, mismatched reuse is Conflict — matches SQL row semantics |
| 35 | Outbox claim until ack | `try_claim` moves entries to in-flight (mirrors SQL UPDATE-not-DELETE); only `ack_done` drops them. Quiescence counts in-flight. Critical kinds are not auto-acked by the best-effort worker |
| 36 | Ownership heartbeat fence | `LocalOwnershipStore` CAS-acquires + heartbeats (SQL analogue); `run_ownership_heartbeat` releases the Gate on mismatch/steal so mutating routes return ownership_lost. SQLx swaps the store for durable SQL |
| 37 | Deposit SQL outbox atomicity | `deposit_sql` inserts `billing.deposit_applied` into `rust_coord.outbox` gated on credit+op so money and the durable side effect commit together (process-local path still uses enqueue_critical after apply) |
| 38 | Settle SQL outbox atomicity | `settle_sql` / `settle_capped_sql` / `force_settle_sql` insert `inference.settled` into `rust_coord.outbox` gated on `mark` so settlement and the durable side effect commit together |
| 39 | Admin force-settle HTTP | `POST /v1/admin/force-settle` (ownership + pilot key) clears start_authorized holds via settle_capped_as(`force_settled`); enqueues critical outbox; idempotent replay returns already_terminal |
| 40 | Admin recover-undispatched HTTP | `POST /v1/admin/recover-undispatched` releases reserved-not-started jobs; skips start_authorized (must use force-settle); enqueues critical `inference.released` outbox |
| 41 | Admin held-review HTTP | `POST /v1/admin/held-review` classifies start_authorized holds without moving money (`held_for_review` / `skipped` / `already_terminal`) |
| 42 | Disposition-first recovery | `force_settle_held` / `recover_start_authorized_held` / `recover_undispatched` (and admin mirrors) check `job_disposition` before `funded_start` so disposed jobs are AlreadyTerminal, not Skipped |
| 43 | Release SQL outbox atomicity | `release_sql` / admin recover-undispatched / chat prepare-fail / pre-start cancel insert `inference.released` into outbox (gated on successful mark/credit in SQL; `enqueue_released` / `release_job_with_outbox` in-process) so refunds and durable side effects commit together |
| 44 | Live settle requires provider terminal | After live `start`, settle only from a real `provider_terminal` (`wait_terminal` + pending buffer). Timeout / missing digest leaves the job `start_authorized` held — never fabricate a mock settle on the live path |
| 45 | Terminal ingest job bind | `MemoryTerminalStore` / Go `TerminalDisposition` record `job_id` with each disposition; ingest with a known digest but wrong `job_id` returns `disposition=conflict` (never settled ACK / never late) — mirrors SQL `job_id = $3` on lookup |
| 46 | Deposit payload param bind | `ExternalEventInbox.observe` stores a payload digest over account/amount/withdrawable; identical replay is idempotent, mismatched reuse is Conflict — `deposit_sql` mismatch CTE aborts before credit. Go `ApplyStripeDeposit` likewise conflicts on account/amount/external_id mismatch for a known event_id |
| 47 | Money-boundary ownership fence | Re-check `OwnershipGate` immediately before every ledger money mutation (reserve / resize_authorize / settle / release / pre-start cancel release) and refuse release after fencing loss — route-entry checks alone leave in-flight requests able to settle after steal |
| 48 | Live terminal binding validate | Before live settle, require `provider_terminal` fields to match funded attempt (`job_id`, `attempt_id`, `lease_id`, `coordinator_epoch`, `dispatch_nonce`, `request_digest`) plus non-negative token counts; mismatch holds the reservation |
| 49 | Stream settle after checkpoint | Streaming requests defer `settle_capped` until after the bounded chunk pipe advances `ChunkCheckpoint`; billable tokens are `min(provider_claim, content_len/4)` so inflated `completion_tokens` cannot overcharge |
| 50 | Settle SQL writes lease_id | `settle_sql` / `settle_capped_sql` / `force_settle_sql` insert `lease_id` into `provider_terminals` so durable terminal rows bind the funded lease for ingest/audit |
| 51 | Settle SQL writes se_signature | Settle CTEs also persist `se_signature` (COALESCE empty) on `provider_terminals` so rollback ingest can verify provider attestation material without re-settling |
| 52 | Job fencing epoch bind | `MemoryLedger` stores `fencing_epoch` on reserve (via `bind_fencing_epoch`); settle/release/resize refuse with `OwnershipLost` when the caller's epoch no longer matches. SQL `inference_jobs.coordinator_epoch` already reserved in `0001_rust_coord.sql` / `reserve_sql` `$5` |
| 53 | Terminal ingest lease/SE bind | `MemoryTerminalStore.record_bound` / Go `TerminalDisposition` persist `lease_id` + `se_signature`; ingest with a known digest but wrong lease or SE signature returns `disposition=conflict` (never settled ACK / never late). `lookup_sql` binds `$4`/`$5`. Chat settle records via `record_bound` |
| 54 | Live settle ownership steal hold | After live `start` (stream or non-stream), if `OwnershipGate` is released before settle, `require_holding` / fencing refuse with `ownership_lost` and leave the job `start_authorized` held — never charge after fencing loss mid-flight |
| 55 | Atomic reserve+epoch bind | `MemoryLedger.reserve_with_epoch` sets `fencing_epoch` in the same critical section as reserve (chat path uses it). Idempotent op-key replay with a mismatched epoch is `OwnershipLost`. Closes the unbound-job window between `reserve` and `bind_fencing_epoch` |
| 56 | Fenced money API wrappers | `settle_capped_fenced` / `settle_capped_as_fenced` / `release_fenced` / `resize_and_authorize_fenced` / `mark_start_authorized_fenced` call `require_fencing_epoch` inside the ledger before mutating money. HTTP chat/admin paths use these so a forgotten route-level check cannot settle after steal |
| 57 | Live SE signature on disposition | Live `provider_terminal.se_signature` is copied onto `MockCompletion` and persisted via `record_bound`; replay ingest with a mismatched SE signature returns `disposition=conflict` |
| 58 | Force-settle records disposition | Admin `force-settle` calls `record_bound` with `force_settled` so provider reconnect ingest ACKs without recording late |
| 59 | Fenced recovery helpers | `force_settle_held_fenced` / `recover_undispatched_fenced` require matching fencing epoch before money moves. Unfenced wrappers pass epoch `0` (unbound jobs only). CLI demos bind epoch via `reserve_with_epoch` |
| 60 | Release records disposition | `release_job_with_outbox` persists `released` via `record_bound` with digest `release:{job_id}` so recover/cancel releases are auditable and ingestable |
| 61 | Cancel release records disposition | Pre-start cancel release calls `record_released_disposition` (same digest as #60) when a terminal store is provided — parity with recover/prepare-fail releases |
| 62 | Admin force-settle via recovery core | `admin_force_settle` calls `force_settle_held_on` (shared with CLI/recovery) so HTTP and recovery cannot drift on disposition-first / fencing / clamp semantics |
| 63 | Admin recover via recovery core | `admin_recover_undispatched` calls `recover_undispatched_on` then records disposition + critical outbox — same classification/fencing as CLI/recovery |
| 64 | Deposit money-boundary holding re-check | `admin_deposit` re-asserts `OwnershipGate` immediately before `apply_stripe_deposit` so a steal between auth and credit cannot fund an account |
| 65 | Live wait aborts on ownership steal | While awaiting `provider_terminal`, poll ownership; on steal return `ownership_lost` and leave `start_authorized` held — never settle after mid-wait fencing loss |
| 66 | Adopt job fencing after re-acquire | `POST /v1/admin/adopt-job` rebinds an active job's `fencing_epoch` to the current owner so orphaned reserved/held jobs can be recovered or force-settled after steal |
| 67 | Prepare/start ownership watch | Live `prepare` and `start` waits `select!` with `watch_ownership_lost`; on steal return `ownership_lost` and leave the job reserved/held for adopt+recover/force-settle |
| 68 | Admin cancel-attempt HTTP | `POST /v1/admin/cancel-attempt` sends provider cancel for `start_authorized` jobs without releasing money (`cancelled_await_terminal`); reserved-not-started returns `skipped` (use recover-undispatched) |
| 69 | Adopt fencing SQL docs | `adopt_fencing_epoch_sql` rebinds `inference_jobs.coordinator_epoch` gated on active ownership holder + non-disposed job (no money CTEs) |
| 70 | Prepare-steal adopt-recover e2e | After prepare-wait ownership steal, re-acquire + `adopt-job` + `recover-undispatched` clears the orphaned reserved job and restores balance |
| 71 | Start-steal adopt-force-settle e2e + quiescence active ids | After start-wait ownership steal, adopt + force-settle clears the hold. Quiescence reports `active_job_ids` for orphan discovery |
| 72 | Bulk adopt-jobs + quiescence without ownership lists ids | `POST /v1/admin/adopt-jobs` rebinds all (or listed) active jobs. Quiescence without holding still returns `active_job_ids` so cutover ops can discover orphans after steal |
| 73 | Wait-steal adopt-force-settle e2e | After terminal-wait ownership steal, quiescence lists orphan → adopt-jobs → force-settle clears hold. `adopt_all_fencing_epoch_sql` documents bulk SQL |
| 74 | Stream wait-steal + adopt-jobs edges | Stream=true wait-steal follows same adopt→force-settle path. Bulk adopt supports explicit `job_ids` with partial failure; concurrent adopt-jobs is idempotent |
| 75 | CLI adopt-recover demo | `recovery --demo-adopt-recover-job` proves old-epoch recover fails, adopt rebinds, new-epoch recover refunds |
| 76 | Quiescence active_jobs_detail + CLI adopt-force-settle | Quiescence lists per-job `fencing_epoch` / `funded_start` / reserved amounts. CLI `--demo-adopt-force-settle-job` proves adopt then force-settle for held orphans |
| 77 | needs_adopt + recover-undispatched-batch | Quiescence `needs_adopt` flags fencing mismatch vs current owner. `POST /v1/admin/recover-undispatched-batch` releases all reserved-not-started jobs after adopt |
| 78 | force-settle-batch | `POST /v1/admin/force-settle-batch` force-settles all held jobs (default actual=0 full refund); pair with recover-batch after adopt for mixed orphans |
| 79 | clear-orphans one-shot | `POST /v1/admin/clear-orphans` runs adopt → recover reserved → force-settle held in one admin call for cutover drain |
| 80 | CLI demo-clear-orphans | `--demo-clear-orphans` proves adopt→recover→force-settle on mixed reserved+held orphans restores balance |
| 81 | orphan_summary + clear-orphans race | Quiescence `orphan_summary` counts needs_adopt/reserved/held. Concurrent clear-orphans conserves money; outbox must be acked for ready |
| 82 | Admin outbox-drain | `POST /v1/admin/outbox-drain` claim+acks all outbox entries so quiescence can become ready after clear-orphans |
| 83 | Outbox-drain race + deposit/clear conservation | Concurrent outbox-drain acks each entry once. Deposit then clear-orphans restores reserved funds on top of deposit |
| 84 | Cutover e2e + charged clear-orphans | Full steal→clear-orphans→outbox-drain→ready path. `actual_micro_usd` on clear-orphans charges held jobs |
| 85 | Clear-orphans mid-flight ownership fence | Re-check OwnershipGate before each money phase/job in clear-orphans and batch recover/force-settle; abort with partial progress on steal |
| 86 | Quiescence cutover_hint | Quiescence returns `cutover_hint` (`ready` / `clear-orphans then outbox-drain` / `outbox-drain` / …) for ops drain guidance |
| 87 | Resume after mid-flight abort + drain SQL | After clear-orphans abort on steal, re-acquire → clear-orphans → outbox-drain reaches ready. `drain_ack_all_sql` documents durable drain |
| 88 | Per-job account on clear/batch | clear-orphans / recover-batch / force-settle-batch use each job's `account_id` for money moves; optional `account` filters |
| 89 | Single-job admin defaults to job owner | `/v1/admin/recover-undispatched` and `/force-settle` omit-account → job owner; explicit mismatch → `account_mismatch` |
| 90 | Deposit vs clear-orphans conservation | Concurrent deposits + clear-orphans: each deposit applies once; orphans clear exactly once; balance = start + deposits |
| 91 | held-review-batch + cutover-drain | `POST /v1/admin/held-review-batch` classifies holds (no money). `POST /v1/admin/cutover-drain` runs clear-orphans then outbox-drain |
| 92 | cutover-drain abort on steal + hint | cutover-drain returns clear abort without draining outbox. Quiescence `cutover_hint` prefers `cutover-drain` when active jobs remain |
| 93 | Resume cutover-drain + concurrent race | After steal abort, re-acquire → cutover-drain reaches ready. Concurrent cutover-drain clears orphans once and drains outbox |
| 94 | CLI cutover-drain + deposit race | `--demo-cutover-drain` clears+drains outbox. Concurrent deposits ∥ cutover-drain conserve balance |
| 95 | Multi-account + charged cutover-drain | cutover-drain refunds each job owner; `actual_micro_usd` charges holds; account filter leaves foreign jobs (ready=false) |

## Deleted Go mechanisms (do not port)

See architecture plan §27.
