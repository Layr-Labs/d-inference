"""Bounded change coordinates accompany source excerpts split across batches."""
import json
import re

from .diagnostics import ReviewFailure

MAX_CONTEXT_BYTES = 16_000
MAX_RANGES = 128
MAX_PATCH_CHARS = 2000


def changed_ranges(patch):
    ranges = {"base": [], "head": []}
    old = new = None

    def append(side, number):
        items = ranges[side]
        if items and items[-1][1] + 1 == number:
            items[-1][1] = number
        else:
            items.append([number, number])

    for line in patch.splitlines():
        match = re.match(r"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@", line)
        if match:
            old, new = map(int, match.groups())
        elif old is not None:
            if line.startswith("-"):
                append("base", old)
                old += 1
            elif line.startswith("+"):
                append("head", new)
                new += 1
            elif line.startswith(" "):
                old += 1
                new += 1
    return ranges


def file_changes(files):
    result = {}
    for file in files:
        patch = file.get("patch", "")
        ranges = changed_ranges(patch)
        result[file["filename"]] = {
            "file": file["filename"], "status": file["status"],
            "changed_ranges": {side: spans[:MAX_RANGES] for side, spans in ranges.items()},
            "range_map_complete": bool(file.get("source_complete")) and all(
                len(spans) <= MAX_RANGES for spans in ranges.values()),
            "patch_excerpt": patch[:MAX_PATCH_CHARS],
            "patch_excerpt_complete": len(patch) <= MAX_PATCH_CHARS,
        }
    return result


def batch_changes(changes, batch):
    paths = sorted({unit["metadata"]["file"] for unit in batch})
    context = [changes[path] for path in paths]
    if len(json.dumps(context).encode()) > MAX_CONTEXT_BYTES:
        raise ReviewFailure("Batch change context exceeds capacity; scan incomplete", "CHANGE_CONTEXT_LIMIT")
    return context
