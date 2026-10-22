"""Bounded exact source evidence for stateless integration requests."""
import json

MAX_REPLAY_BYTES = 16_000


def replay_source(source, reviewed_ids):
    """Replay only this model's validated source scope, never model-picked paths.

    Prefer patches and metadata so large files do not crowd out change context.
    Units are either included verbatim or explicitly counted as omitted; their
    numbered source lines and IDs retain the original citation coordinates.
    """
    reviewed = [unit for batch in source for unit in batch if unit["id"] in reviewed_ids]
    priority = {"patch": 0, None: 1, "head_text": 2, "base_text": 3}
    ordered = sorted(reviewed, key=lambda unit: priority[unit.get("kind")])
    result = {"units": [], "reviewed_units": len(reviewed), "omitted_units": len(reviewed),
              "complete": not reviewed}
    for unit in ordered:
        candidate = {**result, "units": result["units"] + [unit],
                     "omitted_units": result["omitted_units"] - 1,
                     "complete": result["omitted_units"] == 1}
        if len(json.dumps(candidate).encode()) <= MAX_REPLAY_BYTES:
            result = candidate
    return result
