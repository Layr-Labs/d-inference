# Historical storage cloud baseline

> Last updated: 2026-10-05

Read-only metadata inspection of `darkbloom-mainnet` at 05:36-05:37 UTC on
2026-10-05, for the [14-day operational storage plan](../design/operational-history-retention.md).
No record contents, secrets or database credentials were read. No queries, job
executions, infrastructure mutations or source deletion were performed.

## Observed storage

All bucket names below have the prefix `darkbloom-mainnet-`. All are regional
STANDARD in `US-EAST4`, with uniform bucket-level access, enforced public-access
prevention, object versioning and seven-day soft delete. None reported a bucket
retention policy/lock.

| Bucket suffix | Current Parquet files under `data/` | Bytes | Latest object creation, UTC | Lifecycle |
|---|---:|---:|---|---|
| `telemetry-archive` | 165 | 5,560,806,720 | 2026-09-09 09:58:03 | Deletes noncurrent versions with at least four newer versions |
| `telemetry-history` | 1,445 | 5,597,392,689 | 2026-09-29 01:52:42 | None |
| `accounting-history` | 4 | 320,263 | 2026-09-26 23:43:16 | None |

These are object counts, not distinct source rows, source-time coverage or
verification results. Listings exclude old object versions and cannot establish
completeness. Current summary objects exist for some plans, but their contents
were not read or reconciled.

The accounting bucket has `archive-scope=accounting` and `purpose=copy-only`.
Its dataset ACL is restricted, but its bucket grants project viewers
`storage.legacyObjectReader`/`storage.legacyBucketReader`; project editors and
owners have legacy owner grants. Thus dataset isolation alone does not restrict
access to raw accounting objects. Dedicated worker identities have bucket-level
creator/viewer access and project `bigquery.jobUser`/`cloudsql.client`; this was
not an exhaustive inherited-permission audit.

## Workers and catalogs

All three Cloud Run jobs have one task, parallelism one, two CPUs, 4 GiB RAM,
no automatic retries, and attach to the PostgreSQL 17 read replica.

| Job | Timeout / configured budget | Latest observed activity |
|---|---|---|
| `darkbloom-telemetry-backfill` | 21,600s / 21,000s | Failed 2026-09-09 18:43:36 UTC |
| `darkbloom-telemetry-history` | 3,600s / 3,000s, 1,000 new windows | Capture `m5qsd` exited 75 on September 29; subsequent publisher `fwqg2` succeeded at 02:00:27 UTC |
| `darkbloom-accounting-history` | 3,600s / 3,000s, 1,000 new windows | Capture `qhlk5` and subsequent publisher succeeded September 26 |

No active executions or `us-east4` Cloud Scheduler jobs were listed. This does
not rule out external automation or jobs in other regions. A publisher success
does not imply the preceding capture completed; metadata did not establish why
the telemetry capture stopped.

A subsequent read-only `gcloud datastream streams list` request for `us-east4`
returned `SERVICE_DISABLED` for `datastream.googleapis.com`; no API was enabled.
The request therefore did not inventory streams or prove an alternative capture
mechanism exists.

The pinned images under
`us-east4-docker.pkg.dev/darkbloom-mainnet/coordinator/` were:

```text
telemetry-archive@sha256:b2ad2736212bbad8b668e72e5f99f0d6fcf31b69bec523ae01a6fffd1be6bbee
telemetry-history@sha256:bb871cd99b1549fbd5bc0fd158fbffbcb703a43f3f6d6215be12fe7a493a4fea
accounting-history@sha256:2d433e295ba15420b0d66153d56428bccc0b88208ff8fb2c19b3e2a92c7596a9
```

Image-to-source provenance was not established. No image was changed.

| BigQuery dataset | Current coverage target | Catalog rows |
|---|---|---:|
| `telemetry_history` | `catalog_724f5f329ac28de7` | 1,445 |
| `accounting_history` | `catalog_101e0981572c6544` | 4 |

Both datasets are in `us-east4` with no default table expiration. Their current
five telemetry and four accounting views use external Parquet manifests and
source-ID deduplication. The catalogs lack the `archive_coverage=plan_windows_v2`
label, and readers use the older direct filename join. The new coverage-format
publication is therefore not evidenced as deployed. Catalog rows are file or
coverage entries, not business-row counts; `numRows=0` on a view/external table
is not evidence that an archive is empty.

## Operational database

The jobs use `d-inference-prod-pg17-ro`, not the separate PostgreSQL 16 instance.

| Setting | Primary `d-inference-prod-pg17` | Replica `d-inference-prod-pg17-ro` |
|---|---|---|
| State / region | RUNNABLE / `us-east4` | RUNNABLE / `us-east4` |
| Tier / availability | `db-c4a-highmem-32` / regional | `db-c4a-highmem-16` / zonal |
| Disk | 2,356 GB Hyperdisk Balanced, autoresize | 2,356 GB Hyperdisk Balanced, autoresize |
| Explicit flags | None reported | `max_standby_streaming_delay=900000` |
| Backup / PITR | Enabled; 36 backups, 35-day transaction logs | Disabled |
| Deletion protection | Enabled | Enabled |

The latest five primary automated backups reported SUCCESSFUL; the latest
completed October 5 at 00:30:24 UTC. Backup health is not historical-archive
qualification. No database connection was made, so actual replay age, replay
state, SQL-role permissions and source row coverage remain unverified.

## Evidence collection

Read-only command families used explicit output projections for job metadata,
excluding environment values:

```sh
gcloud storage buckets describe gs://BUCKET --project=darkbloom-mainnet
gcloud storage buckets get-iam-policy gs://BUCKET --project=darkbloom-mainnet
gcloud storage ls --long --recursive gs://BUCKET/data/ --project=darkbloom-mainnet
gcloud storage ls --long 'gs://BUCKET/backfills/v1/*/summary.json' --project=darkbloom-mainnet
gcloud run jobs list --project=darkbloom-mainnet --region=us-east4
gcloud run jobs describe JOB --project=darkbloom-mainnet --region=us-east4
gcloud run jobs executions describe EXECUTION --project=darkbloom-mainnet --region=us-east4
gcloud scheduler jobs list --project=darkbloom-mainnet --location=us-east4
bq show --format=prettyjson darkbloom-mainnet:DATASET.TABLE
gcloud sql instances describe INSTANCE --project=darkbloom-mainnet
gcloud sql backups list --instance=d-inference-prod-pg17 --project=darkbloom-mainnet --limit=5
```

This baseline warrants preserving existing objects, requalifying IAM and
publication, and completing capture before any retirement. It does not authorize
those operations or establish that 14-day source retention is safe today.
