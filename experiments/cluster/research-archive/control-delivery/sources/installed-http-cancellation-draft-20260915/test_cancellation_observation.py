"""Deterministic observation/fallback contract; no SSH or process inference."""

import unittest
from harness.cancellation_observation import observe_after_close


class Clock:
    def __init__(self): self.value = 10.0
    def now(self): return self.value
    def sleep(self, amount): self.value += amount


class ObservationTests(unittest.TestCase):
    def test_waits_for_both_absence_and_empty_journals(self):
        clock = Clock(); calls = []
        def collect(rank, timeout):
            calls.append((rank, timeout)); clock.sleep(.1)
            return dict(active=[] if len(calls) > 2 else ["12 darkbloom"],
                        journalBytes=0 if len(calls) > 4 else 100)
        result = observe_after_close(10, 5, collect, lambda: False, clock.now, clock.sleep)
        self.assertTrue(result["self_retirement_observed"])
        self.assertEqual(len(result["samples"]), 3)
        self.assertTrue(all(0 < timeout <= 5 for _, timeout in calls))

    def test_guard_interference_precludes_self_retirement(self):
        clock = Clock(); interrupted = [False]
        def collect(rank, timeout):
            interrupted[0] = True
            return dict(active=[], journalBytes=0)
        result = observe_after_close(10, 5, collect, lambda: interrupted[0], clock.now, clock.sleep)
        self.assertFalse(result["self_retirement_observed"])
        self.assertTrue(result["harness_interference_observed"])

    def test_unknown_observation_never_means_absence(self):
        clock = Clock()
        def collect(rank, timeout): raise OSError("fabricated unavailable peer")
        result = observe_after_close(10, 3, collect, lambda: False, clock.now, clock.sleep)
        self.assertFalse(result["self_retirement_observed"])
        self.assertTrue(all(s["error_type"] == "OSError" for s in result["samples"]))
        self.assertEqual(result["elapsed_after_client_close_seconds"], 3)

    def test_late_proof_does_not_extend_deadline(self):
        clock = Clock()
        def collect(rank, timeout):
            clock.sleep(timeout + .1)
            return dict(active=[], journalBytes=0)
        result = observe_after_close(10, 1, collect, lambda: False, clock.now, clock.sleep)
        self.assertFalse(result["self_retirement_observed"])

    def test_boolean_journal_value_is_rejected(self):
        clock = Clock()
        result = observe_after_close(10, 1, lambda rank, timeout: dict(active=[], journalBytes=False),
                                     lambda: False, clock.now, clock.sleep)
        self.assertFalse(result["self_retirement_observed"])
        self.assertEqual(result["samples"][0]["error_type"], "ValueError")


if __name__ == "__main__":
    unittest.main()
