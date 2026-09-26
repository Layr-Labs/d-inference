"""Frozen, finite telemetry ranges and deterministic non-overlapping windows."""

import hashlib
from datetime import timedelta

from .artifact import json_bytes
from .model import TABLES, ArchiveError, Window, stamp, utc


def make_plan(ranges: list[dict]) -> dict:
    if not 1 <= len(ranges) <= len(TABLES):
        raise ArchiveError("a backfill plan needs one to five telemetry ranges")
    clean = []
    seen = set()
    for item in ranges:
        table, start, end = item["table"], utc(item["start"]), utc(item["end"])
        if table not in TABLES or table in seen:
            raise ArchiveError("each allowed telemetry table may appear only once")
        if not timedelta(0) < end - start <= timedelta(days=365):
            raise ArchiveError("each backfill range must span at most 365 days")
        seen.add(table)
        clean.append({"table": table, "start": stamp(start), "end": stamp(end)})
    plan = {"version": 1, "copy_only": True, "ranges": clean}
    plan["plan_id"] = hashlib.sha256(json_bytes(plan)).hexdigest()
    return plan


def validate_plan(plan: dict) -> None:
    if make_plan(plan["ranges"]) != plan:
        raise ArchiveError("invalid backfill plan or plan checksum")


def windows(plan: dict):
    validate_plan(plan)
    for item in plan["ranges"]:
        cursor, end = utc(item["start"]), utc(item["end"])
        while cursor < end:
            # Split at UTC hour boundaries, including midnight.
            stop = min(cursor.replace(minute=0, second=0, microsecond=0) + timedelta(hours=1), end)
            yield Window(item["table"], cursor, stop)
            cursor = stop


def identity(window: Window) -> dict:
    return {"table": window.table, "start": stamp(window.start), "end": stamp(window.end)}


def window_key(window: Window) -> str:
    return hashlib.sha256(json_bytes(identity(window))).hexdigest()


def children(window: Window) -> tuple[Window, Window]:
    if window.end - window.start <= timedelta(minutes=1):
        raise ArchiveError("a one-minute window still exceeds limits; operator review required")
    middle = window.start + (window.end - window.start) / 2
    return Window(window.table, window.start, middle), Window(window.table, middle, window.end)
