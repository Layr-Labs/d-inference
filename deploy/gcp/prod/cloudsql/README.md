# Production Cloud SQL PostgreSQL

This package prepares the production `darkbloom` Cloud SQL PostgreSQL deployment and its SOC 2 evidence. It is intentionally separate from the development bootstrap in `deploy/gcp/bootstrap.sh`.

Production mutations are human-operated. Nothing in this directory is invoked by Cloud Build.

## Design

```text
coordinator container
    |
    | PostgreSQL on 127.0.0.1:5432
    | existing database name/user/password
    v
Cloud SQL Auth Proxy (host systemd service)
    |
    | private IP + authenticated TLS
    v
Cloud SQL PostgreSQL
```

The coordinator contract remains:

```text
postgres://USER:PASSWORD@127.0.0.1:5432/DATABASE?sslmode=disable
```

`sslmode=disable` applies only to the loopback hop between the coordinator and the host proxy. The proxy authenticates with the VM service account and encrypts the Cloud SQL connection.

Do not enable Cloud SQL connector enforcement until every production database client has been inventoried and migrated. The coordinator, administrative access, migrations, reporting jobs, and any read-only consumers must be tested first.

## Files

| File | Purpose |
|---|---|
| `config.example.env` | Reviewed input values for the production instance |
| `provision.sh` | Validates or creates the production instance; defaults to read-only planning |
| `cloud-sql-proxy.service` | Host-local persistent proxy unit |
| `cloud-sql-proxy.env.example` | Proxy instance connection name |
| `collect-evidence.sh` | Collects non-secret, dated SOC 2 configuration evidence |
| `restore-test.md` | Controlled PITR/restore exercise and evidence template |
| `soc2-control-mapping.md` | Maps deployment controls to required operating evidence |

## Proposed Baseline

`provision.sh` proposes:

- PostgreSQL 16, Enterprise edition;
- regional high availability;
- private IP only;
- Cloud SQL `sslMode=ENCRYPTED_ONLY`;
- Data API disabled;
- automated backups and point-in-time recovery;
- 30 retained backups and 7 days of transaction logs by default;
- instance deletion protection and retained backups on deletion;
- storage auto-increase;
- an instance password policy for built-in database users;
- a defined maintenance window;
- optional pgAudit bootstrap flags;
- no connector enforcement during migration.

The actual values must be approved against the production RTO, RPO, data classification, expected load, and cost model.

## Preparation

1. Copy `config.example.env` outside source control and fill in the reviewed values.
2. Confirm the selected VPC already has, or may safely receive, a private services access range.
3. Confirm the production VM uses a dedicated service account with:
   - `roles/cloudsql.client`;
   - access only to the required Secret Manager secrets;
   - no service-account JSON key.
4. Confirm Cloud SQL capacity supports the coordinator pool. The coordinator currently uses at least 10 and up to 80 connections.
5. Decide whether pgAudit is required and which statement classes are proportionate.

## Plan and Apply

The default mode performs read-only validation and prints the proposed command:

```bash
CONFIG_FILE=/secure/path/darkbloom-cloudsql.env \
  deploy/gcp/prod/cloudsql/provision.sh --plan
```

Only a human operator may apply:

```bash
CONFIG_FILE=/secure/path/darkbloom-cloudsql.env \
  deploy/gcp/prod/cloudsql/provision.sh --apply
```

The script refuses to alter an existing instance. Existing-instance remediation must be reviewed as a separate change because network, HA, SSL, and database-flag changes can restart the instance or break clients.

## Proxy Installation

1. Install a reviewed, pinned Cloud SQL Auth Proxy v2 binary on the production VM.
2. Verify its published checksum before placing it at `/usr/local/bin/cloud-sql-proxy`.
3. Copy `cloud-sql-proxy.service` to `/etc/systemd/system/`.
4. Create `/etc/d-inference/cloud-sql-proxy.env` from the example with mode `0600`.
5. Validate on an unused local port before replacing the existing database path.
6. Enable and start the service only during the approved change window.

The unit listens on loopback only and uses private IP. It does not manage the application database password.

## Migration With Minimal Client Change

1. Provision Cloud SQL without changing the current RDS connection.
2. Restore or replicate data using the approved migration method.
3. Run a second proxy listener on `127.0.0.1:15432`.
4. Validate schema, migrations, billing invariants, and representative reads/writes.
5. Freeze or synchronize writes according to the migration plan.
6. Update only `EIGENINFERENCE_DATABASE_URL` to use `127.0.0.1:5432`.
7. Restart the coordinator and run production health/business checks.
8. Preserve the old RDS path for the approved rollback window.
9. Remove obsolete access only after the soak and reviewer approval.

Do not combine this cutover with IAM database authentication, PgBouncer, connector enforcement, or a broad pgAudit rollout.

## SOC 2 Evidence

Collect configuration after provisioning and monthly during the Type 2 period:

```bash
deploy/gcp/prod/cloudsql/collect-evidence.sh \
  --project darkbloom-mainnet \
  --instance darkbloom \
  --output /secure/evidence/root
```

Store the resulting dated directory in the approved evidence repository and complete its `review.md`. Evidence collection does not prove operating effectiveness by itself; retain access reviews, alerts, incidents, change approvals, backup history, and restore-test results.

## Current Production Warning

The canonical production runbook currently identifies AWS RDS as the production database. This package is preparatory until the migration is approved, executed, validated, and reflected in `docs/operations/coordinator-deploy.md`.
