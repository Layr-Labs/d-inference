"""Explicit source scope, resource bounds, and lossless archive envelope."""

from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pyarrow as pa

TABLES = {
    "request_profiles": "created_at",
    "fleet_snapshots": "sampled_at",
    "request_rejections": "created_at",
    "inference_routes": "created_at",
    "request_outcomes": "received_at",
}
FORMAT_VERSION = 1
# row_json is PostgreSQL's complete row_to_json output, never a field allowlist.
# The type catalog in the receipt makes it possible to restore new/unprojected fields.
ARCHIVE_SCHEMA = pa.schema(
    [
        pa.field("source_id", pa.int64(), nullable=False),
        pa.field("source_time", pa.timestamp("us", tz="UTC"), nullable=False),
        pa.field("model", pa.string()),
        pa.field("provider_id", pa.string()),
        pa.field("final_status", pa.string()),
        pa.field("error_reason", pa.string()),
        pa.field("row_json", pa.string(), nullable=False),
        pa.field("row_sha256", pa.string(), nullable=False),
    ],
    metadata={b"darkbloom.archive_format": b"1", b"darkbloom.copy_only": b"true"},
)


class ArchiveError(Exception):
    """An archive could not be completed or verified."""


def utc(value: str) -> datetime:
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("timestamps must include a timezone")
    return parsed.astimezone(UTC)


def stamp(value: datetime) -> str:
    return value.astimezone(UTC).isoformat(timespec="microseconds").replace("+00:00", "Z")


@dataclass(frozen=True)
class Window:
    table: str
    start: datetime
    end: datetime
    page_rows: int = 1000
    max_rows: int = 250_000
    max_raw_bytes: int = 512 * 1024 * 1024
    max_seconds: int = 120

    def __post_init__(self):
        if self.table not in TABLES:
            raise ValueError("only the five telemetry tables are supported")
        if self.start.tzinfo is None or self.end.tzinfo is None:
            raise ValueError("timestamps must include a timezone")
        if not timedelta(0) < self.end - self.start <= timedelta(hours=1):
            raise ValueError("each snapshot must span more than zero and at most one hour")
        start = self.start.astimezone(UTC)
        last = (self.end - timedelta(microseconds=1)).astimezone(UTC)
        if start.date() != last.date():
            raise ValueError("split windows at UTC midnight")
        if not 1 <= self.page_rows <= 10_000:
            raise ValueError("page_rows must be between 1 and 10000")
        if not 1 <= self.max_rows <= 1_000_000:
            raise ValueError("max_rows must be between 1 and 1000000")
        if not 1 <= self.max_raw_bytes <= 2 * 1024**3:
            raise ValueError("max_raw_bytes must be between 1 byte and 2 GiB")
        if not 1 <= self.max_seconds <= 300:
            raise ValueError("max_seconds must be between 1 and 300")

    @property
    def date(self) -> str:
        return self.start.astimezone(UTC).date().isoformat()


def new_directory(path: Path) -> None:
    # An interrupted or previous run is evidence; never overwrite it.
    path.mkdir(parents=True, exist_ok=False, mode=0o700)
