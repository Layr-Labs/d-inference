"""Reproduce every promoted deadline record from its archived hardware runs."""
import json
from pathlib import Path
import unittest

from .catalog_codegen import ROOT, SOURCE
from .deadline_profile import evaluate_deadline_profile


INDEX = Path("scripts/serving_performance/catalog/deadline_evidence.json")


class ReviewedDeadlineEvidenceTests(unittest.TestCase):
    def evidence_path(self, root, relative):
        self.assertIsInstance(relative, str)
        path = (root / relative).resolve(strict=True)
        self.assertTrue(path.is_relative_to(root.resolve()), "evidence must stay inside its archive")
        return path

    def test_catalog_reproduces_the_qualified_raw_hardware_receipts(self):
        reviewed = json.loads((ROOT / SOURCE).read_bytes())
        index = json.loads((ROOT / INDEX).read_bytes())
        self.assertIsInstance(index, list)
        candidates = []
        for entry in index:
            root = self.evidence_path(ROOT, entry["evidence_root"])
            raw = self.evidence_path(root, entry["receipt"]).read_bytes()
            receipt = json.loads(raw)
            with self.subTest(profile=receipt["identity"]["id"]):
                # Qualification itself reconstructs every sample from bounded,
                # hash-checked source runs and verifies actual prerequisites.
                result = evaluate_deadline_profile(raw, evidence_root=root)
                self.assertTrue(result["qualified"], result["errors"])
                candidates.append(result["profile"])
        self.assertEqual(reviewed, candidates,
                         "every compiled record must exactly match its qualified real evidence")


if __name__ == "__main__":
    unittest.main()
