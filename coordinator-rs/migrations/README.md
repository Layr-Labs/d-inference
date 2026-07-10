# `rust_coord` migrations

sqlx-format migrations (`NNNN_description.sql`, ascending) creating the
additive `rust_coord` PostgreSQL schema for the Rust coordinator
(plan: `docs/architecture/rust-coordinator-plan.md`, §12 and §20).

Everything here is **additive**. No migration touches a legacy (`public`
schema) table with DDL — no rename, drop, type change, trigger, destructive
backfill, or new required non-null field — so a rollback-safe Go build keeps
working against the same database until Go fallback is retired (plan §20,
§4.6).

## Migration list

| # | File | Creates |
|---|------|---------|
| 0001 | `0001_rust_coord_schema_and_ownership.sql` | schema `rust_coord`, `schema_meta` (version stamp), `coordinator_ownership` (fencing epoch) |
| 0002 | `0002_inference_jobs.sql` | `inference_jobs` + recovery/admission partial indexes |
| 0003 | `0003_inference_attempts.sql` | `inference_attempts` + one-started-per-job unique partial index |
| 0004 | `0004_provider_terminals.sql` | `provider_terminals` + awaiting-settlement / conflict indexes |
| 0005 | `0005_financial_operations.sql` | `financial_operations` (operation-key idempotency) |
| 0006 | `0006_fee_allocations.sql` | `fee_allocations` (authoritative platform/referral fee rows) + unprojected index |
| 0007 | `0007_external_events_and_intents.sql` | `external_events` (inbox), `external_intents` (payout outbox) + external_unknown index |
| 0008 | `0008_outbox.sql` | `outbox` (non-critical side effects) + pending index |

## Apply procedure (plan §20)

**Application startup never runs DDL.** Migrations are applied by a separate
migrate step, never by the serving binary at boot:

```bash
# one-off, before deploying a binary that requires a newer schema_version
cd coordinator-rs
DATABASE_URL=postgres://... cargo sqlx migrate run --source migrations
```

or the equivalent `sqlx::migrate!("./migrations")` invoked from a dedicated
`coordinator-rs migrate` subcommand / deploy job — not from `main()` serving
startup. sqlx records applied migrations in `_sqlx_migrations` and applies
each file in its own transaction; a failed migration rolls back atomically and
the file can be re-run after fixing the environment.

Every file begins with bounded `SET LOCAL lock_timeout / statement_timeout`
so a migration that cannot acquire its locks fails fast instead of queueing
behind (and blocking) production traffic.

## Schema-range stamping (`rust_coord.schema_meta`, plan §20)

Migration 0001 creates a singleton row `(id = 1)`:

- `schema_version` — highest applied migration number; **every subsequent
  migration's last statement bumps it** to its own `NNNN` prefix.
- `min_reader_version` — the oldest application support floor that can still
  correctly use this schema. It stays at `1` until a migration changes
  semantics in a way old binaries must not read/write through; such a
  migration raises it explicitly.

At startup the Rust binary (and the same-release `recovery` subcommand, plan
§26.2) reads this row and **refuses to start** unless its compiled supported
range satisfies:

```text
app.min_supported <= schema_meta.schema_version
schema_meta.min_reader_version <= app.max_supported
```

## Concurrent index creation before cutover

sqlx runs each migration inside a transaction, so these files must not (and
do not) use `CREATE INDEX CONCURRENTLY`. On an **empty** `rust_coord` schema
plain `CREATE INDEX` is instant, which is the normal case: apply the whole
directory before the schema receives any traffic.

If a future migration adds an index to a `rust_coord` table that already
holds production data, follow the DAR-349 procedure instead (see
`coordinator/store/migrations/dedupe_provider_earnings.sql` for the
precedent): build it out-of-band **before** deploying the migration —

```sql
CREATE INDEX CONCURRENTLY IF NOT EXISTS <name> ON rust_coord.<table> ...;
```

— via psql (autocommit, outside any transaction), verify `indisvalid` in
`pg_index` (drop and rebuild if an interrupted build left it invalid), and
make the in-tree migration a no-op guard (`CREATE INDEX IF NOT EXISTS`) so
fresh databases still get the index. As of 0001–0008 **no index requires
out-of-band concurrent creation**: all indexes are created together with
their (empty) tables.

## Rollback-compatibility notes (plan §4.6, §12.1, §26.1)

The patched rollback-safe Go build shares this database. What it must
understand:

- **Legacy tables are untouched.** `balances`, `ledger_entries`, `usage`,
  `provider_earnings`, `earnings_summary`, `billing_sessions`,
  `stripe_withdrawals`, `api_keys`, `users`, and the model-registry tables
  keep their exact Go shapes. Rust writes them as compatibility projections
  inside its own transactions (reservation debits/refunds, ledger rows,
  usage, earnings, withdrawal rows), so Go reads stay correct throughout the
  pilot. Reservation provenance uses the existing
  `balances.withdrawable_micro_usd` column — no new hold column an old Go
  binary would ignore (plan §12.3).
- **`rust_coord` objects are additive.** Go never needs to write them, but
  the rollback build must read: `inference_jobs.state` (refuse unsafe startup
  while any job is non-terminal, and treat `review_pending` as blocking,
  §26.1 step 5), `provider_terminals` (ingest and ACK replayed protocol-v2
  terminals for Rust jobs by recording/reading the durable disposition —
  never a second settlement, §4.6), `financial_operations` (operation-key
  lookup before any compensation), and `external_intents`
  (`external_unknown` means reconcile by Stripe idempotency key — **never**
  refund or re-call Stripe, §12.11).
- **Ownership.** Go must acquire the same runtime advisory lock and bump
  `rust_coord.coordinator_ownership.fencing_epoch` before enabling workers or
  provider ingress (§26.1 step 10). Mutations fenced on an older epoch then
  fail their epoch compare-and-swap by design.
- **Quiescence before normal rollback** (§26.1): zero non-terminal
  `inference_jobs`, zero undispositioned `provider_terminals`, zero
  unprojected `fee_allocations`, zero pending `outbox` rows, and every
  `external_intents` row `legacy_projected` with no unresolved
  `external_unknown`.

## Test fixtures

`../fixtures/sql/legacy_baseline.sql` recreates the legacy Go tables for
ephemeral test databases only (production already has them — never apply it
there). `../fixtures/sql/smoke_money_flow.sql` is the regression smoke that
exercises reserve → resize → settle and reserve → release with §9.3
invariant asserts; run order: baseline, migrations 0001–0008, smoke.
