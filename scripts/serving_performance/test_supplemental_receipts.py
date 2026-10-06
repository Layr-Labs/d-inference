import copy
import unittest

from serving_performance.supplemental_receipts import supplemental_summary


class SupplementalReceiptsTests(unittest.TestCase):
    def test_competing_requires_real_overlap_cancel_and_retirement(self):
        receipt = {"kind": "competing_models_supplement", "complete": True, "trials": [
            {"passed": True, "overlapProven": True, "retired": True, "competitorCancelled": True}]}
        self.assertTrue(supplemental_summary(receipt)["passed"])
        self.assertFalse(supplemental_summary(receipt)["qualified"])
        for field in ("passed", "overlapProven", "retired", "competitorCancelled"):
            invalid = copy.deepcopy(receipt)
            invalid["trials"][0].pop(field)
            self.assertFalse(supplemental_summary(invalid)["passed"], field)
        receipt["complete"] = False
        self.assertFalse(supplemental_summary(receipt)["passed"])

    def test_deadline_integration_retains_fallback_and_late_failures(self):
        row = {"failure": None, "deadlineEvidence": {"deliveredWithinBudget": True,
            "calibratedPathProven": True, "legacyWouldReject": True}}
        receipt = {"complete": True, "job": {"requireCalibratedAdmission": True}, "trials": [{"rows": [row]}]}
        summary = supplemental_summary(receipt)
        self.assertTrue(summary["passed"])
        self.assertFalse(summary["qualified"])
        self.assertEqual(summary["legacy_rejection_rows"], 1)
        for field in ("deliveredWithinBudget", "calibratedPathProven", "legacyWouldReject"):
            invalid = copy.deepcopy(receipt)
            invalid["trials"][0]["rows"][0]["deadlineEvidence"][field] = False
            self.assertFalse(supplemental_summary(invalid)["passed"])
        row["failure"] = "request_failed"
        self.assertFalse(supplemental_summary(receipt)["passed"])

    def test_wide_control_can_report_fallback_without_claiming_activation(self):
        receipt = {"complete": True, "job": {"requireCalibratedAdmission": False}, "trials": [{"rows": [
            {"failure": None, "deadlineEvidence": {"deliveredWithinBudget": True, "calibratedPathProven": False}}]}]}
        summary = supplemental_summary(receipt)
        self.assertTrue(summary["passed"])
        self.assertEqual(summary["calibrated_rows_proven"], 0)
        self.assertFalse(summary["qualified"])
        receipt["trials"] = []
        self.assertFalse(supplemental_summary(receipt)["passed"])
