"""Replay reviewed deadline records from an explicitly supplied local archive."""
from pathlib import Path

from .deadline_profile import evaluate_deadline_profile
from .evidence_files import MAX_RECEIPT_BYTES


def validate_evidence_index(reviewed, index):
    if not isinstance(reviewed, list) or not isinstance(index, list) or len(reviewed) != len(index):
        raise ValueError("every compiled record requires exactly one indexed receipt")
    receipts = set()
    for entry in index:
        if not isinstance(entry, dict) or set(entry) != {"receipt"}:
            raise ValueError("each evidence index entry must name an archive-relative receipt")
        relative = entry["receipt"]
        if (not isinstance(relative, str) or not relative or Path(relative).is_absolute()
                or ".." in Path(relative).parts or relative in receipts):
            raise ValueError("receipt paths must be unique and relative to the local archive")
        receipts.add(relative)


def replay_catalog_evidence(reviewed, index, evidence_root):
    validate_evidence_index(reviewed, index)
    if not index:
        return []
    if evidence_root is None:
        raise ValueError("an explicit local evidence root is required to replay promoted records")
    root = Path(evidence_root).resolve(strict=True)
    candidates = []
    for entry in index:
        path = (root / entry["receipt"]).resolve(strict=True)
        if not path.is_relative_to(root) or not path.is_file():
            raise ValueError("evidence must be a file within the local archive")
        with path.open("rb") as stream:
            raw = stream.read(MAX_RECEIPT_BYTES + 1)
        if len(raw) > MAX_RECEIPT_BYTES:
            raise ValueError("assembled receipt exceeds the evidence size bound")
        # This verifies hash-bound raw runs and prerequisites, not just schema.
        result = evaluate_deadline_profile(raw, evidence_root=root)
        if not result["qualified"]:
            raise ValueError(f"indexed receipt is not qualified: {result['errors']}")
        candidates.append(result["profile"])
    if candidates != reviewed:
        raise ValueError("every compiled record must exactly match its qualified real evidence")
    return candidates
