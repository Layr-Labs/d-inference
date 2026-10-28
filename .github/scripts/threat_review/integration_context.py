"""Bounded exact source evidence for stateless integration requests."""
import json

MAX_REPLAY_BYTES = 16_000


def replay_source(source, reviewed_ids):
    """Replay only this model's validated source scope, never model-picked paths.

    Prefer patches and metadata so large files do not crowd out change context.
    Units retain exact text and coordinates, with id renamed to source_id, or
    are explicitly counted as omitted. Replay grants no new citation scope.
    """
    reviewed = [unit for batch in source for unit in batch if unit["id"] in reviewed_ids]
    priority = {"patch": 0, None: 1, "head_text": 2, "base_text": 3}
    ordered = sorted(reviewed, key=lambda unit: priority[unit.get("kind")])
    result = {"units": [], "reviewed_units": len(reviewed), "omitted_units": len(reviewed),
              "complete": not reviewed}
    for unit in ordered:
        # Replayed evidence is not a primary acknowledgment target. Give its
        # identifier a distinct name so integration cannot confuse the scopes.
        replayed = {"source_id": unit["id"], **{k: v for k, v in unit.items() if k != "id"}}
        candidate = {**result, "units": result["units"] + [replayed],
                     "omitted_units": result["omitted_units"] - 1,
                     "complete": result["omitted_units"] == 1}
        if len(json.dumps(candidate).encode()) <= MAX_REPLAY_BYTES:
            result = candidate
    return result
