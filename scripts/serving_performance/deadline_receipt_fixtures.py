"""Synthetic archived runs for verifier tests only, never promotion evidence."""
import copy
import hashlib
import uuid

from .check_receipt_fixtures import ROOT, references, write
from .deadline_evidence import reference_run, verified_source_runs
from .deadline_receipts import assemble_deadline_receipt
from .test_deadline_receipts import run


def receipt():
    prefix = uuid.uuid4().hex
    source_runs = []
    for partition, count in (("calibration", 20), ("validation", 100)):
        report, provenance = run(partition)
        original = report["trials"][0]
        report["trials"] = []
        for index in range(count):
            trial = copy.deepcopy(original)
            trial["iteration"] = index
            row = trial["rows"][0]
            row["requestID"] = f"{partition}-{index}"
            row["workloadSHA256"] = hashlib.sha256(row["requestID"].encode()).hexdigest()
            report["trials"].append(trial)
        report["cooldowns"] *= count
        directory = ROOT / prefix / partition
        write(directory / "receipt.json", report)
        write(directory / "provenance.json", provenance)
        source_runs.append(reference_run(directory, ROOT))
    result = assemble_deadline_receipt(verified_source_runs({"source_runs": source_runs}, ROOT),
        profile_id="deadline-fixture", prompt_min=4096, prompt_max=4096, checks={})
    result["checks"] = references(result["identity"], result["build"])
    result["source_runs"] = source_runs
    return result
