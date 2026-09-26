# Copy and verify historical telemetry

> Last updated: 2026-09-26 · commit `3e9dcf6b4`

Use the standalone copy-only exporter to preserve a bounded telemetry snapshot
in Cloud Storage and verify it with BigQuery. This phase does not change the
existing profile/fleet retention, add new retention, remove source rows, or
deploy a scheduled service.

## When to use

Use for small verified pilots and explicitly bounded historical copies of
`request_profiles`, `fleet_snapshots`, `request_rejections`, or
`inference_routes`. These are diagnostic histories. They are used by admin and
profiler reads, while live routing and financial state are separate. No billing,
balance, user, or API-key table is accepted by the exporter.

The implementation is `scripts/telemetry_archive/src/telemetry_archive/`:
`source.snapshot` opens a read-only replica snapshot, `artifact.capture` creates
Parquet and a verified receipt, `objects.upload` publishes immutable objects,
and `queries.verify_query` checks a temporary BigQuery external table.

## Prerequisites

- Python 3.12 and uv; install the locked dependencies following the
  [tool README](../../scripts/telemetry_archive/README.md).
- A SELECT-only read-replica role and Cloud SQL connector/Proxy access.
  `ARCHIVE_DATABASE_URL` is an environment-only credential. Physical replica
  and transaction read-only checks are enforced before reading table data.
- Google credentials with access to create/read archive objects and submit
  BigQuery query jobs. The implementation uses temporary external table
  definitions, so this pilot does not need a persistent dataset.
- A private STANDARD bucket in us-east4 with uniform bucket access, public
  access prevention enforced, and no lifecycle rules.

Production bucket creation, IAM changes and subsequent service deployments
follow the repository's explicit approval rules. A bucket used for logs may
have automatic deletion and must not be reused without checking its policy.
The exporter itself cannot create buckets or alter their policies.

## Steps

1. Choose one telemetry table and a small historical interval. Prefer a
   one-minute pilot first; intervals must fit within one UTC date and be at
   most one hour. Explicitly bound row/byte/runtime budgets.
2. Run `telemetry-archive capture` with `--table`, `--start`, `--end`, and a new
   local `--directory`. COUNT and all pages share one repeatable-read source
   snapshot. After the transaction closes, the full decoded file is verified.
3. Run `verify-local`. Preserve the resulting data and receipt together.
   Receipts say `copy_only=true` and `retention_eligible=false`; no consumer
   should interpret them as deletion permission.
4. Run `upload` with the approved existing bucket and project. The uploader
   validates bucket policy, creates content-addressed Parquet, reads it back,
   creates its file manifest, and publishes the receipt last. Retry this
   command against the same local artifact after an interrupted upload.
5. Run `verify-remote --receipt <returned gs URI> --bigquery` with a bytes-billed
   cap. It re-downloads and decodes the published objects, then compares
   BigQuery results with the source receipt. Save its JSON output/job ID.

Full commands are maintained in the [tool README](../../scripts/telemetry_archive/README.md).

If an approved dedicated bucket does not exist, the concrete creation command is:

```sh
gcloud storage buckets create gs://darkbloom-mainnet-telemetry-archive \
  --project=darkbloom-mainnet --location=us-east4 \
  --default-storage-class=STANDARD \
  --uniform-bucket-level-access --public-access-prevention
```

This command creates no lifecycle rule and no automatic deletion. Default soft
delete provides recovery for accidental explicit deletions; it does not expire
live objects. Do not add lifecycle or locked retention settings during this phase.

## Verification

Require successful source capture, local readback, GCS generation-pinned
readback, and BigQuery verification as separate gates. A successful upload alone
does not establish usable or complete archival. Check the reported source row
count, payload hashes, distinct source IDs, bounds, and BigQuery job ID.

Rows are preserved in complete PostgreSQL JSON plus the source type catalog;
Parquet exposes typed ID/time/model/outcome fields for convenient queries.
Integration tests restore JSON through PostgreSQL `json_populate_record` and
compare complete values, including precise numeric fields and new columns.

The bucket contains `data/v1/<table>/event_date=<date>/<file-hash>.parquet`,
`manifests/v1/<artifact-id>.txt`, and `receipts/v1/<artifact-id>.json`. All are
create-only. Published manifests name exactly the verified objects. Queries
use one manifest, avoiding double counts from repeated snapshots of a window.

Routes can be updated after insertion. A snapshot of them is a historical
observation, not a promise of final outcomes. Capturing that interval again
preserves a later snapshot; this phase does not deduplicate multiple snapshots
into a current-state catalog or certify them for deletion.

## Rollback

Stop invoking the exporter. There is no coordinator code/config change, source
mutation, scheduler, or retention hook to roll back. Leave uploaded evidence
in the private bucket. Partial uploads have no successful receipt and must not
be included by a broad wildcard query. The tool has no delete command.

## Related

- [Profiler query recipes](profiler-queries.md)
- [Telemetry inventory and current retention](../reference/telemetry-inventory.md)
- [Historical archive tool](../../scripts/telemetry_archive/README.md)
