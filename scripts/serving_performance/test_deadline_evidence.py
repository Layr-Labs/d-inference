import copy
import json
import unittest

from .check_receipt_fixtures import ROOT
from .deadline_profile import evaluate_deadline_profile
from .deadline_receipt_fixtures import receipt


def evaluate(value):
    return evaluate_deadline_profile(json.dumps(value).encode(), evidence_root=ROOT)


class DeadlineEvidenceTests(unittest.TestCase):
    def test_intact_raw_runs_reproduce_the_promotable_candidate(self):
        result = evaluate(receipt())
        self.assertTrue(result["qualified"], result["errors"])

    def test_retained_digest_cannot_cover_changed_or_dropped_samples(self):
        original = receipt()
        for mutation in ("latency", "partition", "drop", "invent", "rate", "work", "identity"):
            value = copy.deepcopy(original)
            cell = value["deadline_calibration"]["cells"][0]
            if mutation == "latency": cell["samples"][-1]["observed_first_content_ms"] = 1
            elif mutation == "partition": cell["samples"][-1]["partition"] = "calibration"
            elif mutation == "drop": cell["samples"].pop()
            elif mutation == "invent": cell["samples"].append(copy.deepcopy(cell["samples"][-1]))
            elif mutation == "rate": cell["prefill_tps"] *= 2
            elif mutation == "work": cell["samples"][-1]["prefill_work_tokens"] = 1
            else: value["identity"]["effective_max_concurrency"] = 8
            result = evaluate(value)
            with self.subTest(mutation=mutation):
                self.assertFalse(result["qualified"])
                self.assertTrue(any("raw deadline evidence" in error for error in result["errors"]))

    def test_missing_tampered_duplicate_and_external_raw_files_fail_closed(self):
        original = receipt()
        for mutation in ("missing", "hash", "duplicate", "external", "malformed"):
            value = copy.deepcopy(original)
            if mutation == "missing": value.pop("source_runs")
            elif mutation == "hash": value["source_runs"][0]["receipt_sha256"] = "f" * 64
            elif mutation == "duplicate": value["source_runs"].append(value["source_runs"][0])
            elif mutation == "external": value["source_runs"][0]["receipt_path"] = "/etc/hosts"
            else: value["source_runs"][0] = None
            with self.subTest(mutation=mutation):
                self.assertFalse(evaluate(value)["qualified"])
        value = receipt()
        path = ROOT / value["source_runs"][0]["receipt_path"]
        path.write_bytes(path.read_bytes() + b" ")
        self.assertFalse(evaluate(value)["qualified"])
