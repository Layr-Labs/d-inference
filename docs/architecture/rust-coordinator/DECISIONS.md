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
| 24 | Account bind on money moves | `settle` / `release` / SQL CTEs require `inference_jobs.account_id = caller account`; mismatch is Conflict and does not poison op keys. Digest/op inserts are gated on successful guard/charge so failed settles cannot pin digests |

## Deleted Go mechanisms (do not port)

See architecture plan §27.
