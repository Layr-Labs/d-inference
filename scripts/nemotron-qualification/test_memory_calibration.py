"""CPU-only regression checks for persistent managed-owner reservations."""
import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest

spec = importlib.util.spec_from_file_location("memory_calibration", Path(__file__).with_name("memory_calibration.py"))
calibration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(calibration)


def snapshot(rows, charged=100):
    return {"charges": {"rows": rows, "unattributed_bytes": 0},
            "ledger": {"charged": charged, "owners": len(rows)},
            "context": {"bridge_active_requests": 0, "http_active_responses": 0}}


class PersistentOwnerTests(unittest.TestCase):
    def setUp(self):
        self.owners = [{"id": "lane", "kind": "prefill_lane"},
                       {"id": "bank", "kind": "prefix_bank"},
                       {"id": "round", "kind": "mtp_round"}]
        self.baseline = snapshot(self.owners)

    def settle(self, current):
        runner = SimpleNamespace(memory=lambda: current)
        probe = calibration.Calibration(runner, SimpleNamespace(seed=1234))
        probe.baseline = self.baseline
        return probe.settled(timeout=0)

    def test_idle_managed_owner_is_settled_without_refunding_its_reservations(self):
        result = self.settle(snapshot(self.owners))
        self.assertTrue(result["settled"])
        self.assertEqual(calibration.leak_verdict(result), "pass")

    def test_new_request_and_unknown_reservations_remain_visible_as_leaks(self):
        for kind in ["kv", "media", "media_ingress", "unknown"]:
            with self.subTest(kind=kind):
                result = self.settle(snapshot(self.owners + [{"id": "new", "kind": kind}], 110))
                self.assertFalse(result["settled"])
                self.assertEqual(calibration.leak_verdict(result), "fail")

    def test_owner_only_ledger_drift_still_requires_review(self):
        result = self.settle(snapshot(self.owners, 101))
        self.assertTrue(result["settled"])
        self.assertEqual(calibration.leak_verdict(result), "review")


if __name__ == '__main__':
    unittest.main()
