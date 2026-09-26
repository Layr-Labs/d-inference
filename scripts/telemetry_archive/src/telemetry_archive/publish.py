"""Publish immutable catalog generations and atomically switch reader views."""

import hashlib
import re
import tempfile
from pathlib import Path

from google.api_core.exceptions import NotFound
from google.cloud import bigquery

from . import cloud
from .artifact import json_bytes
from .backfill_plan import validate_plan
from .catalog import merge_files, verified_entries
from .journal import read_json
from .model import TABLES, ArchiveError
from .objects import archive_bucket, put_verified

CATALOG_SCHEMA = [
    bigquery.SchemaField(name, kind, mode="REQUIRED")
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
]


def validate_destination(project, dataset):
    if not re.fullmatch(r"[a-z][a-z0-9-]{4,62}", project):
        raise ArchiveError("invalid project")
    if not re.fullmatch(r"telemetry_[a-zA-Z0-9_]+", dataset):
        raise ArchiveError("publisher requires a dedicated telemetry_ dataset")


def reader_sql(project, dataset, table, version):
    validate_destination(project, dataset)
    if table not in TABLES or not re.fullmatch(r"[0-9a-f]{16}", version):
        raise ArchiveError("invalid catalog identity")
    prefix = f"{project}.{dataset}"
    return f"""SELECT r.*, c.observed_at AS archive_observed_at
FROM `{prefix}.{table}_files_{version}` r
JOIN `{prefix}.catalog_{version}` c ON r._FILE_NAME = c.source_uri
WHERE c.table_name = '{table}'
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY r.source_id ORDER BY c.observed_at DESC, r.row_sha256 DESC
) = 1"""


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
        entries.extend(verified_entries(bucket, args.bucket, plan))
    client = cloud.bigquery_client(args.project, args.location)
    dataset = client.get_dataset(f"{args.project}.{args.dataset}")
    if dataset.location.lower() != args.location.lower():
        raise ArchiveError("BigQuery dataset must be colocated with the archive")
    coverage_id = f"{args.project}.{args.dataset}.archive_coverage"
    try:
        client.get_table(coverage_id)
    except NotFound:
        pass
    else:
        prior = client.query(
            f"SELECT * FROM `{coverage_id}`",
            job_config=bigquery.QueryJobConfig(maximum_bytes_billed=64 * 1024**2),
        ).result(timeout=120)
        for row in prior:
            entry = dict(row.items())
            for field in ("observed_at", "window_start", "window_end"):
                entry[field] = entry[field].isoformat()
            if not entry["source_uri"].startswith(f"gs://{args.bucket}/data/v1/"):
                raise ArchiveError("existing catalog names another bucket")
            object_name = entry["source_uri"].removeprefix(f"gs://{args.bucket}/")
            current = bucket.get_blob(object_name, timeout=30)
            if current is None or str(current.generation) != entry["generation"]:
                raise ArchiveError("existing catalog object was replaced or removed")
            entries.append(entry)
    entries = merge_files(entries)
    if not entries:
        raise ArchiveError("no verified windows are ready to publish")
    digest = hashlib.sha256(json_bytes(entries)).hexdigest()
    version = digest[:16]
    catalog_id = f"{args.project}.{args.dataset}.catalog_{version}"
    catalog = bigquery.Table(catalog_id, schema=CATALOG_SCHEMA)
    catalog.description = "Verified archive catalog sha256=" + digest
    client.create_table(catalog, exists_ok=True)
    existing = client.get_table(catalog_id)
    if existing.description != catalog.description:
        raise ArchiveError("existing catalog identity mismatch")
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
    published = []
    with tempfile.TemporaryDirectory(prefix="archive-catalog-") as scratch:
        for table in TABLES:
            files = [r for r in entries if r["table_name"] == table]
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
            # Each stable view changes only after its immutable backing objects exist.
            sql = reader_sql(args.project, args.dataset, table, version)
            view_id = f"{args.project}.{args.dataset}.{table}"
            client.query(
                f"CREATE OR REPLACE VIEW `{view_id}` AS {sql}",
                job_config=bigquery.QueryJobConfig(maximum_bytes_billed=1024**3),
            ).result(timeout=120)
            published.append(
                {
                    "table": table,
                    "verified_windows": len(files),
                    "snapshot_rows": sum(r["row_count"] for r in files),
                }
            )
    client.query(f"CREATE OR REPLACE VIEW `{coverage_id}` AS SELECT * FROM `{catalog_id}`").result(
        timeout=120
    )
    return {
        "catalog_version": version,
        "tables": published,
        "copy_only": True,
        "retention_eligible": False,
    }
