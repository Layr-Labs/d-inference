"""Verify a single immutable snapshot with a temporary BigQuery external table."""

from google.cloud import bigquery

from .model import ArchiveError, stamp, utc

VERIFY_SQL = """
SELECT COUNT(*) AS row_count, COUNT(DISTINCT source_id) AS distinct_ids,
       MIN(source_id) AS min_id, MAX(source_id) AS max_id,
       MIN(source_time) AS first_time, MAX(source_time) AS last_time,
       COUNTIF(row_json IS NULL OR row_sha256 IS NULL OR
               TO_HEX(SHA256(row_json)) != row_sha256) AS invalid_hashes,
       COUNTIF(source_time IS NULL OR source_time < @start OR source_time >= @end) AS outside_window
FROM archive_snapshot
"""


def verify_query(client, published: dict, *, maximum_bytes_billed: int = 1024**3) -> dict:
    if not 1 <= maximum_bytes_billed <= 10 * 1024**3:
        raise ArchiveError("BigQuery verification budget must be at most 10 GiB")
    receipt = published["snapshot"]
    # The live jobs API rejected NEW_LINE_DELIMITED_MANIFEST in a temporary
    # table definition. Use the exact URI already checked against our manifest;
    # never broaden discovery to a wildcard containing overlapping snapshots.
    external = bigquery.ExternalConfig("PARQUET")
    external.autodetect = True
    external.source_uris = [f"gs://{published['bucket']}/{published['data']['name']}"]
    config = bigquery.QueryJobConfig(
        table_definitions={"archive_snapshot": external},
        maximum_bytes_billed=maximum_bytes_billed,
        use_query_cache=False,
        use_legacy_sql=False,
        labels={"purpose": "telemetry-archive-verify", "mode": "copy-only"},
        query_parameters=[
            bigquery.ScalarQueryParameter("start", "TIMESTAMP", utc(receipt["start"])),
            bigquery.ScalarQueryParameter("end", "TIMESTAMP", utc(receipt["end"])),
        ],
    )
    job = client.query(VERIFY_SQL, job_config=config, location=published["location"])
    rows = list(job.result(timeout=180))
    if len(rows) != 1:
        raise ArchiveError("BigQuery returned an unexpected verification result")
    actual = dict(rows[0])
    for field in ("first_time", "last_time"):
        actual[field] = stamp(actual[field]) if actual[field] is not None else None
    stats = receipt["stats"]
    expected = {key: stats[key] for key in ("min_id", "max_id", "first_time", "last_time")}
    expected.update(
        row_count=stats["rows"], distinct_ids=stats["rows"], invalid_hashes=0, outside_window=0
    )
    if actual != expected:
        raise ArchiveError("BigQuery results differ from the verified source snapshot")
    return {
        "verified": True,
        "artifact_id": receipt["artifact_id"],
        "job_id": job.job_id,
        "bytes_processed": job.total_bytes_processed,
        "bytes_billed": job.total_bytes_billed,
        "result": actual,
    }
