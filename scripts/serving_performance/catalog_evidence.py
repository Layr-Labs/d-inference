"""Replay reviewed deadline records from an explicitly supplied local archive."""
import hashlib
import json
from pathlib import Path, PurePosixPath

from .deadline_profile import evaluate_deadline_profile
from .evidence_files import MAX_RECEIPT_BYTES
from .matrix import digest


def canonical_profile_sha256(profile):
    """Bind all reviewed values, using the catalog generator's JSON convention."""
    canonical = json.dumps(profile, ensure_ascii=False, allow_nan=False,
                           sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def validate_evidence_index(reviewed, index):
    if not isinstance(reviewed, list) or not isinstance(index, list) or len(reviewed) != len(index):
        raise ValueError("every compiled record requires exactly one indexed receipt")
    receipts, identifiers = set(), set()
    for profile, entry in zip(reviewed, index):
        if (not isinstance(profile, dict) or not isinstance(profile.get("id"), str)
                or not profile["id"] or profile["id"] in identifiers
                or not digest(profile.get("qualification_report_sha256"))):
            raise ValueError("reviewed profiles require unique ids and valid qualification report digests")
        identifiers.add(profile["id"])
        if not isinstance(entry, dict) or set(entry) != {
                "receipt", "profile_id", "qualification_report_sha256", "profile_sha256"}:
            raise ValueError("each evidence index entry must bind a profile and its archive-relative receipt")
        if (entry["profile_id"] != profile["id"]
                or entry["qualification_report_sha256"] != profile["qualification_report_sha256"]
                or entry["profile_sha256"] != canonical_profile_sha256(profile)):
            raise ValueError("indexed profile identity, report and full digest must exactly match the catalog order")
        relative = entry["receipt"]
        if not isinstance(relative, str) or not relative or "\x00" in relative or "\\" in relative:
            raise ValueError("receipt paths must be canonical POSIX paths relative to the local archive")
        path = PurePosixPath(relative)
        if (path.is_absolute() or not path.parts or ".." in path.parts
                or path.as_posix() != relative or relative in receipts):
            raise ValueError("receipt paths must be unique canonical paths relative to the local archive")
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
