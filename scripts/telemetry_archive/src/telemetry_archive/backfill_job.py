"""Cloud execution adapter for bounded, verified, copy-only backfills."""

import json
import os
import re
import tempfile
from pathlib import Path

import psycopg
from psycopg.conninfo import make_conninfo

from . import cloud
from .artifact import capture
from .backfill import BackfillIncomplete, Runner, SplitWindow
from .backfill_plan import validate_plan
from .journal import Journal, read_json
from .model import ArchiveError
from .objects import archive_bucket, check_generations, load_remote, upload
from .queries import verify_query


def database_url() -> str:
    if value := os.environ.get("ARCHIVE_DATABASE_URL"):
        return value
    path = os.environ.get("ARCHIVE_ACCESS_FILE")
    expected = os.environ.get("ARCHIVE_EXPECTED_INSTANCE")
    if not path or not expected:
        raise ArchiveError(
            "set ARCHIVE_DATABASE_URL or a mounted access file and expected instance"
        )
    if not re.fullmatch(r"[a-z0-9-]+:[a-z0-9-]+:[a-z0-9-]+", expected):
        raise ArchiveError("invalid expected Cloud SQL instance name")
    access = json.loads(Path(path).read_text())
    if access["connection_name"] != expected:
        raise ArchiveError("mounted database credential names a different instance")
    return make_conninfo(
        host=f"/cloudsql/{expected}",
        dbname=access["database"],
        user=access["username"],
        password=access["password"],
        sslmode="disable",
    )


def replica_ready(dsn: str) -> None:
    with psycopg.connect(
        dsn,
        connect_timeout=10,
        options=(
            "-c default_transaction_read_only=on -c statement_timeout=15000 -c lock_timeout=1000"
        ),
        application_name="telemetry-archive-lag-check",
    ) as conn:
        recovery, readonly, paused, lag = conn.execute(
            "SELECT pg_is_in_recovery(), current_setting('transaction_read_only'), "
            "pg_is_wal_replay_paused(), "
            "EXTRACT(EPOCH FROM clock_timestamp()-pg_last_xact_replay_timestamp())"
        ).fetchone()
        if recovery is not True or readonly != "on":
            raise ArchiveError("backfill source is not a physical replica")
        if paused or lag is None or lag > 30:
            # Exit nonzero with checkpoints retained; do not continue scanning
            # during degraded replication or call a paused backfill complete.
            raise BackfillIncomplete("replica replay age exceeds 30 seconds; resume after recovery")


def process_window(dsn, window, storage, bigquery, bucket_name, location):
    with tempfile.TemporaryDirectory(prefix="telemetry-backfill-") as scratch:
        directory = Path(scratch) / "capture"
        try:
            receipt = capture(dsn, window, directory)
        except ArchiveError as exc:
            if any(
                term in str(exc) for term in ("exceeds max_rows", "size limit", "duration limit")
            ):
                raise SplitWindow(str(exc)) from exc
            raise
        except psycopg.errors.QueryCanceled as exc:
            raise SplitWindow("bounded source query timed out") from exc
        published = upload(directory, storage, bucket_name, location)
        verified, bucket = load_remote(storage, published["receipt_uri"], location)
        result = verify_query(bigquery, verified)
        check_generations(bucket, verified)
        return {
            "verified": result["verified"],
            "receipt_uri": published["receipt_uri"],
            "artifact_id": receipt["artifact_id"],
            "rows": receipt["stats"]["rows"],
            "parquet_bytes": receipt["stats"]["file_bytes"],
            "source_observed_at": receipt["source"]["observed_at"],
            "bigquery_job_id": result["job_id"],
            "objects": {name: verified[name] for name in ("data", "manifest")},
        }


def run_job(args):
    if not re.fullmatch(r"[0-9a-f]{64}", args.plan_id):
        raise ArchiveError("invalid plan ID")
    storage = cloud.storage_client(args.project)
    bucket = archive_bucket(storage, args.bucket, args.location)
    name = f"backfill-plans/v1/{args.plan_id}.json"
    plan = read_json(bucket, name)
    if plan is None:
        raise ArchiveError("backfill plan is missing")
    validate_plan(plan)
    if plan["plan_id"] != args.plan_id:
        raise ArchiveError("plan object identity mismatch")
    dsn = database_url()
    query_client = cloud.bigquery_client(args.project, args.location)
    runner = Runner(
        plan,
        Journal(bucket, plan["plan_id"]),
        lambda window: process_window(
            dsn, window, storage, query_client, args.bucket, args.location
        ),
        saved_check=lambda result: check_generations(bucket, result["objects"]),
        ready=lambda: replica_ready(dsn),
        emit=lambda event: print(json.dumps(event, sort_keys=True), flush=True),
        max_seconds=args.max_run_seconds,
        max_new_windows=args.max_new_windows,
    )
    return runner.run()
