"""Operator-only, asynchronous SELECTs over explicitly pinned archive readers.

Labels identify this tool's jobs, not an authorization boundary. IAM must restrict
the operator and keep published catalogs/manifests immutable. This does not prove
GCS object generations, source completeness, or retention readiness.
"""

import base64
import hashlib
import json
import math
import re
from datetime import date, datetime, time
from decimal import Decimal

from google.api_core.exceptions import Conflict, GoogleAPIError
from google.cloud import bigquery

from . import cloud
from .model import TABLES, ArchiveError
from .publish import CATALOG_SCHEMA, FILE_SCHEMA, reader_sql, validate_destination
from .scope import require_dataset_scope

MAX_BYTES_BILLED = 10 * 1024**3
JOB_TIMEOUT_MS = 120_000
MAX_SQL_BYTES = 1024**2
MAX_COVERAGE_ROWS = 10_000
RPC = {"timeout": 30, "retry": None}
TOOL = "custom_query_v1"


def _identity(args):
    # Status/cancel deliberately require no SQL file or dataset argument.
    if not re.fullmatch(r"[a-z][a-z0-9-]{4,62}", args.project):
        raise ArchiveError("invalid project")
    if not re.fullmatch(r"[a-zA-Z0-9-]{1,63}", args.location):
        raise ArchiveError("invalid location")
    if not re.fullmatch(r"archive-query-[a-zA-Z0-9_-]{1,128}", args.job_id or ""):
        raise ArchiveError("job ID must be archive-query- followed by 1-128 safe characters")


def _configuration(job):
    """Remove only server-assigned fields from the immutable request identity."""
    config = job.to_api_repr()["configuration"]
    config.pop("labels", None)
    if config.get("jobType") == "QUERY":
        config.pop("jobType")
    if config.get("dryRun") is False:
        config.pop("dryRun")
    destination = config.get("query", {}).pop("destinationTable", None)
    if destination and (
        destination.get("projectId") != job.project
        or not destination.get("datasetId", "").startswith("_")
    ):
        raise ArchiveError("query job does not use private temporary results")
    return config


def _fingerprint(project, location, catalog, config):
    payload = json.dumps([project, location.lower(), catalog, config], sort_keys=True).encode()
    # BigQuery label values are limited to 63 characters.
    return hashlib.sha256(payload).hexdigest()[:63]


def _owned(job, args):
    labels = job.labels or {}
    if (
        job.job_type != "query"
        or job.job_id != args.job_id
        or job.project != args.project
        or (job.location or "").lower() != args.location.lower()
        or labels.get("archive_tool") != TOOL
        or not re.fullmatch(r"[0-9a-f]{16}", labels.get("archive_catalog", ""))
    ):
        raise ArchiveError("job is not an owned archive query in the requested project/location")
    config = _configuration(job)
    query = config.get("query", {})
    try:
        maximum_bytes_billed = int(query.get("maximumBytesBilled", 0))
    except (TypeError, ValueError):
        raise ArchiveError("archive query byte limit metadata is invalid") from None
    if (
        query.get("useLegacySql") is not False
        or query.get("useQueryCache") is not False
        or not 1 <= maximum_bytes_billed <= MAX_BYTES_BILLED
        or str(config.get("jobTimeoutMs")) != str(JOB_TIMEOUT_MS)
        or labels.get("archive_request")
        != _fingerprint(args.project, args.location, labels["archive_catalog"], config)
    ):
        raise ArchiveError("archive query configuration identity mismatch")
    return job


def _report(job):
    return {
        "job_id": job.job_id,
        "project": job.project,
        "location": job.location,
        "state": job.state,
        "catalog_version": job.labels["archive_catalog"],
        "serving_eligible": False,
        "retention_eligible": False,
        "source_completeness": "not_certified",
    }


def _validate_catalog(client, args, tables):
    dataset = client.get_dataset(f"{args.project}.{args.dataset}", **RPC)
    if (dataset.location or "").lower() != args.location.lower():
        raise ArchiveError("query location differs from archive dataset")
    prefix = f"{args.project}.{args.dataset}"
    catalog = client.get_table(f"{prefix}.catalog_{args.catalog}", **RPC)
    match = re.fullmatch(
        r"Verified archive catalog sha256=([0-9a-f]{64})", catalog.description or ""
    )
    if (
        not match
        or match[1][:16] != args.catalog
        or catalog.table_type != "TABLE"
        or (catalog.labels or {}).get("archive_coverage") != "plan_windows_v2"
        or catalog.schema != CATALOG_SCHEMA
    ):
        raise ArchiveError("archive catalog metadata mismatch")
    missing = set(tables)
    coverage = client.list_rows(
        catalog,
        selected_fields=[bigquery.SchemaField("table_name", "STRING")],
        max_results=MAX_COVERAGE_ROWS,
        page_size=MAX_COVERAGE_ROWS,
        **RPC,
    )
    for row in coverage:
        missing.discard(row["table_name"])
        if not missing:
            break
    if missing:
        raise ArchiveError("catalog lacks required table coverage within the bounded metadata read")
    allowed = {(args.project, args.dataset, f"catalog_{args.catalog}")}
    for table in tables:
        name = f"{table}_files_{args.catalog}"
        external = client.get_table(f"{prefix}.{name}", **RPC)
        config = external.external_data_configuration
        manifest_suffix = f"/query-manifests/v1/{args.catalog}/{table}.txt"
        sources = (config.source_uris or []) if config else []
        if (
            external.table_type != "EXTERNAL"
            or not config
            or config.source_format != "PARQUET"
            or config.to_api_repr().get("fileSetSpecType")
            != "FILE_SET_SPEC_TYPE_NEW_LINE_DELIMITED_MANIFEST"
            or len(sources) != 1
            or not sources[0].startswith("gs://")
            or not sources[0].endswith(manifest_suffix)
            or "*" in sources[0]
            or tuple((f.name, f.field_type, f.mode) for f in external.schema) != FILE_SCHEMA
        ):
            raise ArchiveError("archive external table metadata mismatch")
        allowed.add((args.project, args.dataset, name))
    return allowed


def _validate_dry_run(job, allowed, maximum_bytes_billed):
    # QueryJob.to_api_repr() serializes a submission, omitting response statistics.
    # Inspect the response to distinguish missing metadata from empty references.
    metadata = job._properties.get("statistics", {}).get("query", {})
    references = metadata.get("referencedTables")
    if (
        job.state != "DONE"
        or job.error_result
        or job.errors
        or job.statement_type != "SELECT"
        or not isinstance(references, list)
        or not references
        or len(references) >= 50  # BigQuery does not guarantee a complete list at this size.
        or metadata.get("referencedRoutines")
        or metadata.get("undeclaredQueryParameters")
        or job.total_bytes_processed is None
    ):
        raise ArchiveError("dry run must report a complete SELECT over pinned archive tables")
    for ref in references:
        if (
            not isinstance(ref, dict)
            or (ref.get("projectId"), ref.get("datasetId"), ref.get("tableId")) not in allowed
        ):
            raise ArchiveError("dry run references a table outside the selected archive catalog")
    if not 0 <= job.total_bytes_processed <= maximum_bytes_billed:
        raise ArchiveError("dry run exceeds the query byte limit")


def submit(args):
    """Validate then insert a named job; never wait for query execution."""
    _identity(args)
    validate_destination(args.project, args.dataset)
    if not re.fullmatch(r"[0-9a-f]{16}", args.catalog):
        raise ArchiveError("invalid catalog identity")
    tables = sorted(set(args.tables))
    if not tables or any(table not in TABLES for table in tables):
        raise ArchiveError("select at least one allowlisted archive table")
    require_dataset_scope(args.dataset, tables)
    if not 1 <= args.maximum_bytes_billed <= MAX_BYTES_BILLED:
        raise ArchiveError("query scan cap must be between 1 byte and 10 GiB")
    try:
        with args.sql_file.open("rb") as stream:
            source = stream.read(MAX_SQL_BYTES + 1)
        if not source.strip() or len(source) > MAX_SQL_BYTES:
            raise ArchiveError("SQL file must contain 1 byte to 1 MiB of UTF-8 SQL")
        source = source.decode("utf-8")
    except (OSError, UnicodeError):
        raise ArchiveError("cannot read UTF-8 SQL file") from None
    readers = [
        f"archive_{table} AS (\n{reader_sql(args.project, args.dataset, table, args.catalog)}\n)"
        for table in tables
    ]
    sql = "WITH " + ",\n".join(readers) + "\n" + source
    config = bigquery.QueryJobConfig(
        use_legacy_sql=False,
        use_query_cache=False,
        maximum_bytes_billed=args.maximum_bytes_billed,
        job_timeout_ms=JOB_TIMEOUT_MS,
        priority="INTERACTIVE",
        create_disposition="CREATE_IF_NEEDED",
        write_disposition="WRITE_EMPTY",
    )
    identity_config = config.to_api_repr()
    identity_config["query"]["query"] = sql
    config.labels = {
        "archive_tool": TOOL,
        "archive_catalog": args.catalog,
        "archive_request": _fingerprint(args.project, args.location, args.catalog, identity_config),
    }
    try:
        client = cloud.bigquery_client(args.project, args.location)
        allowed = _validate_catalog(client, args, tables)
        dry_config = bigquery.QueryJobConfig.from_api_repr(config.to_api_repr())
        dry_config.dry_run = True
        dry = client.query(
            sql,
            job_config=dry_config,
            project=args.project,
            location=args.location,
            job_retry=None,
            **RPC,
        )
        _validate_dry_run(dry, allowed, args.maximum_bytes_billed)
        reused = False
        try:
            job = client.query(
                sql,
                job_config=config,
                job_id=args.job_id,
                project=args.project,
                location=args.location,
                job_retry=None,
                **RPC,
            )
        except Conflict:
            job = client.get_job(args.job_id, project=args.project, location=args.location, **RPC)
            reused = True
        _owned(job, args)
        if job.labels != config.labels or _configuration(job) != identity_config:
            raise ArchiveError("job ID is already bound to a different query or configuration")
        return {**_report(job), "reused": reused}
    except GoogleAPIError:
        # BigQuery error messages can quote SQL and private row values.
        raise ArchiveError("BigQuery query submission failed; cloud error text withheld") from None


def _json_value(value):
    if isinstance(value, (dict, bigquery.Row)):
        return {key: _json_value(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_json_value(item) for item in value]
    if isinstance(value, Decimal):
        return str(value)
    if isinstance(value, (datetime, date, time)):
        return value.isoformat()
    if isinstance(value, bytes):
        return base64.b64encode(value).decode("ascii")
    if isinstance(value, float) and not math.isfinite(value):
        return str(value)
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    raise ArchiveError("unsupported BigQuery result value type")


def status(args):
    """Read one job snapshot and, only when successful, one bounded result page."""
    _identity(args)
    if not 1 <= args.max_results <= 1000:
        raise ArchiveError("max-results must be between 1 and 1000")
    if args.page_token is not None and (
        not isinstance(args.page_token, str) or len(args.page_token) > 16_384
    ):
        raise ArchiveError("invalid result page token")
    try:
        client = cloud.bigquery_client(args.project, args.location)
        job = _owned(
            client.get_job(args.job_id, project=args.project, location=args.location, **RPC), args
        )
        report = _report(job)
        if job.state != "DONE":
            return report
        if job.error_result:
            return {**report, "error": "query_failed", "message": "Query failed or was cancelled"}
        if job.statement_type != "SELECT" or job.destination is None:
            raise ArchiveError("completed job has no SELECT result table")
        result = client.list_rows(
            job.destination,
            max_results=args.max_results,
            page_size=args.max_results,
            page_token=args.page_token,
            **RPC,
        )
        page = next(result.pages, ())
        return {
            **report,
            "rows": [_json_value(row) for row in page],
            "schema": [field.to_api_repr() for field in result.schema],
            "next_page_token": result.next_page_token,
            "total_rows": result.total_rows,
            "bytes_processed": job.total_bytes_processed,
        }
    except GoogleAPIError:
        raise ArchiveError("BigQuery query status/results unavailable") from None


def cancel(args):
    """Request cancellation of an owned job, without claiming it has stopped."""
    _identity(args)
    try:
        client = cloud.bigquery_client(args.project, args.location)
        job = _owned(
            client.get_job(args.job_id, project=args.project, location=args.location, **RPC), args
        )
        if job.state == "DONE":
            return {**_report(job), "cancel_requested": False}
        client.cancel_job(args.job_id, project=args.project, location=args.location, **RPC)
        return {**_report(job), "cancel_requested": True}
    except GoogleAPIError:
        raise ArchiveError("BigQuery query cancellation unavailable") from None
