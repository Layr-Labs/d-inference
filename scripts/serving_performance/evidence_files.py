"""Bounded, hash-checked reads confined to an explicit evidence archive."""
import hashlib
from pathlib import Path

from .matrix import digest

MAX_RECEIPT_BYTES = 8 * 1024 * 1024


def evidence_file(reference, path_key, hash_key, evidence_root):
    path, expected = reference.get(path_key), reference.get(hash_key)
    if not isinstance(path, str) or not path or not digest(expected):
        raise ValueError(f"requires actual {path_key} and valid {hash_key}")
    if evidence_root is None:
        raise ValueError("an explicit evidence root is required to verify raw files")
    root = Path(evidence_root).resolve(strict=True)
    actual = (root / path).resolve(strict=True)
    if not actual.is_relative_to(root) or not actual.is_file():
        raise ValueError("evidence must be a file within the evidence root")
    return actual, expected


def read_evidence(reference, path_key, hash_key, evidence_root):
    actual, expected = evidence_file(reference, path_key, hash_key, evidence_root)
    with actual.open("rb") as stream:
        raw = stream.read(MAX_RECEIPT_BYTES + 1)
    if len(raw) > MAX_RECEIPT_BYTES or hashlib.sha256(raw).hexdigest() != expected:
        raise ValueError(f"{path_key} content does not match its reviewed hash")
    return raw
