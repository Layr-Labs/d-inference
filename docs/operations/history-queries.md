# Run asynchronous historical queries

> Last updated: 2026-10-05

Submit operator-controlled SELECTs over a pinned archive catalog, then poll,
page results or request cancellation without blocking a coordinator request.
This queries captured history; it does not certify complete history or authorize
source retirement. See the [storage plan](../design/operational-history-retention.md).

## When to use

Use for ad hoc analysis of the currently supported telemetry or accounting
tables. Repeated large queries should use qualified incremental analytical
projections rather than continually scan external files. This CLI is not an
untrusted-user SQL service and must not be exposed directly as an HTTP endpoint.

## Prerequisites

- An approved identity with BigQuery job access and read access to the intended
  dataset and underlying bucket. Accounting authorization must hold at both
  layers; a private dataset does not hide readable raw GCS objects.
- A successfully published coverage-format-2 catalog and its external tables.
  The [observed cloud catalogs](../reports/2026-10-05-history-storage-baseline.md)
  predate this format; deploying the new publisher and republishing checkpoints
  require separate approval. Do not relabel old catalogs to bypass validation.
- Qualified protection against changes to the selected catalog, manifests and
  data objects for the query's lifetime. An external table reads object URIs,
  not the generation column recorded in a catalog. Versioning is not immutability.
- Python environment installed as described in the
  [worker instructions](../../scripts/telemetry_archive/README.md#run).

## Steps

1. Select the catalog version from a successful `publish-catalog` result.
   Use the same explicit catalog for every input. Never derive publication
   readiness by listing partially created catalog tables.
2. Prepare a UTF-8 SQL file containing a SELECT over the declared `archive_`
   table names. For example, `usage-by-model.sql` can contain:

   ```sql
   SELECT model,
          COUNT(*) AS requests,
          SUM(CAST(prompt_tokens AS BIGNUMERIC)) AS prompt_tokens
   FROM archive_usage
   WHERE source_time >= TIMESTAMP('2026-09-01 00:00:00+00')
     AND source_time < TIMESTAMP('2026-09-02 00:00:00+00')
   GROUP BY model
   ORDER BY requests DESC
   ```

   Choose bounds appropriate for the captured source coverage. Missing history
   is not zero activity. The command prepends pinned reader CTEs; a nested
   subquery may have its own CTEs. Do not reference moving table aliases.
3. Submit with an explicit job identity and scan cap:

   ```sh
   telemetry-archive query-submit \
     --project darkbloom-mainnet --location us-east4 \
     --dataset accounting_history --catalog CATALOG_VERSION \
     --tables usage --sql-file usage-by-model.sql \
     --job-id archive-query-usage-by-model-20261005 \
     --maximum-bytes-billed 1073741824
   ```

   Submission checks catalog metadata and dry-runs the query before inserting
   the named job. It does not wait for execution to complete. A retry with the
   same job identity must use the same SQL and configuration; a changed request
   needs a different identity. If a transport timeout leaves submission
   uncertain, retry the same identity rather than creating another paid job.
4. Poll the returned job, then page its successful results:

   ```sh
   telemetry-archive query-status \
     --project darkbloom-mainnet --location us-east4 \
     --job-id archive-query-usage-by-model-20261005 --max-results 100
   ```

   Running jobs return status only. Completed jobs return one bounded page;
   pass its `next_page_token` using `--page-token` to continue. Numeric/BigNumeric
   decimal values remain exact strings, timestamps are ISO-formatted and bytes
   are base64. Keep result output private. BigQuery temporary results expire;
   they are not the durable historical store.
5. To stop unwanted work, request cancellation:

   ```sh
   telemetry-archive query-cancel \
     --project darkbloom-mainnet --location us-east4 \
     --job-id archive-query-usage-by-model-20261005
   ```

   Cancellation is best effort. Poll again to establish the terminal outcome;
   it does not undo work already billed.

## Verification

`async_query.submit` in
`scripts/telemetry_archive/src/telemetry_archive/async_query.py` validates standard
SQL SELECT metadata, restricts referenced tables to the pinned inputs, and
rejects scripts, writes, referenced routines and missing validation metadata.
Job labels and configuration fingerprints bind retries and status operations;
they are not an authorization boundary against a principal that can forge jobs.

The scan cap defaults to 1 GiB and cannot exceed 10 GiB. Query execution requests
a 120-second server timeout; this is not a guarantee of immediate cancellation.
SQL files are capped at 1 MiB and result pages at 1,000 rows. RPCs are bounded;
query failure text is withheld because cloud errors may include SQL or values.
The initial table-coverage inspection is bounded; failure to establish coverage
must not be treated as permission to query unvalidated inputs.

Verify result semantics against a source cut before using outputs in a product.
This command always reports `serving_eligible=false`, `retention_eligible=false`
and uncertified source completeness, even when the query succeeds.

## Rollback

Stop submitting queries and request cancellation of owned jobs if appropriate.
No coordinator configuration, source records or published archive pointers are
changed by these commands. Keep archive evidence intact.

## Related

- [Accounting archive](accounting-history.md)
- [Telemetry archive publication](telemetry-history.md)
- [Public serving snapshots](analytics-snapshots.md)
