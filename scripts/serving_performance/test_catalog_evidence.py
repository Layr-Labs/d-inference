"""Reproduce every promoted deadline record from its archived hardware runs."""
import json
import os
from pathlib import Path
import unittest

from .catalog_codegen import ROOT, SOURCE
from .catalog_evidence import replay_catalog_evidence, validate_evidence_index
from .deadline_profile import evaluate_deadline_profile


INDEX = Path("scripts/serving_performance/catalog/deadline_evidence.json")


class ReviewedDeadlineEvidenceTests(unittest.TestCase):
    def test_endpoint_only_historical_cohort_cannot_qualify(self):
        archive = os.environ.get("DARKBLOOM_QUALIFICATION_EVIDENCE_ROOT")
        if not archive:
            self.skipTest("historical cohort is archived locally; set DARKBLOOM_QUALIFICATION_EVIDENCE_ROOT to verify it")
        root = Path(archive)
        raw = (root / "m5-deadline-qualification-receipt.json").read_bytes()
        result = evaluate_deadline_profile(raw, evidence_root=root)
        self.assertFalse(result["qualified"])
        self.assertTrue(result["errors"])

    def test_catalog_reproduces_the_qualified_raw_hardware_receipts(self):
        reviewed = json.loads((ROOT / SOURCE).read_bytes())
        index = json.loads((ROOT / INDEX).read_bytes())
        # Catalog/index omissions remain failures even without local archives.
        validate_evidence_index(reviewed, index)
        archive = os.environ.get("DARKBLOOM_QUALIFICATION_EVIDENCE_ROOT")
        if index and not archive:
            self.skipTest("promoted receipts are archived locally; set DARKBLOOM_QUALIFICATION_EVIDENCE_ROOT to verify them")
        self.assertEqual(reviewed, replay_catalog_evidence(reviewed, index, archive))


if __name__ == "__main__":
    unittest.main()
