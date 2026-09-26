"""Local capture artifacts are complete snapshots, never deletion receipts."""

import hashlib
import json
from pathlib import Path

from .codec import encode, verify_parquet
from .model import FORMAT_VERSION, ArchiveError, Window, new_directory, stamp, utc
from .source import snapshot


def json_bytes(value: dict) -> bytes:
    return (json.dumps(value, sort_keys=True, indent=2, allow_nan=False) + "\n").encode()


def capture(dsn: str, window: Window, directory: Path, *, require_replica=True) -> dict:
    new_directory(directory)
    path = directory / "data.parquet"
    with snapshot(dsn, window, require_replica=require_replica) as (source, expected, pages):
        stats = encode(pages, path, window, expected)
    # The replica transaction is closed before verification, upload, or BigQuery work.
    verify_parquet(path, window, stats)
    receipt = {
        "format_version": FORMAT_VERSION,
        "copy_only": True,
        "retention_eligible": False,
        "table": window.table,
        "start": stamp(window.start),
        "end": stamp(window.end),
        "source": source,
        "stats": stats,
    }
    receipt["artifact_id"] = hashlib.sha256(json_bytes(receipt)).hexdigest()
    # No receipt exists until the full source snapshot and decoded files match.
    (directory / "receipt.json").write_bytes(json_bytes(receipt))
    return receipt


def validate_receipt(receipt: dict) -> Window:
    if (
        receipt.get("format_version") != FORMAT_VERSION
        or receipt.get("copy_only") is not True
        or receipt.get("retention_eligible") is not False
    ):
        raise ArchiveError("not a supported copy-only snapshot receipt")
    core = {k: v for k, v in receipt.items() if k != "artifact_id"}
    if hashlib.sha256(json_bytes(core)).hexdigest() != receipt.get("artifact_id"):
        raise ArchiveError("snapshot receipt checksum mismatch")
    window = Window(receipt["table"], utc(receipt["start"]), utc(receipt["end"]))
    stats = receipt["stats"]
    if not 0 <= stats["rows"] <= 1_000_000 or not 0 < stats["file_bytes"] <= 2 * 1024**3:
        raise ArchiveError("snapshot exceeds supported verification bounds")
    return window


def read_artifact(directory: Path) -> tuple[dict, Window]:
    receipt = json.loads((directory / "receipt.json").read_text())
    window = validate_receipt(receipt)
    verify_parquet(directory / "data.parquet", window, receipt["stats"])
    return receipt, window
