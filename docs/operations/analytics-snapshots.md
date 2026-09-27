# Serve public analytics from verified snapshots

> Last updated: 2026-09-27 · commit `64c621e14`

Use the opt-in coordinator reader to serve leaderboard, network totals and network usage charts from a
small local snapshot, removing history scans from those request paths. This
runbook covers the reader and private artifact sync. A qualified producer and
complete, fresh source coverage are prerequisites, not provided by the copy-only
archive or its preview command.

## When to use

Use after continuous capture, analytical projections and financial/cohort
reconciliation have qualified an immutable result generation. Existing pilot
catalogs are incomplete and cannot supply a qualified production snapshot.

## Prerequisites

- Review/approval for the coordinator configuration/deployment and any new
  bucket read grant. Keep `EIGENINFERENCE_ANALYTICS_SNAPSHOT_PATH` unset until
  the end-to-end pipeline is ready.
- A private accounting bucket, with a qualified producer publishing an immutable
  `analytics/v1/snapshots/<sha256>.json` and atomically selecting it with
  `analytics/v1/current.json`. The pointer contains `name`, `generation`,
  `sha256`. A content hash is not proof of source completeness; qualification
  remains the producer's responsibility.
- A local sync worker running as the coordinator's operating-system user and
  using a read-only bucket identity. Do not give the coordinator a database
  export credential or public access to accounting objects.

## Steps

1. Produce a complete snapshot with schema version 1, immutable `generation`,
   `reconciliation_id`, `source_complete=true`, `source_complete_through`,
   `as_of`, `generated_at`, and `windows` for 24h/7d/30d/all. Every window includes
   `totals` matching `store.NetworkTotalsRow` and `leaderboards` for earnings,
   tokens and jobs matching `store.LeaderboardRow`. Supply exactly
   min(active_accounts,200) rows for each metric, ranked descending with account
   ID ascending as the tie breaker. When there are at most 200 active accounts,
   all metrics must contain the same account-ID set. Empty rankings must be arrays, not null.
   Use integer JSON amounts within signed INT64; never float-round or truncate.
   Include `series` for 30m/24h/7d/30d with `start_at`, `end_at`,
   `bucket_seconds` (60/1800/14400/43200), and `buckets` shaped as
   `store.UsageBucket`. Bounds are complete buckets ending at `as_of` rounded
   down to the bucket size. Buckets are strictly ordered, unique, aligned and
   within their half-open interval.
2. Run the explicitly bounded private sync command from the Python worker:

   ```sh
   telemetry-archive sync-analytics-snapshot \
     --project darkbloom-mainnet --bucket darkbloom-mainnet-accounting-history \
     --output /var/lib/darkbloom/analytics/current.json
   ```

   The parent directory must exist and be owned by the service user. For a container deployment, bind-mount the synchronized directory read-only at the configured container path. The sync
   verifies object generation/digest, refuses unqualified/oversized objects and
   atomically stages a mode 0600 file with fsync. Credential material stays in ADC
   or the environment. Its default workflow creates no recurring schedule.
3. After explicit deployment approval, set
   `EIGENINFERENCE_ANALYTICS_SNAPSHOT_PATH=/var/lib/darkbloom/analytics/current.json`.
   Keep the producer's 5-minute cadence; sync at least every minute. The coordinator
   polls the local file every 30s, avoiding additional source queries.
4. Check all leaderboard aliases, metrics and limits, and network totals windows.
   `updated_at` is the source `as_of`. Account IDs remain pseudonymized by the API.

## Verification

The `coordinator/analyticssnapshot` package validates an 8 MiB cap, complete windows
and ranks, exact work+reward sums without overflow, source/result freshness,
cohort cardinality, cross-metric values, deterministic rank order and generation
monotonicity. Every different generation must advance `as_of` or
`source_complete_through`, and neither may regress. Publish corrections with the
next qualified source cut.
It rejects changed content under the same generation. An invalid
refresh leaves the prior valid in-memory generation in place; every read checks
freshness again. Source and as-of age must be at most 10 minutes, result age at
most 15 minutes; future source times are rejected and generated time allows one
minute of clock skew.

With this mode configured, leaderboard/totals/series never fall back to historical
PostgreSQL queries, even on cold start or expiry. Missing/stale data returns 503.
The old network-totals database refresher is disabled. Stats, geography and private billing readers still use their existing paths. This mode
does not authorize retirement of their underlying detail.

`go test -race ./coordinator/analyticssnapshot ./coordinator/api -run
'TestSnapshot|TestCacheFailure|TestIncompleteTopRanks|TestArchiveAnalytics'`
checks validation, retained prior generations and HTTP behavior with a store
that fails the test if it is scanned. Python sync tests check immutable object
identity, private scope, hash mismatches and preservation of the previous file.

## Database mode while archive cutover is pending

Without the snapshot env var, leaderboard requests share one top-200 SQL result
per metric/canonical window for 5 minutes, including concurrent requests, aliases
and differing limits. Query/scan/iteration errors propagate as 503 and are not
cached as empty or partial results. Network totals refresh every 5 minutes and
retain an existing success for at most 15 minutes across failed refreshes. Network
usage charts cache successful results for 5 minutes. These changes reduce repeat
work without depending on archive completion. Live stats/geography retain their
existing refresh behavior.

## Rollback

Stop publication/sync of bad generations. A prior still-fresh validated snapshot
can continue serving within its freshness bounds. To return to the old database
path, remove the env var through an approved deployment **only while source
history is intact**. After future retention, restore/reconcile required source
history before attempting that rollback.

## Related

- [Accounting archive](accounting-history.md)
- [Next-stage retention and capture design](../design/archive-analytics-retention.md)
- [Coordinator deployment](coordinator-deploy.md)
