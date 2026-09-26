"""Resume verified windows and persist adaptive splits without overlap."""

import hashlib
import time

from .artifact import json_bytes
from .backfill_plan import children, identity, window_key, windows
from .model import ArchiveError


class SplitWindow(ArchiveError):
    """The bounded capture needs a smaller interval."""


class BackfillIncomplete(ArchiveError):
    """A finite execution budget stopped before the plan completed."""


class Runner:
    def __init__(
        self,
        plan,
        journal,
        process,
        *,
        saved_check,
        ready=lambda: None,
        emit=lambda event: None,
        max_seconds=21600,
        max_new_windows=20000,
        monotonic=time.monotonic,
    ):
        if not 1 <= max_seconds <= 43200 or not 1 <= max_new_windows <= 50000:
            raise ArchiveError("backfill execution budget exceeds supported bounds")
        self.plan, self.journal, self.process = plan, journal, process
        self.saved_check, self.ready, self.emit = saved_check, ready, emit
        self.monotonic = monotonic
        self.deadline = monotonic() + max_seconds
        self.max_new_windows, self.started_windows = max_new_windows, 0

    def budget(self):
        if self.monotonic() >= self.deadline or self.started_windows >= self.max_new_windows:
            raise BackfillIncomplete("execution budget reached; rerun the same plan to resume")

    def validate_state(self, state, window):
        if (
            state.get("plan_id") != self.plan["plan_id"]
            or state.get("window") != identity(window)
            or state.get("copy_only") is not True
            or state.get("retention_eligible") is not False
            or state.get("status") not in ("complete", "split")
        ):
            raise ArchiveError("checkpoint identity or status mismatch")

    def visit(self, window):
        key = "windows/" + window_key(window)
        state = self.journal.get(key)
        if state is None:
            self.budget()
            self.ready()
            self.budget()
            self.started_windows += 1
            state = {
                "plan_id": self.plan["plan_id"],
                "window": identity(window),
                "copy_only": True,
                "retention_eligible": False,
            }
            try:
                result = self.process(window)
            except SplitWindow:
                left, _ = children(window)
                state.update(status="split", middle=identity(left)["end"])
            else:
                if result.get("verified") is not True:
                    raise ArchiveError("unverified export cannot become a completion checkpoint")
                state.update(status="complete", result=result)
            # First immutable writer decides this window's structure. A concurrent
            # loser can leave an unreferenced copy, never an overlapping checkpoint.
            state = self.journal.put(key, state)
            self.emit(
                {"event": "checkpoint", "window": identity(window), "status": state["status"]}
            )
        self.validate_state(state, window)
        if state["status"] == "complete":
            self.saved_check(state["result"])
            yield state
        else:
            left, right = children(window)
            if state.get("middle") != identity(left)["end"]:
                raise ArchiveError("split checkpoint has an unexpected boundary")
            yield from self.visit(left)
            yield from self.visit(right)

    def run(self):
        totals = {}
        files = {}
        digest = hashlib.sha256()
        leaves = 0
        for window in windows(self.plan):
            for state in self.visit(window):
                result = state["result"]
                if result.get("verified") is not True or result["rows"] < 0:
                    raise ArchiveError("invalid completion checkpoint")
                totals.setdefault(window.table, {"rows": 0, "parquet_bytes": 0, "windows": 0})
                target = totals[window.table]
                target["rows"] += result["rows"]
                target["parquet_bytes"] += result["parquet_bytes"]
                target["windows"] += 1
                data = result["objects"]["data"]
                entries = files.setdefault(window.table, {})
                if data["name"] in entries and entries[data["name"]] != data:
                    raise ArchiveError("one data object has conflicting generation receipts")
                entries[data["name"]] = data
                digest.update(json_bytes(state))
                leaves += 1
        for table, entries in files.items():
            catalog = {
                "plan_id": self.plan["plan_id"],
                "table": table,
                "copy_only": True,
                "rows": totals[table]["rows"],
                "files": [entries[k] for k in sorted(entries)],
            }
            key = "catalogs/" + table
            if self.journal.put(key, catalog) != catalog:
                raise ArchiveError("existing file catalog differs from verified coverage")
        summary = {
            "plan_id": self.plan["plan_id"],
            "complete": True,
            "copy_only": True,
            "retention_eligible": False,
            "tables": totals,
            "windows": leaves,
            "checkpoint_sha256": digest.hexdigest(),
        }
        if self.journal.put("summary", summary) != summary:
            raise ArchiveError("existing summary differs from the completed checkpoint coverage")
        return summary
