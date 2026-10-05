"""Frozen, finite telemetry ranges and deterministic non-overlapping windows."""

import hashlib
import re
from datetime import timedelta

from .artifact import json_bytes
from .model import TABLES, ArchiveError, Window, stamp, utc
from .scope import table_scope
from .tables import ACCOUNTING_FIELDS
from .windows import IDWindow, identity, validate_id_bounds


def make_plan(ranges: list[dict], capture_generation: str | None = None) -> dict:
    if capture_generation is not None and (
        not isinstance(capture_generation, str)
        or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}", capture_generation)
    ):
        raise ArchiveError(
            "capture generation must be 1-64 safe alphanumeric, '_' or '-' characters"
        )
    if not 1 <= len(ranges) <= len(TABLES):
        raise ArchiveError("a backfill plan needs explicitly allowed history ranges")
    clean = []
    seen = set()
    for item in ranges:
        table = item["table"]
        if table not in TABLES or table in seen:
            raise ArchiveError("each allowed history table may appear only once")
        seen.add(table)
        if "id_start" in item or "id_end" in item:
            if table not in ACCOUNTING_FIELDS or set(item) != {"table", "id_start", "id_end"}:
                raise ArchiveError("invalid accounting ID range")
            validate_id_bounds(item["id_start"], item["id_end"])
            clean.append(dict(item))
            continue
        start, end = utc(item["start"]), utc(item["end"])
        if not timedelta(0) < end - start <= timedelta(days=365):
            raise ArchiveError("each backfill range must span at most 365 days")
        clean.append({"table": table, "start": stamp(start), "end": stamp(end)})
    table_scope(seen)
    if len({"id_start" in r for r in clean}) != 1:
        raise ArchiveError("a plan cannot mix timestamp and primary-key ranges")
    plan = {"version": 2 if "id_start" in clean[0] else 1, "copy_only": True, "ranges": clean}
    if capture_generation is not None:
        plan.update(version=3, capture_generation=capture_generation)
    plan["plan_id"] = hashlib.sha256(json_bytes(plan)).hexdigest()
    return plan


def validate_plan(plan: dict) -> None:
    if make_plan(plan["ranges"], plan.get("capture_generation")) != plan:
        raise ArchiveError("invalid backfill plan or plan checksum")


def windows(plan: dict):
    validate_plan(plan)
    for item in plan["ranges"]:
        if "id_start" in item:
            for cursor in range(item["id_start"], item["id_end"], 100_000):
                yield IDWindow(item["table"], cursor, min(cursor + 100_000, item["id_end"]))
            continue
        cursor, end = utc(item["start"]), utc(item["end"])
        while cursor < end:
            # Split at UTC hour boundaries, including midnight.
            stop = min(cursor.replace(minute=0, second=0, microsecond=0) + timedelta(hours=1), end)
            yield Window(item["table"], cursor, stop)
            cursor = stop


def window_key(window: Window) -> str:
    return hashlib.sha256(json_bytes(identity(window))).hexdigest()


def children(window: Window) -> tuple[Window, Window]:
    if isinstance(window, IDWindow):
        if window.end - window.start <= 1:
            raise ArchiveError("a single ID still exceeds limits; operator review required")
        middle = (window.start + window.end) // 2
        return IDWindow(window.table, window.start, middle), IDWindow(
            window.table, middle, window.end
        )
    if window.end - window.start <= timedelta(minutes=1):
        raise ArchiveError("a one-minute window still exceeds limits; operator review required")
    middle = window.start + (window.end - window.start) / 2
    return Window(window.table, window.start, middle), Window(window.table, middle, window.end)
