"""Compile or execute SELECT-only analytics previews; never switch product readers."""

import re
from datetime import datetime
from decimal import Decimal

from google.cloud import bigquery

from . import cloud
from .analytics_sql import parameters, query_sql, source_tables
from .model import ArchiveError, stamp


def json_value(value):
    if isinstance(value, Decimal):
        return str(value)  # Exact sums can exceed both JavaScript precision and INT64.
    if isinstance(value, datetime):
        return stamp(value)
    return value


def preview(args):
    if not 1 <= args.maximum_bytes_billed <= 10 * 1024**3:
        raise ArchiveError("preview scan cap must be between 1 byte and 10 GiB")
    params = parameters(args.window, args.as_of, args.limit)
    sql = query_sql(args.project, args.dataset, args.catalog, args.query, args.metric)
    report = {
        "mode": "shadow",
        "serving_eligible": False,
        "retention_eligible": False,
        "source_completeness": "not_certified",
        "catalog_version": args.catalog,
        "window": args.window,
        "query": args.query,
        "parameters": {key: json_value(value) for key, value in params.items()},
        "sql": sql,
    }
    if not args.execute:
        return report
    if args.query == "usage-timeseries" and args.window == "all":
        raise ArchiveError("executed usage series requires a bounded 24h, 7d or 30d window")
    client = cloud.bigquery_client(args.project, args.location)
    dataset = client.get_dataset(f"{args.project}.{args.dataset}")
    if dataset.location.lower() != args.location.lower():
        raise ArchiveError("preview location differs from archive dataset")
    catalog_id = f"{args.project}.{args.dataset}.catalog_{args.catalog}"
    catalog = client.get_table(catalog_id)
    match = re.fullmatch(
        r"Verified archive catalog sha256=([0-9a-f]{64})", catalog.description or ""
    )
    if not match or match[1][:16] != args.catalog:
        raise ArchiveError("preview catalog identity mismatch")
    config = bigquery.QueryJobConfig(maximum_bytes_billed=args.maximum_bytes_billed)
    coverage = list(
        client.query(f"SELECT DISTINCT table_name FROM `{catalog_id}`", job_config=config).result(
            timeout=120
        )
    )
    if not set(source_tables(args.query)).issubset({row["table_name"] for row in coverage}):
        raise ArchiveError("preview catalog lacks required table coverage")
    config.query_parameters = [
        bigquery.ScalarQueryParameter("since", "TIMESTAMP", params["since"]),
        bigquery.ScalarQueryParameter("as_of", "TIMESTAMP", params["as_of"]),
        bigquery.ScalarQueryParameter("limit", "INT64", params["limit"]),
    ]
    job = client.query(sql, job_config=config)
    result = [
        {key: json_value(value) for key, value in row.items()} for row in job.result(timeout=120)
    ]
    return {
        **report,
        "rows": result,
        "job_id": job.job_id,
        "bytes_processed": job.total_bytes_processed,
    }
