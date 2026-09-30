"""Reconstruct promotable deadline evidence from intact measured source runs."""
import hashlib
from pathlib import Path

from .deadline_receipts import assemble_deadline_receipt
from .evidence_files import MAX_RECEIPT_BYTES, read_evidence


def reference_run(directory, evidence_root):
    root = Path(evidence_root).resolve(strict=True)
    reference = {}
    for name in ("receipt", "provenance"):
        path = (Path(directory) / f"{name}.json").resolve(strict=True)
        relative = str(path.relative_to(root))
        with path.open("rb") as stream:
            raw = stream.read(MAX_RECEIPT_BYTES + 1)
        if len(raw) > MAX_RECEIPT_BYTES:
            raise ValueError("raw measurement exceeds the bounded evidence size")
        reference[f"{name}_path"] = relative
        reference[f"{name}_sha256"] = hashlib.sha256(raw).hexdigest()
    return reference


def verified_source_runs(receipt, evidence_root):
    references = receipt.get("source_runs")
    if not isinstance(references, list) or not 2 <= len(references) <= 128:
        raise ValueError("deadline evidence requires bounded raw training/validation references")
    runs = []
    seen = set()
    for reference in references:
        if not isinstance(reference, dict):
            raise ValueError("source run reference must be an object")
        raw = read_evidence(reference, "receipt_path", "receipt_sha256", evidence_root)
        provenance = read_evidence(reference, "provenance_path", "provenance_sha256", evidence_root)
        if reference["receipt_sha256"] in seen:
            raise ValueError("a raw run cannot occur more than once")
        seen.add(reference["receipt_sha256"])
        runs.append((raw, provenance))
    return runs


def verify_deadline_samples(receipt, evidence_root):
    calibration = receipt.get("deadline_calibration")
    cells = calibration.get("cells") if isinstance(calibration, dict) else None
    if not isinstance(cells, list) or len(cells) != 1:
        raise ValueError("raw deadline collector requires one isolated cold cell")
    cell = cells[0]
    reconstructed = assemble_deadline_receipt(verified_source_runs(receipt, evidence_root),
        profile_id=receipt["identity"]["id"], prompt_min=cell["prompt_tokens_min"],
        prompt_max=cell["prompt_tokens_max"], checks=receipt.get("checks"))
    for field in ("identity", "build", "applicability", "deadline_calibration"):
        if receipt.get(field) != reconstructed[field]:
            raise ValueError(f"{field} differs from the intact measured receipts")
