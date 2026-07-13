# Go coordinator retirement checklist

Go retirement is a separate, eventual gate after the full Rust cutover and
both 30-day and 90-day bakes. Reaching full cutover does not authorize removing
the Go binary, fallback image, migrator ownership, compatibility tests, or
protocol-v1 support.

## Prerequisites

- The recursively embedded chain reaches `full-cutover`, `bake-24h`,
  `bake-7d`, `bake-30d`, and a fresh `bake-90d` authorization.
- The current live snapshot proves the atomic single Rust owner, 100% protocol
  v2, zero v1 providers, complete minimum-version/hardware-trust coverage, and all
  durable/external/outbox/fee counts at zero.
- The 90-day bake consists of fixed, non-overlapping RDS/Datadog intervals.
  RDS reports zero actual Go-tagged mutation, background, and financial table
  writes; zero Go sessions and ownership epochs; zero unknown ownership
  epochs; and complete write-trigger coverage. It also proves every trigger is
  enabled, exact `pg_get_triggerdef`/function hashes match the migration-pinned
  manifest, and table/function owners still match, including ownership
  history. HTTP proxy traffic and operator-entered booleans are not evidence.
- The last local rollback drill passed additive-schema Go compatibility,
  provider-v1 fallback, and durable historical terminal ACK checks.
- Incident, payments, security, provider, database, release, and coordinator
  owners have reviewed the ownership matrix.

## Steps

1. Complete a schema-version-1 retirement inventory with exactly these
   booleans:

   ```json
   {
     "schema_version": 1,
     "checks": {
       "go_compatibility_archive_verified": true,
       "go_fallback_dependency_inventory_empty": true,
       "historical_terminal_ack_archive_verified": true,
       "migration_owner_transferred": true,
       "rollback_artifacts_retained": true,
       "v1_provider_inventory_empty": true
     }
   }
   ```

2. Sign it without altering the reviewed source:

   ```bash
   python3 scripts/cutover-readiness.py import-retirement-inventory \
     --source artifacts/cutover/go-retirement-inventory.json \
     --environment production \
     --environment-manifest artifacts/cutover/environment.json \
     --trusted-environment-key "$GATE_PUBLIC" \
     --signing-key "$COLLECTOR_PRIVATE" \
     --output artifacts/cutover/go-retirement-inventory.report.json
   ```

3. Assess and explicitly approve `go-retirement` using only the fresh 90-day
   bake authorization as its direct predecessor. Its recursive bundle proves
   the earlier stages. A missing or false inventory field blocks retirement.
4. Before deleting code, transfer the external migration command and schema
   checksum ownership to a reviewed Rust or standalone migration artifact.
   Serving startup must remain DDL-free
   (`coordinator-rs/crates/server/src/schema.rs`).
5. Preserve immutable source, image, migration, and evidence artifacts needed
   to interpret historical Go ledger and Rust terminal records. Preserve the
   cross-language crypto/protocol fixtures.
6. Remove dependencies in small reviewed changes: operational selector and
   Go-serving path first, then Go fallback packaging, then dead Go code. Do not
   combine retirement with a schema migration or provider protocol change.
7. Keep `CheckRollbackSafe` characterization and historical-terminal-ACK
   fixtures in the archive even after the executable leaves the active image.

## Verification

- `go-retirement.authorization.json` verifies against the trusted gate key and
  names the trusted human approver key.
- Datadog and RDS evidence use repository-pinned definitions and exactly tile
  90 days with zero measured Go database mutations/ownership and no overlap or
  gap. Distinct RDS job IDs satisfy the minimum volume.
- Provider protocol coverage reports `v1=0` and `v2=total`; no support or
  release channel still advertises a v1-compatible provider.
- The replacement migration command validates public/Rust schema checksums and
  additive compatibility without the Go serving binary.
- A clean image build, Rust test/fault suite, offline cutover suite, and
  deployment shell suite pass after each removal.
- The incident commander can locate retained rollback artifacts and the
  post-retirement recovery procedure.

## Rollback

Before deleting the Go serving path, rollback is the normal serial pinned-Go
handoff. After retirement, do not reintroduce an old Go binary against a newer
schema merely because its artifact exists. Stop serving mutations, inspect the
current schema and durable state with the retained compatibility tooling, and
ship a reviewed forward fix or purpose-built recovery image. Any need to use a
retained Go artifact invalidates the retirement bake and requires a new
90-day authorization before attempting retirement again.

