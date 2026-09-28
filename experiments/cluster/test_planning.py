import contextlib
import copy
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from planning.__main__ import main, reject_constant, unique_object
from planning.fixtures import candidate, cost, profile
from planning.rank import analyze


class PlanningTests(unittest.TestCase):
    def result(self, value):
        return analyze(profile(value))["candidates"][0]

    def test_fill_drain_and_explicit_credit_handoff(self):
        value = candidate(handoff=5, completion=2)
        value["startup_ns"] = cost(3)
        value["return_token_ns"] = cost(7)
        result = self.result(value)
        self.assertEqual(result["ttft_ns"]["typical"], 71)
        self.assertEqual(result["zero_overhead_scenario_ns"]["typical"], 40)
        timeline = result["typical_timeline"]
        self.assertEqual([item["fork_ns"] for item in timeline], [18, 35, 52])
        self.assertEqual([item["completed_ns"] for item in timeline], [30, 47, 64])
        self.assertIsNone(timeline[-1]["next_prepare_end_ns"])
        self.assertEqual(sum(result["typical_breakdown_ns"].values()), 71)
        self.assertEqual(result["typical_breakdown_ns"]["exposed_prepare"], 10)

    def test_serial_has_no_hidden_overlap(self):
        value = candidate(handoff=5, completion=2, policy="serial_v1")
        result = self.result(value)
        self.assertEqual(result["ttft_ns"]["typical"], 81)
        self.assertTrue(all(item["next_prepare_end_ns"] is None
                            for item in result["typical_timeline"]))

    def test_final_head_and_selection_cost_cannot_disappear(self):
        self.assertEqual(self.result(candidate(consume=(10, 10, 100)))["ttft_ns"]["typical"], 130)

    def test_context_order_matters_even_with_identical_total_work(self):
        a = candidate(prepare=(9, 1, 8), consume=(1, 9, 2))
        b = candidate(prepare=(6, 6, 6), consume=(4, 4, 4))
        self.assertEqual(self.result(a)["ttft_ns"]["typical"], 21)
        self.assertEqual(self.result(b)["ttft_ns"]["typical"], 22)
        self.assertEqual(self.result(a)["typical_breakdown_ns"]["exposed_prepare"], 9)
        self.assertEqual(self.result(b)["typical_breakdown_ns"]["exposed_prepare"], 10)

    def test_one_chunk_and_partial_final_chunk(self):
        value = profile(candidate(prepare=(12,), consume=(8,), handoff=3, completion=2))
        value["workload"]["chunk_tokens"] = 12
        self.assertEqual(analyze(value)["candidates"][0]["ttft_ns"]["typical"], 25)
        value = profile()
        value["workload"]["prompt_tokens"] = 10
        self.assertEqual(analyze(value)["candidates"][0]["prefill_tps"]["typical"], 250_000_000)

    def test_missing_handoff_is_not_zero_or_a_rankable_estimate(self):
        value = candidate()
        value["frames"][1]["handoff_ns"] = None
        result = self.result(value)
        self.assertEqual(result["status"], "missing_costs")
        self.assertEqual(result["missing_costs"], ["frames[1].handoff_ns"])
        self.assertEqual(result["zero_overhead_scenario_ns"]["typical"], 40)
        self.assertIsNone(result["ttft_ns"])
        self.assertEqual(analyze(profile(value))["comparisons"], [])

    def test_missing_compute_prevents_even_zero_overhead_scenario(self):
        value = candidate()
        value["frames"][2]["consume_ns"] = None
        self.assertIsNone(self.result(value)["zero_overhead_scenario_ns"])

    def test_memory_unknown_and_over_budget_excluded_from_ranking(self):
        for peak in (None, cost(101)):
            value = candidate()
            value["memory"][1]["peak_bytes"] = peak
            result = self.result(value)
            self.assertEqual(result["status"], "memory_screen_failed")
            self.assertIsNotNone(result["ttft_ns"])
            self.assertEqual(analyze(profile(value))["comparisons"], [])

    def test_shared_gpu_never_becomes_two_independent_devices(self):
        for policy in ("serial_v1", "prompt_lookahead_one_v1"):
            value = candidate(policy=policy)
            value["devices"][1] = value["devices"][0]
            with self.assertRaises(ValueError):
                self.result(value)
            value["resource_layout"] = "shared_device"
            result = self.result(value)
            self.assertEqual(result["status"], "shared_device_not_modeled")
            self.assertIsNone(result["ttft_ns"])
            self.assertIsNone(result["zero_overhead_scenario_ns"])

    def test_unknown_target_memory_budget_prevents_ranking(self):
        value = candidate()
        value["memory"][0]["budget_bytes"] = None
        result = self.result(value)
        self.assertEqual(result["memory_issues"], ["memory[0].budget_bytes unknown"])
        self.assertEqual(result["status"], "memory_screen_failed")
        self.assertEqual(analyze(profile(value))["comparisons"], [])

    def test_ranges_are_monotonic_and_tps_order_reverses(self):
        value = candidate()
        for frame in value["frames"]:
            frame["consume_ns"] = cost(10, 5, 20)
        result = self.result(value)
        self.assertEqual(result["ttft_ns"], {"low": 35, "typical": 40, "high": 70})
        self.assertEqual(result["prefill_tps"]["low"], 12e9 / 70)
        self.assertEqual(result["prefill_tps"]["high"], 12e9 / 35)
        self.assertFalse(result["baseline_comparison"]["faster_across_supplied_ranges"])

    def test_solo_can_win_and_overlapping_scenarios_do_not_get_a_winner(self):
        document = profile(candidate(consume=(30, 30, 30)))
        result = analyze(document)
        self.assertEqual(result["comparisons"][0]["winner_across_supplied_ranges"],
                         {"id": "solo", "kind": "baseline"})
        document["baseline"]["ttft_ns"] = cost(100, 50, 110)
        self.assertIsNone(analyze(document)["comparisons"][0]["winner_across_supplied_ranges"])

    def test_rank_only_comparable_device_pairs(self):
        a, b = candidate("a"), candidate("b")
        b["devices"] = ["fabricated-device-c", "fabricated-device-d"]
        result = analyze(profile(a, b))
        self.assertEqual(len(result["comparisons"]), 2)
        self.assertIsNone(result["candidates"][1]["baseline_comparison"])
        self.assertIsNone(result["comparisons"][1]["winner_across_supplied_ranges"])
        self.assertFalse(result["execution_admission"])
        self.assertFalse(result["performance_qualification"])
        self.assertFalse(result["physical_measurement_verified"])

    def test_reordered_device_placement_compares_with_same_pair(self):
        a, b = candidate("a"), candidate("b")
        b["devices"].reverse()
        result = analyze(profile(a, b))
        self.assertEqual(len(result["comparisons"]), 1)
        self.assertIsNone(result["comparisons"][0]["winner_across_supplied_ranges"])

    def test_strict_numeric_schema_and_request_coverage(self):
        invalid = [True, -1, 1.5, float("nan"), float("inf"), 10**19, "10"]
        for number in invalid:
            value = candidate()
            value["frames"][0]["prepare_ns"]["typical"] = number
            with self.subTest(number=number), self.assertRaises(ValueError):
                self.result(value)
        mutations = [
            lambda d: d["candidates"][0]["frames"].pop(),
            lambda d: d["candidates"].append(copy.deepcopy(d["candidates"][0])),
            lambda d: d["workload"].update(batch_size=True),
            lambda d: d["workload"].update(cache_mode="prefix_hit"),
            lambda d: d["candidates"][0].update(policy="unbounded_pipeline"),
            lambda d: d["candidates"][0].update(evidence_kind="qualified"),
            lambda d: d["candidates"][0].update(source_sha256=[]),
            lambda d: d["candidates"][0].update(extra=0),
            lambda d: d["candidates"][0].update(startup_ns=cost(10, 11, 12)),
        ]
        for mutate in mutations:
            document = profile()
            mutate(document)
            with self.subTest(mutate=mutate), self.assertRaises(ValueError):
                analyze(document)

    def test_zero_complete_time_not_divided(self):
        result = self.result(candidate(prepare=(0, 0, 0), consume=(0, 0, 0)))
        self.assertEqual(result["status"], "nonpositive_modeled_time")
        self.assertIsNone(result["prefill_tps"])

    def test_cli_binds_raw_input_and_rejects_duplicate_and_nonfinite_json(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "costs.json"
            raw = json.dumps(profile()).encode()
            path.write_bytes(raw)
            output = io.StringIO()
            with patch("sys.argv", ["planning", str(path)]), contextlib.redirect_stdout(output):
                self.assertEqual(main(), 0)
            import hashlib
            self.assertEqual(json.loads(output.getvalue())["input_sha256"], hashlib.sha256(raw).hexdigest())
            for raw in (b'{"schema":1,"schema":2}', b'{"x":NaN}', b" " * (2 * 1024 * 1024 + 1)):
                path.write_bytes(raw)
                with patch("sys.argv", ["planning", str(path)]), contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(main(), 2)
        with self.assertRaises(ValueError):
            unique_object([("x", 1), ("x", 2)])
        with self.assertRaises(ValueError):
            reject_constant("Infinity")


if __name__ == "__main__":
    unittest.main()
