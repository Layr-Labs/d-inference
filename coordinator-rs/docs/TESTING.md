# coordinator-rs Test Map

Where every test lives, how to run any slice of the suite, and which plan
sections (docs/architecture/rust-coordinator-plan.md, at the repo root) each
test module enforces. Placement rules are in [STYLE.md](STYLE.md) rule 10.

## Layers

| Layer | Location | What it proves | External needs |
|---|---|---|---|
| Unit | `#[cfg(test)] mod tests` at the bottom of each `src/` file | The file's own logic, white-box | none |
| Core integration | `crates/core/tests/it/` (single binary `it`) | Pure domain invariants: request reducer, fleet admission/health/permits, settlement conservation. No IO, heavy proptest | none |
| Protocol integration | `crates/protocol/tests/it/` (single binary `it`) | Cross-language compatibility against the Go coordinator via checked-in golden vectors | `fixtures/vectors/` (checked in) |
| Server integration | `crates/server/tests/it/` (single binary `it`) | The wired system: e2e settlement flows, HTTP surface, Postgres ledger, provider sessions, socket behavior | PostgreSQL binaries for the pg-backed suites (see below) |

Each crate has exactly ONE integration-test binary, `tests/it/main.rs`, whose
`//!` header is the authoritative module → proves-what map for that crate.
Server modules: `it/e2e/{v1_settlement,v2_settlement,rejections,cancellation}`,
`it/http/{chat_v1,chat_v2,limits,nonstream,deadlines}`,
`it/ledger/{pg,concurrency,recovery}`, `it/session/{v1,v2,fleet_actor}`,
`it/net/{stream_latency,backpressure,protocol}`, shared harness in `it/support/`.

## Running slices

```bash
cargo test --workspace                                # everything
cargo test -p darkbloom-core                          # one crate (unit + it)
cargo test -p darkbloom-core --lib                    # unit tests only
cargo test -p darkbloom-core --test it                # integration binary only
cargo test -p darkbloom-core --test it request::cancellation   # one module
cargo test -p darkbloom-server --test it ledger::concurrency   # one server module
cargo test -p darkbloom-protocol --test it -- --list  # enumerate without running
```

Test filters are substring matches on the full module path
(`request::cancellation::rung_13_4_...`), so any prefix selects a subtree.

## External dependencies

- **PostgreSQL (server suites only).** `it/ledger/*`, `it/e2e/*`, and every
  other pg-backed suite boot a REAL throwaway cluster per test via
  `initdb`/`pg_ctl` (helpers in `it/support/`), apply
  `fixtures/sql/legacy_baseline.sql` plus all `migrations/`, and tear it down.
  When `initdb` is not on `PATH` the tests **self-skip**: they print
  `SKIPPED: initdb/pg_ctl not found on PATH — install PostgreSQL` and pass, so
  a green run on a machine without Postgres has NOT exercised the money paths.
  Nothing ever points at a live database.
- **Nothing else.** No network, no Go toolchain (vectors are checked in), no
  provider binaries.

## Golden vectors (`fixtures/vectors/`)

Cross-language fixtures consumed by `crates/protocol/tests/it`. Regenerate
from the **repository root** (one level above `coordinator-rs/`), where the Go
coordinator module lives:

```bash
go run ./coordinator-rs/fixtures/gen
```

- **Byte-stable on regeneration**: `json_v1/*.json` goldens,
  `nacl_box/vectors.json`, `sealed_sender/vectors.json` — every key and nonce
  is derived from fixed strings via SHA-256, so a regen only changes bytes if
  the Go encoder or crypto changed (which is exactly what the tests must catch).
- **Churn by design**: the ECDSA P-256 signatures in `signing/vectors.json`
  and the signed attestation embedded in `json_v1/register__populated.json`
  are randomized per run (ECDSA signing draws fresh randomness; verification
  inputs are what matter). The checked-in files are the fixture of record —
  regenerate everything together and commit atomically, because
  `it/golden_v1` cross-checks the register golden against the signing vectors.

## SQL smoke (`fixtures/sql/smoke_money_flow.sql`)

A pure-SQL regression smoke for the plan §12 money design: seed → reserve
(with idempotent replay) → resize/freeze → settle with exact split, plus
reserve → release, duplicate-digest replay, and §9.3 conservation asserts.
Run it against an **ephemeral** database only, after `legacy_baseline.sql`
and all `migrations/`, with `psql -v ON_ERROR_STOP=1`. The Rust
`it/ledger/pg` suite exercises the same shapes through the real code; the
smoke exists so the schema + SQL contract can be checked with nothing but
`psql`. Never run either fixture against production.

## Plan traceability

Which test modules enforce each load-bearing plan section. Module paths are
inside each crate's `tests/it/` unless marked `src` (unit tests).

| Plan section | Enforced by |
|---|---|
| §9.2 Request invariants (single funded start, no alternate after funding, immutable deadlines, permit/lease hygiene, ambiguous writes) | core `request/properties` (arbitrary-interleaving reducer property, §9.2.3–9.2.11), core `request/lifecycle` (deadlines §9.2.5, ambiguous start §9.2.11), core `fleet/properties` (permit accounting §9.2.10); server `http/deadlines` (shared first-content deadline across alternates), server `e2e/rejections` |
| §9.3 Financial invariants (conservation, provenance, no negative balances) | core `settlement/properties` (reserve == charge + refund on both components, exact splits); server `ledger/pg`, `ledger/concurrency` (spend-cap fence under concurrency), server `e2e/v1_settlement`, `e2e/v2_settlement`; `fixtures/sql/smoke_money_flow.sql` |
| §9.4 Backpressure invariants (bounded buffers, stall propagation) | server `net/backpressure` (stalled consumer socket → provider cancel with bounded memory), server `http/limits` |
| §10 Provider protocol v2 (registration, prepare/fund/start, structured errors, terminal delivery) | protocol `src json_v2::*` unit tests (frames, registration gating, ids); core `request/lifecycle` (terminal idempotency + digest conflict §10.6); server `session/v2` (prepare→started, epoch/nonce fencing, abort tombstone §10.2–10.3), `session/v1` (legacy interop), `session/fleet_actor` (§10.7 model lifecycle); protocol `golden_v1` pins the v1 wire during migration |
| §12 Durable request and money design (reserve/settle/release transactions, provenance, terminal acknowledgement) | core `settlement/properties` (§12.3 provenance); server `ledger/pg` (§12.5–§12.8 transactions, idempotent replays), `ledger/recovery` (sweepers/ownership, §18.1 §22.4); `fixtures/sql/smoke_money_flow.sql` |
| §13 Cancellation and consumer commitment | core `request/cancellation` (every rung §13.1–§13.6), core `request/properties` (post-cancel checkpoint freeze §13.4–§13.5); server `e2e/cancellation`, server `net/backpressure` (slow consumer §13.6) |
| §16 Latency budgets | server `net/stream_latency` (per-chunk relay p99 < 2 ms, no Nagle/coalescing stalls), server `http/deadlines` (first-content and total deadline discipline) |

When adding a test for a new plan guarantee, put the plan-section reference in
the test's doc comment and extend this table.
