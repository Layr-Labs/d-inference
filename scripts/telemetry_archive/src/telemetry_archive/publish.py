"""Publish immutable catalogs and update independent single-table reader aliases.

Cross-table analytics pin an explicit generation via reader_sql; stable aliases
are not switched as one group. archive_coverage selects the completed catalog last.
"""

import hashlib
import re
import tempfile
from pathlib import Path

from google.api_core.exceptions import NotFound
from google.cloud import bigquery

from . import cloud
from .accounting import query_projections
from .artifact import json_bytes
from .backfill_plan import validate_plan
from .catalog import merge_coverage, merge_files, verified_entries
from .journal import read_json
from .model import TABLES, ArchiveError
from .objects import archive_bucket, put_verified
from .scope import require_bucket_scope, require_dataset_scope

CATALOG_SCHEMA = [
    bigquery.SchemaField(name, kind, mode="NULLABLE" if name.startswith("window_") else "REQUIRED")
    for name, kind in (
        ("table_name", "STRING"),
        ("source_uri", "STRING"),
        ("generation", "STRING"),
        ("observed_at", "TIMESTAMP"),
        ("window_start", "TIMESTAMP"),
        ("window_end", "TIMESTAMP"),
        ("row_count", "INTEGER"),
        ("parquet_bytes", "INTEGER"),
        ("plan_id", "STRING"),
    )
] + [bigquery.SchemaField(name, "INTEGER") for name in ("id_start", "id_end")]

# Keep this in sync with model.ARCHIVE_SCHEMA. An existing table with the same
# name but a different inferred or manually edited schema cannot be reused.
FILE_SCHEMA = (
    ("source_id", "INTEGER", "REQUIRED"),
    ("source_time", "TIMESTAMP", "REQUIRED"),
    ("model", "STRING", "NULLABLE"),
    ("provider_id", "STRING", "NULLABLE"),
    ("final_status", "STRING", "NULLABLE"),
    ("error_reason", "STRING", "NULLABLE"),
    ("row_json", "STRING", "REQUIRED"),
    ("row_sha256", "STRING", "REQUIRED"),
)


def validate_destination(project, dataset):
    if not re.fullmatch(r"[a-z][a-z0-9-]{4,62}", project):
        raise ArchiveError("invalid project")
    if not re.fullmatch(r"(?:telemetry|accounting)_[a-zA-Z0-9_]+", dataset):
        raise ArchiveError("publisher requires a dedicated telemetry_ or accounting_ dataset")


def reader_sql(project, dataset, table, version):
    validate_destination(project, dataset)
    if table not in TABLES or not re.fullmatch(r"[0-9a-f]{16}", version):
        raise ArchiveError("invalid catalog identity")
    require_dataset_scope(dataset, [table])
    prefix = f"{project}.{dataset}"
    projections = query_projections(table)
    extra = ", " + ", ".join(projections) if projections else ""
    return f"""SELECT r.*, c.observed_at AS archive_observed_at{extra}
FROM `{prefix}.{table}_files_{version}` r
JOIN (
  SELECT source_uri, MAX(observed_at) AS observed_at
  FROM `{prefix}.catalog_{version}` WHERE table_name = '{table}'
  GROUP BY source_uri
) c ON r._FILE_NAME = c.source_uri
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY r.source_id ORDER BY c.observed_at DESC, r.row_sha256 DESC
) = 1"""


def _read_catalog(client, catalog_id, row_count, digest, *, legacy=False):
    # Metadata is mutable: bound the physical read and verify its content, not
    # merely the claimed count. Never query the movable coverage alias here.
    if type(row_count) is not int or row_count < 0:
        raise ArchiveError("existing catalog row count mismatch")
    rows = client.query(
        f"SELECT * FROM `{catalog_id}` LIMIT {row_count + 1}",
        job_config=bigquery.QueryJobConfig(
            maximum_bytes_billed=64 * 1024**2, use_query_cache=False
        ),
    ).result(timeout=120)
    entries = []
    for row in rows:
        entry = dict(row.items())
        for field in ("observed_at", "window_start", "window_end"):
            if entry[field] is not None:
                entry[field] = entry[field].isoformat()
        entries.append(entry)
    normalized = merge_files(entries) if legacy else merge_coverage(entries)
    if len(entries) != row_count or len(normalized) != row_count:
        raise ArchiveError("existing catalog row count mismatch")
    payload = normalized if legacy else {"coverage_format": 2, "entries": normalized}
    if hashlib.sha256(json_bytes(payload)).hexdigest() == digest:
        return normalized
    if legacy:
        # The file-only writer omitted null ID fields on fresh time windows;
        # BigQuery materializes them on read. Its republish path retained them.
        without_null_ids = [
            {k: v for k, v in row.items() if k not in ("id_start", "id_end") or v is not None}
            for row in normalized
        ]
        if hashlib.sha256(json_bytes(without_null_ids)).hexdigest() == digest:
            return normalized
        raise ArchiveError(
            "legacy catalog content mismatch; republish all relevant checkpoint plans "
            "into a fresh dedicated dataset and verify coverage before switching readers"
        )
    raise ArchiveError("existing catalog content mismatch")


def publish(args):
    validate_destination(args.project, args.dataset)
    storage = cloud.storage_client(args.project)
    bucket = archive_bucket(storage, args.bucket, args.location)
    entries = []
    for plan_id in args.plan_ids:
        if not re.fullmatch(r"[0-9a-f]{64}", plan_id):
            raise ArchiveError("invalid catalog plan ID")
        plan = read_json(bucket, f"backfill-plans/v1/{plan_id}.json")
        if plan is None or plan["plan_id"] != plan_id:
            raise ArchiveError("catalog plan is missing or mismatched")
        validate_plan(plan)
        tables = [r["table"] for r in plan["ranges"]]
        require_bucket_scope(bucket, tables)
        require_dataset_scope(args.dataset, tables)
        entries.extend(verified_entries(bucket, args.bucket, plan))
    client = cloud.bigquery_client(args.project, args.location)
    dataset = client.get_dataset(f"{args.project}.{args.dataset}")
    if dataset.location.lower() != args.location.lower():
        raise ArchiveError("BigQuery dataset must be colocated with the archive")
    coverage_id = f"{args.project}.{args.dataset}.archive_coverage"
    try:
        coverage = client.get_table(coverage_id)
    except NotFound:
        pass
    else:
        pointer = re.fullmatch(
            rf"SELECT \* FROM `({re.escape(args.project + '.' + args.dataset)}"
            r"\.catalog_([0-9a-f]{16}))`",
            coverage.view_query or "",
        )
        if (
            coverage.table_type != "VIEW"
            or coverage.view_use_legacy_sql is not False
            or not pointer
        ):
            raise ArchiveError("existing archive_coverage pointer mismatch")
        prior_id, prior_version = pointer.groups()
        prior = client.get_table(prior_id)
        identity = re.fullmatch(
            r"Verified archive catalog sha256=([0-9a-f]{64})", prior.description or ""
        )
        coverage_format = (prior.labels or {}).get("archive_coverage")
        if (
            not identity
            or identity[1][:16] != prior_version
            or prior.table_type != "TABLE"
            or prior.external_data_configuration is not None
            or coverage_format not in (None, "plan_windows_v2")
        ):
            raise ArchiveError("existing catalog identity mismatch")
        if tuple((f.name, f.field_type, f.mode) for f in prior.schema) != tuple(
            (f.name, f.field_type, f.mode) for f in CATALOG_SCHEMA
        ):
            raise ArchiveError("existing catalog schema mismatch")
        for entry in _read_catalog(
            client, prior_id, prior.num_rows, identity[1], legacy=coverage_format is None
        ):
            require_dataset_scope(args.dataset, [entry["table_name"]])
            require_bucket_scope(bucket, [entry["table_name"]])
            if not entry["source_uri"].startswith(f"gs://{args.bucket}/data/v1/"):
                raise ArchiveError("existing catalog names another bucket")
            object_name = entry["source_uri"].removeprefix(f"gs://{args.bucket}/")
            current = bucket.get_blob(object_name, timeout=30)
            if current is None or str(current.generation) != entry["generation"]:
                raise ArchiveError("existing catalog object was replaced or removed")
            entries.append(entry)
    entries = merge_coverage(entries)
    file_entries = merge_files(entries)
    if not entries:
        raise ArchiveError("no verified windows are ready to publish")
    # Domain-separate window coverage from the older file-only catalogs, even
    # when a particular publication happens to have one file per window.
    digest = hashlib.sha256(json_bytes({"coverage_format": 2, "entries": entries})).hexdigest()
    version = digest[:16]
    catalog_id = f"{args.project}.{args.dataset}.catalog_{version}"
    catalog = bigquery.Table(catalog_id, schema=CATALOG_SCHEMA)
    catalog.description = "Verified archive catalog sha256=" + digest
    catalog.labels = {"archive_coverage": "plan_windows_v2"}
    client.create_table(catalog, exists_ok=True)
    existing = client.get_table(catalog_id)
    if (
        existing.description != catalog.description
        or (existing.labels or {}).get("archive_coverage") != "plan_windows_v2"
    ):
        raise ArchiveError("existing catalog identity mismatch")
    if tuple((f.name, f.field_type, f.mode) for f in existing.schema) != tuple(
        (f.name, f.field_type, f.mode) for f in CATALOG_SCHEMA
    ):
        raise ArchiveError("existing catalog schema mismatch")
    if not existing.num_rows:
        client.load_table_from_json(
            entries,
            catalog_id,
            job_config=bigquery.LoadJobConfig(
                schema=CATALOG_SCHEMA, write_disposition="WRITE_EMPTY"
            ),
        ).result(timeout=120)
    elif existing.num_rows != len(entries):
        raise ArchiveError("existing catalog row count mismatch")
    _read_catalog(client, catalog_id, len(entries), digest)
    published = []
    with tempfile.TemporaryDirectory(prefix="archive-catalog-") as scratch:
        for table in TABLES:
            table_windows = [r for r in entries if r["table_name"] == table]
            files = [r for r in file_entries if r["table_name"] == table]
            if not files:
                continue
            path = Path(scratch) / f"{table}.txt"
            path.write_text("".join(r["source_uri"] + "\n" for r in files))
            object_name = f"query-manifests/v1/{version}/{table}.txt"
            put_verified(bucket, object_name, path, content_type="text/plain")
            external_id = f"{args.project}.{args.dataset}.{table}_files_{version}"
            external = bigquery.Table(external_id)
            external.external_data_configuration = bigquery.ExternalConfig.from_api_repr(
                {
                    "sourceFormat": "PARQUET",
                    "autodetect": True,
                    "fileSetSpecType": "FILE_SET_SPEC_TYPE_NEW_LINE_DELIMITED_MANIFEST",
                    "sourceUris": [f"gs://{args.bucket}/{object_name}"],
                }
            )
            client.create_table(external, exists_ok=True)
            actual = client.get_table(external_id)
            configuration = actual.external_data_configuration
            if (
                configuration is None
                or configuration.to_api_repr() != external.external_data_configuration.to_api_repr()
            ):
                raise ArchiveError("existing external table manifest or configuration mismatch")
            if tuple((f.name, f.field_type, f.mode) for f in actual.schema) != FILE_SCHEMA:
                raise ArchiveError("existing external table schema mismatch")
            # Each alias changes independently after its backing objects exist.
            # Multi-table consumers must pin a catalog with reader_sql, as the
            # analytics preview does; these aliases are for single-table reads.
            sql = reader_sql(args.project, args.dataset, table, version)
            view_id = f"{args.project}.{args.dataset}.{table}"
            client.query(
                f"CREATE OR REPLACE VIEW `{view_id}` AS {sql}",
                job_config=bigquery.QueryJobConfig(maximum_bytes_billed=1024**3),
            ).result(timeout=120)
            published.append(
                {
                    "table": table,
                    "verified_windows": len(table_windows),
                    "data_files": len(files),
                    "snapshot_rows": sum(r["row_count"] for r in files),
                }
            )
    client.query(f"CREATE OR REPLACE VIEW `{coverage_id}` AS SELECT * FROM `{catalog_id}`").result(
        timeout=120
    )
    return {
        "catalog_version": version,
        "coverage_format": 2,
        "tables": published,
        "copy_only": True,
        "retention_eligible": False,
    }
