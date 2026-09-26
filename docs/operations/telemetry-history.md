# Queryable telemetry history

> Last updated: 2026-09-26 · commit `3e9dcf6b4`

Copy and verify retained PostgreSQL telemetry into private Cloud Storage, then
publish BigQuery views without changing coordinator writes, retention, or
financial state. This is an observational archive: a copied row is its complete
value at the recorded source snapshot, not every historical mutation.

## When to use

Use for the infrastructure stage of telemetry preservation. The source tables
are `request_profiles`, `inference_routes`, `request_outcomes`,
`request_rejections`, and `fleet_snapshots`. Existing profiler sampling and
failed or dropped writes cannot be reconstructed by this exporter.

## Prerequisites

- Authorization for the archive bucket, isolated worker, and BigQuery dataset.
- A physical, read-only replica with replay enabled and replay age at most
  30 seconds. The worker checks this before each bounded capture.
- The independent worker built from `scripts/telemetry_archive/Dockerfile`.
- Private Standard bucket `darkbloom-mainnet-telemetry-history` in us-east4,
  with uniform access, public access prevention, and no lifecycle rules.
- BigQuery dataset `darkbloom-mainnet.telemetry_history` in us-east4. The worker
  has dataset-scoped write access and project query-job access. Analysts also
  need read access to the underlying objects for external tables.

The earlier `darkbloom-mainnet-telemetry-archive` bucket and September 8 job
remain independent. Their incomplete data is not assumed to cover this run.

## Steps

1. Freeze explicit source time ranges using `prepare-plan`, then `upload-plan`.
   Start with a one-minute pilot for each table before broadening the range.
2. Run one `run-backfill` execution against the replica. Use one reader, a
   bounded task timeout, no automatic task retry, and immutable checkpoints.
3. Inspect verified progress and replication health before each resume.
   Exit 75 means incomplete; source data and completed copies are untouched.
4. Run `publish-catalog` with the relevant plan IDs. It can expose completed
   windows while the rest of a plan is still incomplete:

   ```sh
   uv run telemetry-archive publish-catalog \
     --project darkbloom-mainnet --location us-east4 \
     --bucket darkbloom-mainnet-telemetry-history \
     --dataset telemetry_history --plan-ids PLAN_ID
   ```

   `catalog.verified_entries` follows checkpoint split decisions, validates
   receipt identity and object generations, and excludes unfinished windows.
   `publish.publish` retains previously published coverage, creates immutable
   manifest/catalog generations, and switches each stable reader view only
   after its backing objects exist. Run only one publisher at a time.
5. Query `telemetry_history.archive_coverage` first. It lists the exact
   published source windows, snapshot times, rows, and file sizes. Missing
   intervals are not zero traffic. Then query the table-named reader views:

   ```sql
   SELECT source_time, source_id, archive_observed_at,
          JSON_VALUE(row_json, '$.coord_request_id') AS coord_request_id
   FROM `darkbloom-mainnet.telemetry_history.request_outcomes`
   WHERE source_time >= TIMESTAMP('2026-09-25 00:00:00+00')
     AND source_time < TIMESTAMP('2026-09-25 00:01:00+00')
   LIMIT 20;
   ```

   `row_json` retains complete PostgreSQL values, including nested outcome
   records. Repeated snapshots resolve by source ID and latest source
   observation time. Raw versioned external tables remain available for
   examining the individual copies. These are latest *archived* observations,
   not a claim of zero-lag replication or a globally consistent database view.
6. Freeze new copy plans to catch up and refresh mutable intervals. Publishing
   another plan adds coverage without discarding earlier verified files.
   A prior completion checkpoint does not refresh itself or capture updates.

## Verification

Local checks: `uv run ruff check src tests`, `uv run ruff format --check src tests`,
and `uv run pytest -q`. Disposable PostgreSQL tests verify lossless restoration,
including nested outcomes and numeric precision. Cloud verification separately
requires source-snapshot counts, decoded content and object checksums, and the
BigQuery checks in `queries.verify_query`.

Verify reader-view counts against non-overlapping pilot receipts and rerun
publication to verify idempotency. Quantify backlog, rows, bytes, source time
coverage, and observation age separately. A successful pilot or partial catalog
does not establish a completed historical backfill.

The current coordinator retention loop remains active. It can remove rows before
they are captured. Every receipt continues to declare `retention_eligible=false`;
this stage never authorizes source deletion, partition retirement, or disk shrink.

## Rollback

Stop executing the archive worker and publisher. Keep verified files, receipts,
and checkpoints. Published views can be pointed back to a prior immutable
catalog generation. No coordinator rollout or source-database rollback is needed.

## Related

- [Snapshot verification](telemetry-archive.md)
- [Finite cloud backfills](telemetry-backfill.md)
- [Worker commands](../../scripts/telemetry_archive/README.md)
- [Telemetry inventory](../reference/telemetry-inventory.md)
