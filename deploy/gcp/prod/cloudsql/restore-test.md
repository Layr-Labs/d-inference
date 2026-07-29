# `darkbloom` Cloud SQL PITR and Restore Test

## Safety

This is a human-operated production recovery exercise. It creates a separate Cloud SQL instance and may incur cost. It must not overwrite or modify the production source instance.

Before execution:

- obtain change and data-owner approval;
- select a point before the latest restorable time but inside the retained transaction-log window;
- confirm the target name, project, region, network, and cleanup owner;
- confirm the restored data may exist temporarily under the production data classification;
- prevent applications from accidentally connecting to the restored target;
- define validation queries that do not export customer data into tickets or logs.

## Test Record

| Field | Value |
|---|---|
| Source instance | `darkbloom` |
| Source project | `darkbloom-mainnet` |
| Target instance | `[darkbloom-restore-YYYYMMDD]` |
| Approved restore point UTC | `[INSERT]` |
| Test owner | `[INSERT]` |
| Data owner approval | `[INSERT]` |
| Change ticket | `[INSERT]` |
| Approved RTO | `[INSERT]` |
| Approved RPO | `[INSERT]` |
| Start time UTC | `[INSERT]` |
| Restore available time UTC | `[INSERT]` |
| Validation complete time UTC | `[INSERT]` |
| Actual recovery duration | `[INSERT]` |
| Actual recovery point | `[INSERT]` |
| Result | `[Pass / Exception]` |

## Procedure

1. Capture the source instance configuration and latest restorable time.
2. Record the selected restore point and approvals.
3. Restore to a new target instance using the current documented Cloud SQL PITR command/API.
4. Ensure the target uses the approved private network and has no public IP.
5. Do not direct production traffic or production DNS at the target.
6. Connect through a temporary local Cloud SQL Proxy listener using an authorized test identity.
7. Validate:
   - PostgreSQL starts and accepts authenticated connections;
   - required databases and schemas exist;
   - migration/schema version is expected;
   - selected table counts or privacy-safe checksums are plausible;
   - ledger/accounting invariants pass;
   - release and model-registry records are readable;
   - a representative application read path works;
   - no production writes were sent to the restored target.
8. Record timestamps and compare actual RTO/RPO with approved targets.
9. Record defects and remediation owners.
10. Export operation/configuration evidence.
11. Delete the test target after evidence and remediation records are accepted.
12. Capture the deletion audit event and close the change ticket.

Always obtain the current command syntax from the Google Cloud documentation before execution:

- https://cloud.google.com/sdk/gcloud/reference/sql/instances/point-in-time-restore
- https://cloud.google.com/sql/docs/postgres/backup-recovery/pitr

## Evidence Checklist

- [ ] Approved change ticket and data-owner approval.
- [ ] Source configuration before the test.
- [ ] Selected point-in-time and latest-restorable-time evidence.
- [ ] Cloud SQL restore operation ID and timestamps.
- [ ] Target configuration proving private-only access.
- [ ] Privacy-safe validation output.
- [ ] RTO/RPO calculation and reviewer signoff.
- [ ] Issues and remediation tickets.
- [ ] Target deletion evidence.
- [ ] Audit-log event for restoration and deletion.

## Review

| Field | Value |
|---|---|
| Reviewer | `[INSERT]` |
| Review date | `[INSERT]` |
| RTO met | `[Yes / No]` |
| RPO met | `[Yes / No]` |
| Follow-up required | `[INSERT]` |

