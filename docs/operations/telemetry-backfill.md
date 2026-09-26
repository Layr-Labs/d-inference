# Launch the copy-only telemetry backfill

> Last updated: 2026-09-26 · commit `3e9dcf6b4`

Run a finite historical copy in us-east4 near the database, with resumable
Cloud Storage checkpoints and BigQuery verification. This runbook prepares a
one-off Cloud Run Job; it does not enable deletion, alter existing retention,
or add a recurring schedule.

## When to use

Use after the [snapshot pilot](telemetry-archive.md) passes, to copy the four
telemetry tables across explicit historical ranges. Live routing state, users,
balances, usage/accounting, and provider earnings are not included. Each leaf
is a read-only snapshot taken when that interval is processed, not a single
database-wide snapshot or a record of future updates.

## Prerequisites

- Human approval for the specific Cloud Run deployment, service account and
  limited IAM grants below, as required by repository `AGENTS.md`.
- A reviewed Linux/amd64 image of `scripts/telemetry_archive/Dockerfile`.
- Existing STANDARD bucket `darkbloom-mainnet-telemetry-archive` in us-east4,
  with enforced private uniform access and no lifecycle rules.
- Existing read-replica access secret and Cloud SQL connection name. The
  measured configuration used secret `darkbloom-kydo-read-replica-access`
  version **2** and `darkbloom-mainnet:us-east4:d-inference-prod-pg17-ro`.
- A frozen, verified plan uploaded with `telemetry-archive upload-plan`.

The prepared September 8 plan is
`d91357b281aa29745bba8da91c05ab18c197da5feaed946bd824cda75629a5f1`.
It covers retained profiles/fleet rows from September 3, 21:00 UTC, and
routes/rejections from June 17, 00:00 UTC, through September 9, 00:48 UTC
(September 8, 17:48 PDT), exclusively. It starts with 4,282 hourly windows;
adaptive splitting may increase that count. The plan already exists at
`gs://darkbloom-mainnet-telemetry-archive/backfill-plans/v1/d91357b281aa29745bba8da91c05ab18c197da5feaed946bd824cda75629a5f1.json`.

## Steps

### 1. Publish the reviewed image

Build the exact reviewed commit locally for Linux/amd64 and push it under a
new archive-tool image name in the existing Artifact Registry repository.
Do not replace the coordinator image or deploy the coordinator service.

```sh
ARCHIVE_COMMIT=$(git rev-parse HEAD)
ARCHIVE_IMAGE="us-east4-docker.pkg.dev/darkbloom-mainnet/coordinator/telemetry-archive:${ARCHIVE_COMMIT}"
docker build --platform=linux/amd64 \
  --label "org.opencontainers.image.revision=${ARCHIVE_COMMIT}" \
  -t "$ARCHIVE_IMAGE" scripts/telemetry_archive
docker push "$ARCHIVE_IMAGE"
```

Resolve the pushed image digest and use `IMAGE@sha256:DIGEST` as
`ARCHIVE_DEPLOY_IMAGE` in the create command. Registry authentication is a
prerequisite; do not place access tokens in source files or command arguments.

### 2. Create the isolated job identity and limited grants

The proposed identity is
`telemetry-archive@darkbloom-mainnet.iam.gserviceaccount.com`.
It needs these grants, and no SQL/admin or object-delete role:

| Resource | Role | Purpose |
|---|---|---|
| Project `darkbloom-mainnet` | `roles/cloudsql.client` | Connect through the managed Cloud SQL proxy |
| Project `darkbloom-mainnet` | `roles/bigquery.jobUser` | Submit verification queries |
| Read-replica secret only | `roles/secretmanager.secretAccessor` | Read the existing SELECT-only database credential |
| Archive bucket only | `roles/storage.objectCreator` | Create immutable data and checkpoints |
| Archive bucket only | `roles/storage.objectViewer` | Read back objects |
| Archive bucket only | `roles/storage.legacyBucketReader` | Inspect bucket policy/location metadata |

```sh
gcloud iam service-accounts create telemetry-archive \
  --project=darkbloom-mainnet --display-name="Copy-only telemetry archive"

ARCHIVE_MEMBER="serviceAccount:telemetry-archive@darkbloom-mainnet.iam.gserviceaccount.com"
gcloud projects add-iam-policy-binding darkbloom-mainnet \
  --member="$ARCHIVE_MEMBER" --role=roles/cloudsql.client --condition=None
gcloud projects add-iam-policy-binding darkbloom-mainnet \
  --member="$ARCHIVE_MEMBER" --role=roles/bigquery.jobUser --condition=None
gcloud secrets add-iam-policy-binding darkbloom-kydo-read-replica-access \
  --project=darkbloom-mainnet --member="$ARCHIVE_MEMBER" \
  --role=roles/secretmanager.secretAccessor
gcloud storage buckets add-iam-policy-binding gs://darkbloom-mainnet-telemetry-archive \
  --member="$ARCHIVE_MEMBER" --role=roles/storage.objectCreator
gcloud storage buckets add-iam-policy-binding gs://darkbloom-mainnet-telemetry-archive \
  --member="$ARCHIVE_MEMBER" --role=roles/storage.objectViewer
gcloud storage buckets add-iam-policy-binding gs://darkbloom-mainnet-telemetry-archive \
  --member="$ARCHIVE_MEMBER" --role=roles/storage.legacyBucketReader
```

If an account/job already exists, inspect it rather than silently broadening
its permissions or replacing another workload. Partial setup is not a reason
to grant a project-wide storage-admin role.

### 3. Create and execute one bounded job

The initial configuration has one task, one concurrent reader, 2 vCPUs,
4 GiB RAM, a six-hour hard task timeout, and no automatic retries. The runner
checks its own 21,000-second budget between windows so it can exit and resume.

```sh
gcloud run jobs create darkbloom-telemetry-backfill \
  --project=darkbloom-mainnet --region=us-east4 \
  --image="$ARCHIVE_DEPLOY_IMAGE" \
  --service-account=telemetry-archive@darkbloom-mainnet.iam.gserviceaccount.com \
  --cpu=2 --memory=4Gi --tasks=1 --parallelism=1 \
  --task-timeout=21600s --max-retries=0 \
  --set-cloudsql-instances=darkbloom-mainnet:us-east4:d-inference-prod-pg17-ro \
  --set-secrets=/secrets/replica.json=darkbloom-kydo-read-replica-access:2 \
  --set-env-vars=ARCHIVE_ACCESS_FILE=/secrets/replica.json,ARCHIVE_EXPECTED_INSTANCE=darkbloom-mainnet:us-east4:d-inference-prod-pg17-ro \
  --args=run-backfill,--project,darkbloom-mainnet,--bucket,darkbloom-mainnet-telemetry-archive,--location,us-east4,--plan-id,d91357b281aa29745bba8da91c05ab18c197da5feaed946bd824cda75629a5f1,--max-run-seconds,21000 \
  --execute-now
```

Cloud Run uses the managed Cloud SQL socket for the replica. No coordinator
VM/container change, database migration, new secret value, public bucket access,
or deletion permission is required. Startup/socket/IAM connectivity must still
be verified on the first cloud execution; local tests do not certify it.

Current us-east4 list rates are $0.000018/vCPU-second and
$0.000002/GiB-second for jobs. A full six-hour attempt at this configuration
is approximately **$0.95 for compute**, before free allowances or discounts.
Storage, operations and BigQuery are additional. Each verification query is
capped at 1 GiB billed; this is a per-query cap, not a total backfill budget.
Runtime remains uncertain until a colocated sample is measured.

## Verification and resume

Read the execution status and checkpoint logs. Every new source capture first
checks physical recovery and replay age; more than 30 seconds of replay age
exits with code 75 and retains progress. All data reads retain the 15-second
statement timeout and 1-second lock timeout. Replica pressure must recover
before resuming. Do not run overlapping executions of this job.

Resume the same reviewed job/plan with `gcloud run jobs execute
darkbloom-telemetry-backfill --project=darkbloom-mainnet --region=us-east4`.
Completed windows are skipped after checking their object generations, and
persistent split boundaries prevent parent/child double counting. A timeout,
budget exit or high-lag stop is incomplete even if many windows were copied.

Completion requires every planned interval's leaf checkpoints and the
verified `backfills/v1/PLAN_ID/summary.json`. Per-table `catalogs/TABLE.json`
files list exact data objects from this plan; they exclude earlier pilots and
alternative overlapping snapshots. Use those catalogs for BigQuery table
definitions, never a broad wildcard over the archive bucket.

## Rollback

Cancel the running execution if necessary and stop invoking the job. Retain
the bucket's data and checkpoints for inspection/resume. There is no source
deletion or retention configuration to reverse. Service-account/job removal,
if later desired, is a separate approved operation.

## Related

- [Copy and verify snapshots](telemetry-archive.md)
- [Tool and checkpoint behavior](../../scripts/telemetry_archive/README.md)
- [Cloud Run Jobs](https://docs.cloud.google.com/run/docs/create-jobs)
- [Cloud SQL connections from Cloud Run](https://docs.cloud.google.com/sql/docs/postgres/connect-run)
- [Cloud Run pricing](https://cloud.google.com/run/pricing)
