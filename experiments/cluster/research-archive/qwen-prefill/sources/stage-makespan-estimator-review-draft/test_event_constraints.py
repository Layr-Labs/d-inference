"""Independent invented event-graph checks; root executes against a supplied repo.

Usage: python3 test_event_constraints.py /path/to/d-inference
No model, source evidence, process launch, or physical measurement is involved.
"""

import copy
from pathlib import Path
import random
import sys
import unittest


if len(sys.argv) != 2:
    raise SystemExit("usage: test_event_constraints.py REPOSITORY_ROOT")
sys.path.insert(0, str(Path(sys.argv.pop()).resolve() / "experiments" / "cluster"))

from planning.costs import read_profile
from planning.rank import analyze
from planning.schedule import scenario


def cost(n):
    return {"low": n // 2, "typical": n, "high": n * 2 + 1}


def document(prepare, consume, handoff, completion, *, policy="serial_v1"):
    return {
        "schema": "cluster_prefill_costs_v1",
        "workload": {"artifact_sha256": "a" * 64, "tokens_sha256": "b" * 64,
                     "arithmetic": "invented", "prompt_tokens": len(prepare),
                     "chunk_tokens": 1, "batch_size": 1, "cache_mode": "uncached"},
        "baseline": None,
        "candidates": [{
            "id": "invented", "plan_sha256": "c" * 64,
            "devices": ["physical-a", "physical-b"],
            "resource_layout": "independent_devices", "policy": policy,
            "evidence_kind": "assumed", "source_sha256": ["d" * 64],
            "memory": [{"peak_bytes": cost(2), "budget_bytes": 100} for _ in range(2)],
            "startup_ns": cost(3), "return_token_ns": cost(2),
            "frames": [{"prepare_ns": cost(p), "consume_ns": cost(c),
                        "handoff_ns": cost(h), "completion_ns": cost(d)}
                       for p, c, h, d in zip(prepare, consume, handoff, completion)],
        }],
    }


def event_graph(candidate, level, omit_overhead=False):
    """Complete named events from predecessor constraints, not a sum formula."""
    frames = candidate["frames"]
    lookahead = candidate["policy"] == "prompt_lookahead_one_v1"
    durations = {}
    predecessors = {}

    def add(name, duration, dependencies):
        durations[name] = duration
        predecessors[name] = dependencies

    def value(record, key, overhead=False):
        return 0 if overhead and omit_overhead else getattr(record[key], level)

    add("start", value(candidate, "startup_ns", True), [])
    for index, frame in enumerate(frames):
        prior = "start" if index == 0 else (
            f"handoff-{index-1}" if lookahead else f"credit-{index-1}")
        add(f"prepare-{index}", value(frame, "prepare_ns"), [prior])
        handoff_dependencies = [f"prepare-{index}"]
        if index:
            handoff_dependencies.append(f"credit-{index-1}")
        add(f"handoff-{index}", value(frame, "handoff_ns", True), handoff_dependencies)
        add(f"consume-{index}", value(frame, "consume_ns"), [f"handoff-{index}"])
        credit_dependencies = [f"consume-{index}"]
        if lookahead and index + 1 < len(frames):
            credit_dependencies.append(f"prepare-{index+1}")
        add(f"credit-{index}", value(frame, "completion_ns", True), credit_dependencies)
    add("returned-token", value(candidate, "return_token_ns", True),
        [f"credit-{len(frames)-1}"])

    completed = {}
    remaining = set(durations)
    while remaining:
        ready = [node for node in remaining if all(p in completed for p in predecessors[node])]
        if not ready:
            raise AssertionError("test event constraints form a cycle")
        for node in ready:
            completed[node] = max((completed[p] for p in predecessors[node]), default=0) + durations[node]
        remaining.difference_update(ready)
    return completed


class IndependentEventConstraints(unittest.TestCase):
    def test_seeded_event_graph_and_timeline(self):
        rng = random.Random(9142026)
        for case in range(32):
            count = 1 + case % 6
            vectors = [[rng.randrange(10) for _ in range(count)] for _ in range(4)]
            for policy in ("serial_v1", "prompt_lookahead_one_v1"):
                candidate = read_profile(document(*vectors, policy=policy))["candidates"][0]
                for level in ("low", "typical", "high"):
                    for omit in (False, True):
                        with self.subTest(case=case, policy=policy, level=level, omit=omit):
                            expected = event_graph(candidate, level, omit)
                            total, timeline = scenario(candidate, level, omit_overhead=omit)
                            self.assertEqual(total, expected["returned-token"])
                            self.assertEqual(len(timeline), count)
                            for index, row in enumerate(timeline):
                                self.assertEqual(row["fork_ns"], expected[f"handoff-{index}"])
                                self.assertEqual(row["consume_end_ns"], expected[f"consume-{index}"])
                                self.assertEqual(row["completed_ns"], expected[f"credit-{index}"])
                                if index:
                                    self.assertGreaterEqual(row["fork_ns"], timeline[index-1]["completed_ns"])
                                if policy == "prompt_lookahead_one_v1" and index + 1 < count:
                                    self.assertEqual(row["next_prepare_end_ns"], expected[f"prepare-{index+1}"])
                                    self.assertGreaterEqual(row["join_ns"], row["next_prepare_end_ns"])
                                else:
                                    self.assertIsNone(row["next_prepare_end_ns"])
                                self.assertGreaterEqual(row["join_ns"], row["consume_end_ns"])

    def test_one_chunk_policies_are_identical(self):
        values = []
        for policy in ("serial_v1", "prompt_lookahead_one_v1"):
            candidate = read_profile(document([2], [17], [3], [5], policy=policy))["candidates"][0]
            values.append(scenario(candidate, "typical"))
        self.assertEqual(values[0], values[1])

    def test_unknown_handoff_does_not_become_measured_zero(self):
        raw = document([3, 5], [7, 2], [1, 2], [3, 4])
        raw["candidates"][0]["frames"][0]["handoff_ns"] = None
        analysis = analyze(raw)
        result = analysis["candidates"][0]
        self.assertEqual(result["status"], "missing_costs")
        self.assertIsNone(result["ttft_ns"])
        self.assertIsNotNone(result["zero_overhead_scenario_ns"])
        self.assertEqual(analysis["comparisons"], [])
        raw["candidates"][0]["frames"][0]["prepare_ns"] = None
        self.assertIsNone(analyze(raw)["candidates"][0]["zero_overhead_scenario_ns"])

    def test_unknown_or_exceeded_memory_is_never_ranked(self):
        for peak in (None, {"low": 1, "typical": 2, "high": 101}):
            raw = document([1], [1], [1], [1])
            raw["candidates"][0]["memory"][0]["peak_bytes"] = peak
            result = analyze(raw)
            self.assertEqual(result["candidates"][0]["status"], "memory_screen_failed")
            self.assertEqual(result["comparisons"], [])
            self.assertFalse(result["execution_admission"])

    def test_shared_physical_device_is_not_an_independent_lane(self):
        for policy in ("serial_v1", "prompt_lookahead_one_v1"):
            raw = document([2, 3], [4, 5], [1, 1], [1, 1], policy=policy)
            candidate = raw["candidates"][0]
            candidate["devices"] = ["same-gpu", "same-gpu"]
            candidate["resource_layout"] = "shared_device"
            result = analyze(raw)
            self.assertEqual(result["candidates"][0]["status"], "shared_device_not_modeled")
            self.assertIsNone(result["candidates"][0]["ttft_ns"])
            self.assertIsNone(result["candidates"][0]["zero_overhead_scenario_ns"])
            self.assertEqual(result["comparisons"], [])
            candidate["resource_layout"] = "independent_devices"
            with self.assertRaises(ValueError):
                analyze(raw)

    def test_comparison_groups_are_unordered_physical_device_sets(self):
        raw = document([2], [3], [1], [1])
        reverse = copy.deepcopy(raw["candidates"][0])
        reverse["id"] = "reverse"
        reverse["devices"].reverse()
        other = copy.deepcopy(reverse)
        other["id"] = "other-device"
        other["devices"] = ["physical-a", "physical-c"]
        raw["candidates"].extend([reverse, other])
        result = analyze(raw)
        groups = {tuple(group["devices"]): group for group in result["comparisons"]}
        self.assertEqual(set(groups), {("physical-a", "physical-b"), ("physical-a", "physical-c")})
        first = groups[("physical-a", "physical-b")]
        self.assertEqual({item["id"] for item in first["typical_ranking"]}, {"invented", "reverse"})
        self.assertIsNone(first["winner_across_supplied_ranges"])


if __name__ == "__main__":
    unittest.main()
