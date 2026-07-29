# Cloud SQL SOC 2 Control Mapping

This mapping connects the production deployment package to the `darkbloom` Cloud SQL controls maintained in the `security-soc2` repository.

Implementation code demonstrates control design. Audit readiness also requires evidence that the deployed settings exist and the controls operated throughout the Type 2 period.

| Control area | Deployment coverage | Operating evidence still required |
|---|---|---|
| Scope and ownership | `config.example.env`, production runbook | Approved owners, data classification, applications/databases, RTO/RPO, architecture diagram |
| Encryption in transit | `sslMode=ENCRYPTED_ONLY`; host-local proxy unit | Instance export, proxy service status/version, plaintext rejection test, client inventory |
| Private networking | Private services access, private IP only, proxy `--private-ip` | VPC/range/peering exports, instance IP export, connectivity test, public-IP absence |
| Connection authorization | Proxy uses the production VM identity | VM service account attachment, `roles/cloudsql.client` review, impersonation/key review |
| Database authorization | Migration preserves current database contract | Sanitized PostgreSQL roles/grants, separate service identity decision, quarterly review |
| Credentials and password policy | Built-in-user password policy; URL remains in existing root-only environment/secret flow | Secret Manager IAM, secret version/rotation records, no secret values in evidence |
| Administrative audit logs | Cloud SQL Admin Activity logs are inherited from Cloud Audit Logs | Representative log query, centralized sink/retention, monthly review |
| SQL activity audit | Optional `cloudsql.enable_pgaudit` bootstrap support | Approved classes/objects, `CREATE EXTENSION` change, pgAudit settings, sample events, volume/privacy review |
| Backup and PITR | Automated backup, PITR, retained backups/transaction logs | Successful backup history, failure alert, approved retention, monthly review |
| Restore testing | `restore-test.md` | Executed test, achieved RTO/RPO, validation, issue closure, target deletion evidence |
| Availability | Regional HA default | Approved availability decision, failover test, application reconnect evidence |
| Data protection | Private-only instance and Google-managed encryption by default | Encryption configuration; CMEK decision if customer/data requirements demand it |
| Deletion protection | Instance deletion protection and backup retention on delete | Instance export, IAM review, alert/query for protection changes |
| Monitoring | Evidence collector inventories monitoring policies | Alert policies, notification channels, delivery tests, incident/triage records |
| Logging retention | Evidence collector inventories sinks and global log buckets | Approved retention period, all applicable bucket locations/SIEM configuration, access review |
| Change management | Human-only `--apply`; existing instance changes refused | PR, approval, ticket, plan output, operator identity, operation logs, rollback plan |
| Configuration evidence | `collect-evidence.sh` and generated reviewer checklist | Dated monthly packages, reviewer signoff, exceptions and remediation |

## Controls Not Automatically Satisfied

The following require explicit human decisions or operating records:

- whether Availability, Confidentiality, or Processing Integrity are in audit scope;
- pgAudit statement classes and sensitive-object coverage;
- log-retention duration;
- credential rotation cadence;
- VPC Service Controls applicability;
- connector enforcement after migration;
- PgBouncer or managed connection pooling;
- database-user and schema-level least privilege;
- recovery and failover test cadence.

Do not describe these controls as implemented until live GCP and PostgreSQL evidence has been reviewed.

