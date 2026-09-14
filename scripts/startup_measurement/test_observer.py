from datetime import datetime, timedelta, timezone
import json
import unittest

from .http_probe import Result
from .observer import Observer, Settings

BUILD = "a" * 40
START = datetime(2026, 9, 9, tzinfo=timezone.utc)


def model(name, count=1, ready=True, accept=True):
    return {"id": name, "ready": ready, "can_accept": accept, "routable_providers": count}


class FakeClock:
    def __init__(self):
        self.elapsed = 0

    def monotonic(self):
        return self.elapsed

    def now(self):
        return START + timedelta(seconds=self.elapsed)

    def sleep(self, value):
        self.elapsed += value


class SequenceClient:
    def __init__(self, rounds):
        self.rounds = rounds
        self.index = -1
        self.calls = []

    def request(self, path, timeout, **kwargs):
        self.calls.append((path, kwargs))
        if path == "/health":
            self.index = min(self.index + 1, len(self.rounds) - 1)
        current = self.rounds[self.index]
        if path == "/health":
            return Result(current.get("status", 200), "json", {"status": "ok", "build_commit": current.get("build", BUILD), "secret": "not-for-report"})
        if path == "/readyz":
            return Result(200, "json", {"ready": current.get("ready", True), "draining": current.get("draining", False)})
        return Result(200, "json", {"models": current.get("models", []), "secret": "not-for-report"})


class FakeProbe:
    max_attempts = 3

    def __init__(self, available=False, correct=False):
        self.available = available
        self.correct = correct

    def run(self, client, selected_model, timeout):
        return {"status": 200, "outcome": "json", "availability_success": self.available,
                "synthetic_answer_matches": self.correct if self.available else None}


class ObserverTests(unittest.TestCase):
    def settings(self, **kwargs):
        return Settings("http://127.0.0.1:9000", BUILD, ["m1", "m2"], START,
                        old_process_stopped_at=START - timedelta(seconds=2), **kwargs)

    def test_old_build_liveness_and_capacity_do_not_imply_serving(self):
        client = SequenceClient([
            {"status": 503},
            {"build": "b" * 40},
            {"models": []},
            {"ready": False, "models": [model("m1"), model("m2")]},
            {"models": [model("m1", 2), model("m2", 0)]},
            {"models": [model("m1", 2), model("m2", 1)]},
        ])
        report = Observer(self.settings(), client=client, clock=FakeClock()).run()
        self.assertTrue(report["measurement_target_reached"])
        self.assertFalse(report["inference_verified"])
        self.assertEqual("not_measured", report["correctness"])
        milestones = report["milestones"]
        self.assertEqual(1000, milestones["candidate_health"]["first_satisfied"]["process_start_ms"])
        self.assertEqual(2000, milestones["capacity:m1"]["first_satisfied"]["process_start_ms"])
        self.assertEqual(2500, milestones["all_models_capacity"]["first_satisfied"]["process_start_ms"])
        self.assertEqual(4500, milestones["all_models_capacity"]["first_satisfied"]["old_stop_ms"])
        self.assertNotIn("not-for-report", json.dumps(report))
        self.assertTrue(all(not kwargs for _, kwargs in client.calls))
        self.assertNotIn("/v1/chat/completions", [path for path, _ in client.calls])

    def test_health_ready_with_zero_capacity_times_out(self):
        report = Observer(self.settings(duration=1), client=SequenceClient([{}]), clock=FakeClock()).run()
        self.assertFalse(report["measurement_target_reached"])
        self.assertIn("candidate_health", report["milestones"])
        self.assertIn("ready", report["milestones"])
        self.assertNotIn("all_models_capacity", report["milestones"])

    def test_late_observer_is_left_censored(self):
        client = SequenceClient([{"models": [model("m1"), model("m2")]}])
        report = Observer(self.settings(), client=client, clock=FakeClock()).run()
        self.assertTrue(report["milestones"]["all_models_capacity"]["left_censored"])
        self.assertIsNone(report["milestones"]["all_models_capacity"]["last_unsatisfied"])

    def test_duplicate_malformed_or_unacceptable_capacity_refuses(self):
        for rows in ([model("m1"), model("m1"), model("m2")],
                     [model("m1", True), model("m2")],
                     [model("m1", accept=False), model("m2")],
                     [model("m1", ready=False), model("m2")]):
            report = Observer(self.settings(duration=0.5), client=SequenceClient([{"models": rows}]), clock=FakeClock()).run()
            self.assertFalse(report["measurement_target_reached"])

    def test_http_200_without_complete_inference_is_not_success(self):
        client = SequenceClient([{"models": [model("m1"), model("m2")]}])
        report = Observer(self.settings(duration=10), client=client, clock=FakeClock(), probe=FakeProbe()).run()
        self.assertFalse(report["measurement_target_reached"])
        self.assertFalse(report["inference_verified"])
        self.assertEqual(6, len(report["inference_probes"]))  # three/model, globally rate-bounded
        self.assertEqual("incomplete", report["correctness"])

    def test_availability_and_synthetic_correctness_are_distinct(self):
        client = SequenceClient([{"models": [model("m1"), model("m2")]}])
        report = Observer(self.settings(), client=client, clock=FakeClock(), probe=FakeProbe(available=True)).run()
        self.assertTrue(report["inference_verified"])
        self.assertTrue(report["measurement_target_reached"])
        self.assertEqual("failed", report["correctness"])
        self.assertEqual(2, len(report["inference_probes"]))
        self.assertEqual(0, report["milestones"]["first_inference"]["first_satisfied"]["process_start_ms"])
        self.assertEqual(1000, report["inference_probes"][1]["since_model_first_capacity_ms"])
        self.assertNotIn("content", json.dumps(report))


if __name__ == "__main__":
    unittest.main()
