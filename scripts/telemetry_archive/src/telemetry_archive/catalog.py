"""Expose only verified checkpoint coverage, including incomplete backfills."""

from .artifact import validate_receipt
from .backfill import Runner
from .backfill_plan import children, identity, window_key, windows
from .journal import Journal, read_json
from .model import ArchiveError, stamp, utc
from .objects import check_generations


def verified_entries(bucket, bucket_name, plan):
    journal = Journal(bucket, plan["plan_id"])
    validator = Runner(plan, journal, None, saved_check=None)

    def visit(window):
        state = journal.get("windows/" + window_key(window))
        if state is None:
            return
        validator.validate_state(state, window)
        if state["status"] == "split":
            left, right = children(window)
            if state.get("middle") != identity(left)["end"]:
                raise ArchiveError("catalog split boundary mismatch")
            yield from visit(left)
            yield from visit(right)
            return
        result = state["result"]
        if result.get("verified") is not True:
            raise ArchiveError("catalog cannot expose unverified data")
        artifact_id = result["artifact_id"]
        receipt = read_json(bucket, f"receipts/v1/{artifact_id}.json")
        if receipt is None:
            raise ArchiveError("catalog receipt is missing")
        source_window = validate_receipt(receipt["snapshot"])
        if (
            identity(source_window) != identity(window)
            or receipt["snapshot"]["artifact_id"] != artifact_id
            or receipt["bucket"] != bucket_name
            or receipt["snapshot"]["stats"]["rows"] != result["rows"]
            or result["objects"] != {key: receipt[key] for key in ("data", "manifest")}
        ):
            raise ArchiveError("catalog checkpoint differs from receipt")
        check_generations(bucket, receipt)
        yield {
            "table_name": window.table,
            "source_uri": f"gs://{bucket_name}/{receipt['data']['name']}",
            "generation": str(receipt["data"]["generation"]),
            "observed_at": stamp(utc(receipt["snapshot"]["source"]["observed_at"])),
            "window_start": stamp(window.start),
            "window_end": stamp(window.end),
            "row_count": result["rows"],
            "parquet_bytes": result["parquet_bytes"],
            "plan_id": plan["plan_id"],
        }

    for window in windows(plan):
        yield from visit(window)


def merge_files(entries):
    """Repeated identical files are one source; preserve the latest observation."""
    files = {}
    for entry in entries:
        entry = dict(entry)
        for field in ("observed_at", "window_start", "window_end"):
            if field in entry:
                entry[field] = stamp(utc(entry[field]))
        previous = files.get(entry["source_uri"])
        if previous and previous["generation"] != entry["generation"]:
            raise ArchiveError("catalog object generation conflict")
        if previous is None or utc(entry["observed_at"]) > utc(previous["observed_at"]):
            files[entry["source_uri"]] = entry
    return sorted(files.values(), key=lambda row: row["source_uri"])
