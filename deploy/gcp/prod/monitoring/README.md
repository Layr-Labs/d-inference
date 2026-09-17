# Production backup-integrity monitoring

Alert policies that page on backup failure for the production coordinator's two
backed-up data stores. Checked in as code because, before this directory
existed, all nine production alert policies lived only as console/CLI state in
`darkbloom-mainnet` with no definition in any repository — no review, no diff, no
record of who changed a threshold. That absence is itself a change-management
finding, independent of what the policies do.

Everything here targets project `darkbloom-mainnet` and routes to the existing
notification channel `Darkbloom Production PagerDuty`
(`projects/darkbloom-mainnet/notificationChannels/9823153599696034473`).

## What is covered

| Store | What backs it up | Alert |
|---|---|---|
| Cloud SQL `d-inference-prod-pg17` (database `eigeninference`) | Daily automated backup 00:00–04:00 UTC + PITR, 35-day transaction-log retention, 36 retained backups, `us` multi-region | `Darkbloom Cloud SQL backup failed`, `Darkbloom Cloud SQL backup missing` |
| PD `darkbloom-coordinator-data` at `/mnt/disks/userdata` — MicroMDM BoltDB | Resource policy `darkbloom-data-daily`, 07:00 daily, 30-day retention, `us` multi-region | `Darkbloom persistent-disk snapshot failed` |

The MicroMDM BoltDB is not covered by any Cloud SQL backup and is not
reconstructible from Postgres. Losing it while `MIN_TRUST=hardware` drops the
whole provider fleet to `self_signed` — a full outage until every provider
re-enrolls. See the 2026-07-04 incident in
`docs/operations/coordinator-deploy.md`.

## Files

| File | Purpose |
|---|---|
| `logmetric-cloudsql-automated-backup.json` | Log-based counter over automated-backup window events; backs the absence check |
| `alert-cloudsql-backup-failed.json` | Log-match: a backup window closed with `windowStatus != STATUS_SUCCEEDED` |
| `alert-cloudsql-backup-missing.json` | Threshold + missing-data: no backup window at all |
| `alert-pd-snapshot-failed.json` | Log-match: a scheduled PD snapshot logged `severity>=ERROR` |
| `apply.sh` | `--plan` (default, read-only) / `--apply` (human-operated) |

## Applying

```bash
./apply.sh            # plan — read-only, prints what would change
./apply.sh --apply    # HUMAN ONLY
```

Per `CLAUDE.md`, mutation of production is human-only; `--plan` is the default so
an agent can verify the plan and a human runs the apply. `apply.sh` preflights
that the notification channel and the Cloud SQL instance both exist, and updates
rather than duplicates a policy that already exists under the same
`displayName`.

## Design notes

**Why three policies and not one.** The Monitoring API requires that a
`conditionMatchedLog` condition be the *only* condition in its policy — log-match
cannot be combined with `conditionThreshold` or `conditionAbsent`. The two
log-match conditions therefore each need their own policy, and the absence check
needs a third.

**Why an absence check at all.** Failure-only alerting is the classic gap an
auditor probes: it is silent precisely when backups have been turned off, when
the instance has been renamed or replaced, or when audit logging has broken. In
all three cases a failure alert reports nothing, which reads as health. The
absence policy sets `evaluationMissingData: EVALUATION_MISSING_DATA_ACTIVE`, so
no data evaluates as a violation.

**The window arithmetic, because it is easy to get wrong.** Alerting policies cap
`alignmentPeriod` at 90,000s (25h) — a naive 48h window is rejected by the API.
Backups run inside a 00:00–04:00 UTC window, so two consecutive *legitimate*
backups can be nearly 28h apart (00:00 one day, 04:00 the next). A 25h window
alone would therefore false-page on ordinary jitter. Adding `duration: 28800s`
(8h) requires the condition to stay violated for 8h before firing, giving a
33h tolerance against a ~28h worst-case legitimate gap — about 5h of margin,
and genuine loss of backup coverage still pages within a day and a half.

**Creation order matters, and applying it takes two passes.** Log-based metrics
do not backfill — they count only log entries written after the metric was
created. So a metric created now has no data until the next daily backup window,
no matter how many backup events already sit in the log. Creating the absence
policy in the same pass would page the on-call 8h later for a condition that is
not real. `apply.sh` therefore gates the absence policy on the metric having
*pre-existed* the run: pass 1 creates the metric and the two log-match policies,
pass 2 (a day later, after a real backup window has been counted) creates the
absence policy. On-demand backups do not substitute — they emit a different
`methodName` and will not match the filter.

**Validation status.** JSON well-formedness, the fields `apply.sh` reads, and
shell syntax are checked locally. The policy bodies have *not* been accepted by
the live Monitoring API yet, because doing so means creating real policies. The
25h alignment cap and the log-match exclusivity rule above were both taken from
the API reference rather than from a successful create. Run `--plan` first; if
`--apply` rejects a field, the error names it.

## Known gaps

- **Snapshot-schedule detachment is not alerted.** `alert-pd-snapshot-failed`
  catches snapshots that run and fail, not the resource policy being detached or
  deleted — that silence looks identical to health. Closing it needs the same
  log-metric-plus-absence shape used for Cloud SQL, over `ScheduledSnapshots`
  events for `resource.labels.disk_id` of `darkbloom-coordinator-data`.
- **Restore testing is not automated or scheduled.** A backup that has never been
  restored is an assumption, not a control. SOC 2 will ask for evidence of a
  successful restore, not evidence of a successful backup.
- **No alert on backup configuration change.** Disabling PITR or shortening
  retention is an audit-loggable mutation
  (`cloudsql.instances.update`) that currently pages nobody; the absence policy
  only catches a *full* stop.
- **Instance names are hardcoded in every filter.** If production moves again —
  as it just did, from AWS RDS to `d-inference-prod-pg17` — these filters match
  nothing and fail silently open. `apply.sh` preflights the instance name; a
  migration runbook step must re-run it.
- **The four `Darkbloom DMS *` policies are now dead weight.** Migration job
  `eigeninference-rds-to-cloudsql` is `COMPLETED`; those policies can be deleted
  with the DMS connection profiles.
