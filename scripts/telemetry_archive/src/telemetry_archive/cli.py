"""Explicit capture, upload, and verification commands; no automatic pruning."""

import argparse
import json
import os
import sys
from pathlib import Path

from . import cloud
from .artifact import capture, read_artifact
from .backfill import BackfillIncomplete
from .backfill_job import run_job
from .backfill_plan import make_plan, validate_plan
from .journal import create_json
from .model import TABLES, ArchiveError, Window, utc
from .objects import archive_bucket, check_generations, load_remote, upload
from .publish import publish as publish_catalog
from .queries import verify_query


def parser():
    root = argparse.ArgumentParser(description=__doc__)
    commands = root.add_subparsers(dest="command", required=True)
    take = commands.add_parser("capture", help="capture one bounded read-replica snapshot locally")
    take.add_argument("--table", choices=TABLES, required=True)
    take.add_argument("--start", type=utc, required=True)
    take.add_argument("--end", type=utc, required=True)
    take.add_argument("--directory", type=Path, required=True)
    take.add_argument("--page-rows", type=int, default=1000)
    take.add_argument("--max-rows", type=int, default=250_000)
    take.add_argument("--max-raw-bytes", type=int, default=512 * 1024**2)
    take.add_argument("--max-seconds", type=int, default=120)
    local = commands.add_parser("verify-local", help="decode and verify a completed local snapshot")
    local.add_argument("--directory", type=Path, required=True)
    send = commands.add_parser(
        "upload", help="create and read back immutable objects in an existing bucket"
    )
    send.add_argument("--directory", type=Path, required=True)
    send.add_argument("--bucket", required=True)
    remote = commands.add_parser(
        "verify-remote", help="read back remote objects; optionally verify BigQuery"
    )
    remote.add_argument("--receipt", required=True)
    remote.add_argument("--bigquery", action="store_true")
    remote.add_argument("--maximum-bytes-billed", type=int, default=1024**3)
    plan = commands.add_parser("prepare-plan", help="freeze finite telemetry time ranges locally")
    plan.add_argument("--ranges", type=Path, required=True)
    plan.add_argument("--output", type=Path, required=True)
    publish = commands.add_parser("upload-plan", help="publish a verified immutable backfill plan")
    publish.add_argument("--file", type=Path, required=True)
    publish.add_argument("--bucket", required=True)
    run = commands.add_parser(
        "run-backfill", help="resume a finite copy-only backfill from checkpoints"
    )
    run.add_argument("--plan-id", required=True)
    run.add_argument("--bucket", required=True)
    run.add_argument("--max-run-seconds", type=int, default=21600)
    run.add_argument("--max-new-windows", type=int, default=20000)
    catalog = commands.add_parser("publish-catalog", help="publish verified coverage to BigQuery")
    catalog.add_argument("--plan-ids", nargs="+", required=True)
    catalog.add_argument("--bucket", required=True)
    catalog.add_argument("--dataset", required=True)
    for command in (send, remote, publish, run, catalog):
        command.add_argument("--project", required=True)
        command.add_argument("--location", default="us-east4")
    return root


def execute(args):
    if args.command == "publish-catalog":
        return publish_catalog(args)
    if args.command == "prepare-plan":
        plan = make_plan(json.loads(args.ranges.read_text()))
        with args.output.open("x") as stream:
            json.dump(plan, stream, sort_keys=True, indent=2)
        return plan
    if args.command == "run-backfill":
        return run_job(args)
    if args.command == "capture":
        dsn = os.environ.get("ARCHIVE_DATABASE_URL")
        if not dsn:
            raise ArchiveError("ARCHIVE_DATABASE_URL must name the read replica")
        window = Window(
            args.table,
            args.start,
            args.end,
            args.page_rows,
            args.max_rows,
            args.max_raw_bytes,
            args.max_seconds,
        )
        return capture(dsn, window, args.directory)
    if args.command == "verify-local":
        receipt, _ = read_artifact(args.directory)
        return {
            "verified": True,
            "artifact_id": receipt["artifact_id"],
            "rows": receipt["stats"]["rows"],
        }
    storage = cloud.storage_client(args.project)
    if args.command == "upload-plan":
        plan = json.loads(args.file.read_text())
        validate_plan(plan)
        bucket = archive_bucket(storage, args.bucket, args.location)
        name = f"backfill-plans/v1/{plan['plan_id']}.json"
        if create_json(bucket, name, plan) != plan:
            raise ArchiveError("existing plan differs from the local plan")
        return {"plan_id": plan["plan_id"], "plan_uri": f"gs://{args.bucket}/{name}"}
    if args.command == "upload":
        return upload(args.directory, storage, args.bucket, args.location)
    published, bucket = load_remote(storage, args.receipt, args.location)
    result = {
        "verified": True,
        "artifact_id": published["snapshot"]["artifact_id"],
        "rows": published["snapshot"]["stats"]["rows"],
    }
    if args.bigquery:
        result["bigquery"] = verify_query(
            cloud.bigquery_client(args.project, args.location),
            published,
            maximum_bytes_billed=args.maximum_bytes_billed,
        )
        check_generations(bucket, published)
    return result


def main():
    args = parser().parse_args()
    try:
        result = execute(args)
    except BackfillIncomplete as exc:
        print(
            json.dumps({"error": str(exc), "command": args.command, "complete": False}),
            file=sys.stderr,
        )
        return 75
    except (ArchiveError, ValueError) as exc:
        print(json.dumps({"error": str(exc), "command": args.command}), file=sys.stderr)
        return 1
    except Exception as exc:
        # Database/client exception text can include credentials or row values.
        print(json.dumps({"error": type(exc).__name__, "command": args.command}), file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
