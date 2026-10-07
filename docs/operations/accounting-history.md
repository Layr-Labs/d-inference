# Queryable accounting history

> Last updated: 2026-10-05

Preserve complete accounting-history snapshots in private Cloud Storage and
query them through BigQuery. This copy-only phase does not change billing,
balances, coordinator writes, retention, or source data.

## When to use

Use for `usage`, `provider_earnings`, `ledger_entries`, and
`provider_floor_draws`. The closed scope and exact reconciliation columns are
defined by `scripts/telemetry_archive/src/telemetry_archive/tables.py`
(`ACCOUNTING_FIELDS`). Current balances, users, authentication material and
live withdrawal workflows are not exportable with this worker.

## Prerequisites

- Human authorization for this accounting copy and its dedicated resources.
- A physical SELECT-only replica and its existing bigint primary keys. ID
  captures validate the primary key before reading; no source index or SQL
  mutation is performed.
- A separate private Standard bucket, in us-east4, with uniform bucket access,
  enforced public-access prevention, no deletion lifecycle, and the label
  `archive-scope=accounting`. Intended destination:
  `gs://darkbloom-mainnet-accounting-history`.
- A colocated dataset `darkbloom-mainnet.accounting_history`. Restrict dataset
  and underlying bucket access to approved accounting readers; do not copy
  telemetry-reader grants. `scope.require_bucket_scope` and
  `scope.require_dataset_scope` reject mixed destinations.
- A digest-pinned worker built from `scripts/telemetry_archive/Dockerfile`.
  Use a dedicated accounting service account/job. Give it Cloud SQL client,
  existing replica-secret access, BigQuery job-user, new-bucket object
  create/read/metadata access, and dataset-scoped writer. Grant no source writes
  or object-delete access.

## Steps

1. Check both archive jobs for active executions. Never overlap SQL readers.
   After a lag stop, require two recent direct samples with physical recovery,
   read-only mode, replay enabled, and replay age below 30 seconds.
2. Read table schema, SELECT privileges and primary-key metadata. Freeze
   inclusive/exclusive ID bounds using indexed first/last-ID reads. Start with
   small explicit pilot ranges; do not use unindexed timestamp scans on the
   large accounting tables.
3. Prepare a plan from JSON entries such as:

   ```json
   [{"table":"ledger_entries","id_start":1,"id_end":1001}]
   ```

   ```sh
   uv run telemetry-archive prepare-plan --ranges ranges.json --output plan.json
   uv run telemetry-archive upload-plan --file plan.json \
     --project darkbloom-mainnet --bucket darkbloom-mainnet-accounting-history
   ```

   Actual source bounds must be measured. Plans are immutable; copy the returned
   plan ID into the execution arguments. Do not combine telemetry and accounting.
4. Run the accounting job with one task, one reader, two CPUs, four GiB RAM,
   a one-hour timeout, no task retries, and these work bounds:

   ```sh
   uv run telemetry-archive run-backfill --plan-id PLAN_ID \
     --project darkbloom-mainnet --bucket darkbloom-mainnet-accounting-history \
     --max-run-seconds 3000 --max-new-windows 1000
   ```

   ID plans use 100,000-ID chunks and split bounded failures down to one ID.
   Count, exact integer sums and export share a repeatable-read snapshot.
   Source statement, lock, duration and byte limits remain enforced.
5. Inspect exit reason and verify checkpoints. Exit 75 is incomplete. Publish
   verified coverage after the reader has stopped:

   ```sh
   uv run telemetry-archive publish-catalog --plan-ids PLAN_ID \
     --project darkbloom-mainnet --bucket darkbloom-mainnet-accounting-history \
     --dataset accounting_history
   ```

6. Query the stable views for single-table exploration. Amounts are integer micro-USD; sum with BIGNUMERIC
   before converting units to prevent INT64 aggregate overflow:

   ```sql
   SELECT DATE(source_time) AS day,
          SUM(CAST(amount_micro_usd AS BIGNUMERIC)) / 1000000 AS earned_usd
   FROM `darkbloom-mainnet.accounting_history.provider_earnings`
   WHERE source_time >= TIMESTAMP('2026-09-01')
     AND source_time < TIMESTAMP('2026-09-02')
   GROUP BY day;
   ```

   The full original row remains available in `row_json`, with its PostgreSQL
   column types in the receipt. Published views deduplicate by source ID and
   latest archived observation. They are not a zero-lag source of current balances.

   Stable aliases switch independently and can temporarily reference different
   generations if publication is interrupted. Never join them for cross-table
   accounting. Use `analytics-preview --catalog CATALOG_VERSION` (or generate every
   input with `publish.reader_sql` and that same explicit version). Select a
   successfully published version from the command result or resolve the
   `archive_coverage` view definition once; that pointer is switched last.
   Listing `catalog_*` tables is not proof that a publication finished. If a
   required versioned input is absent, the query must fail rather than use an alias.
   Catalog pinning fixes the archive generation; it does not turn independent
   captures into a database-wide transactional snapshot.

## Verification

`accounting.add_row` rejects missing, floating-point and out-of-range integer
values. Source sums, decoded Parquet sums and BigQuery BIGNUMERIC sums must
agree exactly. Existing row-count, per-row/content/file hash, ID/time-extrema,
readback and generation checks continue to apply. The metadata, query totals,
and catalog generation form the cloud evidence; local tests and CI are separate.

Version 2 ID plans/receipts coexist with existing version 1 time snapshots;
the Parquet envelope is unchanged. `archive_coverage.id_start` and `id_end`
describe source ID coverage. Coverage-format 2 preserves separate plan/ID-window
rows even when empty ranges share one data file; manifests and storage totals
use unique files. Existing file-only catalogs require checkpoint republishing
after an approved worker upgrade, as described in [telemetry history](telemetry-history.md).
Time-window fields are null for ID captures;
backdated timestamps are valid. Never report these ID spans as complete time ranges.

Only a verified `complete=true` summary and matching catalogs establish that
the frozen plan finished. Summaries include exact accounting totals. Distinct
tables and chunks have separate source snapshots: there is no database-wide
point-in-time consistency guarantee. ID gaps and a captured maximum ID do not
rule out later commits below that ID. Use a new `prepare-plan --capture-generation`
identity to recapture the same ranges for late commits or updates; an unchanged
plan resumes its saved observation. This exporter is not a change-data-capture system.

All receipts remain `retention_eligible=false`. Archival completion never
authorizes source retirement; billing readers and settlement deduplication
must be redesigned and separately qualified before that phase.

## Prepare analytics and source retention

Follow the [operational/history design](../design/operational-history-retention.md)
for the 14-day completed-detail target, including accounting, reader dependencies
and retention gates. Financial history is in scope, but existing transactional
replay records and counters remain necessary until their replacements are qualified.
Compile a catalog-pinned query with `telemetry-archive analytics-preview`;
add `--execute` to query BigQuery with a scan cap. See the
[command reference](../../scripts/telemetry_archive/README.md#preview-future-analytics-reads).
These commands perform SELECTs only and return private shadow results. They
cannot certify complete production totals or publish a product-serving snapshot.
The proposed policy has deletion disabled; it does not alter the existing
profiler sweeper or billing readers.

## Rollback

Stop launching the accounting job. Retain its verified objects and checkpoints.
Keep prior immutable catalogs for query rollback. No source-database or
coordinator rollback is required because this workflow performs no such writes.

## Related

- [Telemetry history](telemetry-history.md)
- [Exporter commands and limits](../../scripts/telemetry_archive/README.md)
- [Billing architecture](../architecture/billing.md)
- [Read-only cloud baseline and accounting IAM gap](../reports/2026-10-05-history-storage-baseline.md)
