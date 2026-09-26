"""Primary-key accounting snapshots alongside backwards-compatible time windows."""

from dataclasses import dataclass

from .model import Window, stamp, utc, validate_limits
from .tables import ACCOUNTING_FIELDS


def validate_id_bounds(start, end):
    if type(start) is not int or type(end) is not int or not -(2**63) <= start < end < 2**63:
        raise ValueError("ID bounds must be increasing signed integers with an exclusive end")


@dataclass(frozen=True)
class IDWindow:
    table: str
    start: int
    end: int
    page_rows: int = 1000
    max_rows: int = 250_000
    max_raw_bytes: int = 512 * 1024 * 1024
    max_seconds: int = 120

    def __post_init__(self):
        if self.table not in ACCOUNTING_FIELDS:
            raise ValueError("primary-key snapshots are restricted to accounting history")
        validate_id_bounds(self.start, self.end)
        if self.end - self.start > 1_000_000:
            raise ValueError("each ID snapshot must span at most 1000000 IDs")
        validate_limits(self)

    @property
    def partition(self):
        return f"id_range={self.start}_{self.end}"

    def contains(self, source_id, source_time):
        return self.start <= source_id < self.end

    def order_key(self, source_id, source_time):
        return source_id


def identity(window):
    if isinstance(window, IDWindow):
        return {"table": window.table, "id_start": window.start, "id_end": window.end}
    return {"table": window.table, "start": stamp(window.start), "end": stamp(window.end)}


def read_window(record):
    if "id_start" in record or "id_end" in record:
        if "start" in record or "end" in record:
            raise ValueError("a snapshot cannot mix timestamp and ID bounds")
        return IDWindow(record["table"], record["id_start"], record["id_end"])
    return Window(record["table"], utc(record["start"]), utc(record["end"]))


def end_boundary(window):
    return window.end if isinstance(window, IDWindow) else stamp(window.end)
