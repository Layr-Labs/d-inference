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

## Environment matrix

The composition root validates configuration before serving HTTP. Full-surface
mode is independent of isolated pilot mode, but it starts the same supervised
inference runtime and therefore requires the process key and MicroMDM settings.
Production provider credentials, API keys, catalog facts, prices, and billing
allocations are database-backed.

| Variable | Required when | Default / meaning |
|---|---|---|
| `EIGENINFERENCE_DATABASE_URL` | Always | PostgreSQL DSN; no memory-store fallback |
| `EIGENINFERENCE_COORDINATOR_OWNERSHIP_ENABLED` | Full surface | `false`; full surface refuses startup unless `true` |
| `EIGENINFERENCE_RUST_BIND_ADDRESS` | Optional | `0.0.0.0:8081` |
| `EIGENINFERENCE_RUST_DATABASE_MAX_CONNECTIONS` | Optional | `32` |
| `EIGENINFERENCE_RUST_SHUTDOWN_GRACE_SECONDS` | Optional | `30` |
| `EIGENINFERENCE_RUST_PILOT_ENABLED` | Isolated pilot | `false`; does not enable the production surface |
| `EIGENINFERENCE_RUST_FULL_SURFACE_ENABLED` | Production Rust surface | `false`; enables identity, billing, inference, and operations |
| `EIGENINFERENCE_RUST_PROVIDER_CREDENTIALS_JSON` | Isolated pilot; optional full-surface bootstrap | Static provider credentials; full mode also accepts active DB provider tokens |
| `EIGENINFERENCE_RUST_CONSUMER_API_KEYS_JSON` | Isolated pilot only | Static pilot credentials; forbidden in full mode |
| `EIGENINFERENCE_RUST_PROCESS_X25519_KEY_ID` | Either inference mode | Process encryption-key identifier |
| `EIGENINFERENCE_RUST_PROCESS_X25519_PRIVATE_KEY` | Either inference mode | Base64 X25519 private key |
| `EIGENINFERENCE_RUST_PROCESS_X25519_PUBLIC_KEY` | Either inference mode | Matching base64 X25519 public key |
| `EIGENINFERENCE_RUST_PILOT_STATE_DIRECTORY` | Optional | `/var/lib/darkbloom/rust-pilot` |
| `EIGENINFERENCE_RUST_PILOT_MODEL_ID` | Optional | `darkbloom/pilot-text` |
| `EIGENINFERENCE_RUST_PILOT_MODEL_ALIAS` | Optional | `darkbloom-pilot` |
| `EIGENINFERENCE_RUST_PILOT_TRUST_FLOOR` | Optional | `self_signed` in isolated mode; `hardware` and immutable in full mode |
| `EIGENINFERENCE_RUST_BILLING_JSON` | Isolated hardware pilot only | Immutable durable pricing, reservation, and allocation policy; forbidden in full mode |
| `EIGENINFERENCE_MDM_URL` | Hardware/full mode | MicroMDM API origin |
| `EIGENINFERENCE_MDM_API_KEY` | Hardware/full mode | MicroMDM Basic-auth secret |

Full-surface base configuration:

| Variable | Required when | Default / meaning |
|---|---|---|
| `EIGENINFERENCE_PRIVY_APP_ID` | Full surface | Privy JWT audience |
| `EIGENINFERENCE_PRIVY_JWKS_URL` | Optional | Privy app JWKS endpoint |
| `EIGENINFERENCE_ADMIN_KEY` | Full surface | Exact admin bearer secret |
| `EIGENINFERENCE_RELEASE_KEY` | Full surface | Exact release-registration bearer secret |
| `EIGENINFERENCE_MDM_WEBHOOK_SECRET` | Full surface | Exact MDM webhook secret |
| `EIGENINFERENCE_BASE_URL` | Optional | `https://api.darkbloom.dev`; canonical public origin |
| `EIGENINFERENCE_CONSOLE_URL` | Optional | `https://console.darkbloom.dev` |
| `MODEL_REGISTRY_CDN_BASE_URL` | Optional | `https://models.darkbloom.ai` |
| `EIGENINFERENCE_R2_CDN_URL` | Optional | Release artifact origin |
| `EIGENINFERENCE_PROVIDER_VERSION` | Optional | `dev` |
| `EIGENINFERENCE_MIN_PROVIDER_VERSION` | Optional | Empty |
| `MODEL_REGISTRY_PUBLISHING_ENABLED` | Optional | `true`; publishing keys remain DB-backed |
| `EIGENINFERENCE_RUNTIME_MANIFEST_JSON` | Optional | Bounded JSON object returned by the trust surface |
| `EIGENINFERENCE_RUST_RATE_LIMIT_IDENTITIES` | Optional | Bounded identity cardinality |
| `EIGENINFERENCE_RUST_EXTERNAL_HTTP_TIMEOUT_SECONDS` | Stripe enabled | `10`, bounded to `1..=30` |

Optional features fail closed on partial configuration:

| Gate | Required configuration |
|---|---|
| `EIGENINFERENCE_RUST_STRIPE_ENABLED=true` | `EIGENINFERENCE_STRIPE_SECRET_KEY`, both webhook secrets, success/cancel URLs, and Connect return/refresh URLs; `EIGENINFERENCE_STRIPE_CONNECT_COUNTRY` defaults to `US` |
| `EIGENINFERENCE_RUST_ENROLLMENT_ENABLED=true` | `EIGENINFERENCE_MDM_TOPIC`, `EIGENINFERENCE_SCEP_CHALLENGE`, and both CMS certificate/private-key PEM values or their `_FILE` alternatives |
| `EIGENINFERENCE_RUST_REQUIRE_ENROLLMENT=true` | Enrollment must also be enabled with a signer that validates at startup |
| `EIGENINFERENCE_STATE_EXPORT_ENABLED=true` | `EIGENINFERENCE_RUST_STATE_EXPORT_RECIPIENT_KEY_ID` and `EIGENINFERENCE_RUST_STATE_EXPORT_RECIPIENT_X25519`; root falls back through `EIGENINFERENCE_STATE_EXPORT_ROOT`, `USER_PERSISTENT_DATA_PATH`, then `/mnt/disks/userdata` |
| `EIGENINFERENCE_RUST_ADMIN_OTP_ENABLED=true` | `EIGENINFERENCE_PRIVY_APP_SECRET` and non-empty `EIGENINFERENCE_ADMIN_EMAILS` |

Secret-bearing configuration has redacted `Debug` implementations and is never
included in startup logs.

The same binary exposes bounded owner-fenced maintenance modes:

```text
coordinator serve
coordinator recovery
coordinator invariant-scan
coordinator review-resolve --job UUID --disposition settle|release --reason TEXT
```

The isolated hardware pilot requires static consumer/provider mappings and
`EIGENINFERENCE_RUST_BILLING_JSON`. The production full surface deliberately
rejects static consumer and billing policy: each request resolves its API-key
controls, model/alias, prices, provider beneficiary, platform fee, and referral
allocation from PostgreSQL and freezes those facts in the durable job. Static
provider credentials remain an optional bootstrap path; device-issued provider
tokens are authoritative in PostgreSQL. The `self_signed` self-route mode
remains explicitly free and is not available to the full surface.

Application startup never applies DDL. Checked SQL metadata is committed under
`.sqlx/`; the Go `coordinator-migrate` command must first bring the public
catalog to version 6 and install `rust_coord.schema_versions` version 4.
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
