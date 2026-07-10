# Rust Coordinator

This directory tracks the Go → Rust coordinator migration.

- Architecture plan: user-provided (2026-07-10)
- Locked decisions: [DECISIONS.md](./DECISIONS.md)
- Contracts: [contracts/](./contracts/)
- Code: `coordinator-rs/`

## Workspace

```text
coordinator-rs/
  crates/protocol  — wire types + crypto
  crates/core      — pure reducers / admission / health
  crates/server    — Axum + actors + SQLx (M3+)
```

## Build

```bash
make coordinator-rs          # test + build
cd coordinator-rs && cargo test --workspace
```

## Migrations (external — never at process startup)

```bash
# Requires EIGENINFERENCE_DATABASE_URL
make migrate
# or:
cd coordinator && go run ./cmd/migrate -dir ../coordinator-rs/migrations
```

SQL lives in `coordinator-rs/migrations/` (`rust_coord` schema). Money
debits/credits target the shared Go `balances` table for continuity;
`rust_coord.*` owns jobs/attempts/terminals/outbox/ownership. The Go
`ownership` gate refuses unsafe startup when active Rust work is present.

## Ops docs

- [DECISIONS.md](./DECISIONS.md) — locked §29 defaults
- [PILOT.md](./PILOT.md) — Milestone 5 isolated pilot
- [CUTOVER.md](./CUTOVER.md) — Milestones 7–8 cutover/rollback
- [UNSUPPORTED.md](./UNSUPPORTED.md) — pilot route matrix
- Contracts: [contracts/](./contracts/)

## Pilot admin surfaces (warm plane)

| Route | Purpose |
| --- | --- |
| `GET /v1/admin/quiescence` | Drain inventory (jobs, outbox, late terminals, ownership) |
| `POST /v1/admin/deposits` | Idempotent Stripe-inbox apply (`ExternalEventInbox`) |
| `POST /v1/admin/terminal-ingest` | Replay ACK / late record (never double-settles) |
| `POST /v1/admin/force-settle` | Ops clear start_authorized hold (`force_settled`) |
| `POST /v1/admin/force-settle-batch` | Bulk force-settle held jobs (default full refund) |
| `POST /v1/admin/clear-orphans` | One-shot adopt → recover → force-settle |
| `POST /v1/admin/outbox-drain` | Claim+ack all outbox entries (cutover ready) |
| `POST /v1/admin/cutover-drain` | One-shot clear-orphans then outbox-drain |
| `POST /v1/admin/recover-undispatched` | Release reserved-not-started jobs (`inference.released` outbox) |
| `POST /v1/admin/recover-undispatched-batch` | Bulk-release reserved-not-started jobs after adopt |
| `POST /v1/admin/held-review` | Classify held start_authorized jobs (no money move) |
| `POST /v1/admin/held-review-batch` | Bulk classify held jobs (no money move; optional `account`) |
| `POST /v1/admin/adopt-job` | Rebind orphaned job fencing epoch after ownership re-acquire |
| `POST /v1/admin/adopt-jobs` | Bulk-rebind all (or listed / account-scoped) active job fencing epochs |
| `POST /v1/admin/cancel-attempt` | Cancel start_authorized attempt (no money release) |

Smoke provider: `coordinator-rs/scripts/mock_provider_ws.py`
