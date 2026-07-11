# Rust Coordinator

Pre-production replacement for the Go coordinator. It is a single-active
modular monolith with three primary crates:

| Crate | Responsibility |
|---|---|
| `protocol` | Versioned provider wire types, binary framing, crypto compatibility |
| `core` | Pure request/fleet state reducers, admission, health, pricing |
| `server` | Axum/Tokio adapters, provider sessions, SQLx, workers, binary |

The Rust binary is not a production target until the migration's protocol,
money, recovery, parity, pilot, and rollback gates pass. The Go coordinator
remains authoritative during this phase.

## Commands

```bash
make coordinator-rs-fmt
make coordinator-rs-lint
make coordinator-rs-test
make coordinator-rs-build
make coordinator-rs-sqlx
```

Runtime configuration currently required by the composition root:

```text
EIGENINFERENCE_DATABASE_URL
EIGENINFERENCE_COORDINATOR_OWNERSHIP_ENABLED  default false; irreversible once activated
EIGENINFERENCE_RUST_BIND_ADDRESS              default 0.0.0.0:8081
EIGENINFERENCE_RUST_DATABASE_MAX_CONNECTIONS default 32
EIGENINFERENCE_RUST_SHUTDOWN_GRACE_SECONDS   default 30
```

The same binary exposes bounded owner-fenced maintenance modes:

```text
coordinator serve
coordinator recovery
coordinator invariant-scan
coordinator review-resolve --job UUID --disposition settle|release --reason TEXT
```

When the pilot trust floor is `hardware`, startup also requires durable paid
configuration. `EIGENINFERENCE_RUST_CONSUMER_API_KEYS_JSON` maps each raw API
key to an immutable `account_id` and `api_key_id`;
`EIGENINFERENCE_RUST_PROVIDER_CREDENTIALS_JSON` maps each provider credential
to its `beneficiary_account_id`; and `EIGENINFERENCE_RUST_BILLING_JSON` fixes
the platform/referral accounts, pricing and rounding versions, token rates,
reservation amount, and allocation shares. The `self_signed` self-route mode
remains explicitly free.

Application startup never applies DDL. Checked SQL metadata is committed under
`.sqlx/`; the Go `coordinator-migrate` command must first bring the public
catalog to version 5 and install `rust_coord.schema_versions` version 3.
`Database::connect` only checks that compatible pair. Regenerating SQLx
metadata likewise requires a disposable database migrated to that exact
catalog pair; CI migrates its isolated PostgreSQL service before checking the
metadata.

The durable schema is additive. Concrete SQLx services under `server/src/db`,
`ledger`, `recovery`, and `projection` own durable jobs, exact reservation
provenance, atomic settlement, Stripe operations, bounded recovery leases,
outbox work, fee checkpoints, and one-statement catalog snapshots. Paid pilot
request execution and terminal ingestion consume these services directly;
supervised recovery, external-event, outbox, and fee workers reconcile work
that survives process loss. Production migration ownership remains with the
external Go command; integration tests apply the mirror under `migrations/`
only to isolated temporary PostgreSQL databases.

Paid execution acquires fleet capacity before creating one provisional job,
then freezes the validated provider lease, model, token bounds, beneficiary
accounts, rates, and operation provenance in the start-authorization CAS.
Reserve persists the request's absolute `request_deadline`; authorization
refuses an expired deadline. A started attempt is retained and queried only
against its original identity before that deadline. At or after the deadline,
recovery atomically moves it to `review_pending` with
`authorized_terminal_timeout`, preserving the reservation and immutable facts
for a journaled operator settle or release. Terminal settlement/release SQL
also enforces the deadline, so a racing late terminal is persisted in review
and cannot bypass the operator queue.
Ambiguous Start delivery remains bound to that exact provider lease. Accepted
output counters, never `final_generated_tokens`, determine output charges.
Signed terminals are ACKed only after settlement, release, or reviewed
disposition commits; contradictory evidence hard-untrusts the provider epoch
and remains quarantined until `review-resolve` journals an operator decision.
Authorization records absolute `start_authorized_at` and `start_deadline`
timestamps and creates the attempt as `not_sent`. Writer admission, completed
socket delivery, and ambiguous delivery advance it through `queued`, `on_wire`,
or `sent_unknown` under the ownership epoch. Recovery can release only an
expired `not_sent` attempt. Every other authorized delivery state is reconciled
with v2 `query_attempt`/`attempt_status` against the exact historical
`AttemptIdentity`; a resend is permitted only when that same provider proves
the same lease remains prepared. A reconnect may resume it only within the
same provider process generation; the resent Start and StartAck retain the
original session epoch. Unknown or unavailable state after the deadline enters
operator review.

Stripe deposit and withdrawal-intent payloads use a recursively key-sorted
canonical JSON encoding. The ledger recomputes its SHA-256 digest before any
SQL or balance mutation, rejects a caller-supplied mismatch, stores only the
computed digest, and verifies the persisted payload provenance on replay.

Every startup takes the same dedicated PostgreSQL primary advisory lock as the
Go coordinator, including disabled legacy mode. It then takes the exclusive
`darkbloom-coordinator-mutation` handoff lock before checking activation or
advancing the public `coordinator_ownership` epoch. Serving-pool checkouts hold
the shared form of that lock and reverify the primary lock plus the expected
epoch (or absent legacy marker), so an old process cannot write across a
handoff. The primary connection is monitored continuously; loss also removes
readiness and triggers runtime shutdown. Once either coordinator has persisted
`coordinator_ownership_activated`, disabled startup is refused.
Durable financial mutations are single READ COMMITTED data-modifying CTE
statements. Each statement verifies the active owner id/epoch in its own
snapshot, uses immutable operation key/digest replay records, exact status and
version CAS, checked `BIGINT` bounds, and deterministic account lock order.
Only SQLSTATE `40001` and `40P01` are retried with bounded jitter; uncertain
transport outcomes are reconciled by operation key and conflicting digests
fail closed. Other SQL mutators continue to enter through
`Database::begin_owned`.
Real PostgreSQL integration tests use the dedicated
`DARKBLOOM_TEST_DATABASE_URL`; they refuse to fall back to a runtime database
URL.
