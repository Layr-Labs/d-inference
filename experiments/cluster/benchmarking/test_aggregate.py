"""Invented rates and failures; no workload, file IO or hardware measurements."""

import copy
from fractions import Fraction
import json
import math
import unittest

from .aggregate import INT63_MAX, summarize, validate_measurement
from .specification import make_schedule, read_study


def document():
    return dict(schema="cluster_prefill_study_v1", study_id="invented-study", seed=7,
                artifact_sha256="1" * 64, configuration_sha256="2" * 64, tokenizer_sha256="3" * 64,
                numerical_policy="invented-policy", chunk_size=512,
                prompts=[dict(id=f"p{i:02d}", prompt_sha256=f"{i + 1:064x}", origin_sha256=f"{i + 101:064x}")
                         for i in range(10)],
                conditions=[dict(id="solo", role="solo", runtime_identity_sha256="4" * 64, device_ids=["device-a"]),
                            dict(id="pair", role="distributed", runtime_identity_sha256="5" * 64,
                                 device_ids=["device-a", "device-b"])])


def measurement(elapsed=10**9):
    return dict(elapsed_ns=elapsed, prompt_tokens=8192, generated_tokens=1, source_sha256="6" * 64)


def completed(schedule, duration=None):
    return [dict(request_id=request["request_id"], status="completed",
                 measurement=measurement(duration(cohort, request) if duration else 10**9), error=None)
            for cohort in schedule for request in cohort["requests"]]


class AggregateTests(unittest.TestCase):
    def setUp(self):
        self.study = read_study(document())
        self.schedule = make_schedule(self.study)
        self.outcomes = completed(self.schedule)

    def summary(self, outcomes=None, errors=None):
        return summarize(self.study, self.schedule, self.outcomes if outcomes is None else outcomes,
                         [] if errors is None else errors)

    def assert_incomplete(self, result):
        self.assertEqual(result["aggregate_status"], "incomplete")
        for condition in result["conditions"]:
            self.assertIsNone(condition["median_of_prompt_medians_tps"])
            self.assertIsNone(condition["supplied_result_target_met"])
            self.assertIsNone(condition["supplied_result_stretch_met"])
        self.assertIsNone(result["median_paired_prompt_speedup"])
        self.assertIsNone(result["aggregate_distributed_over_solo_speedup"])

    def test_nested_not_pooled_or_mean_and_warmup_exclusion(self):
        # Four medians at 1s, one at 2s, five at 100s. The pooled middle
        # samples are 3s/100s, unlike the middle prompt medians 2s/100s.
        def duration(cohort, request):
            if request["phase"] == "warmup":
                return 1
            index = int(cohort["prompt_id"][1:])
            values = [1, 1, 100] if index < 4 else ([2, 2, 100] if index == 4 else [3, 100, 100])
            elapsed = values[request["iteration"]] * 10**9
            return elapsed if cohort["condition_id"] == "solo" else elapsed // 2
        result = self.summary(completed(self.schedule, duration))
        solo, pair = result["conditions"]
        expected = (Fraction(8192, 2) + Fraction(8192, 100)) / 2
        pooled = (Fraction(8192, 3) + Fraction(8192, 100)) / 2
        mean = (4 * Fraction(8192) + Fraction(8192, 2) + 5 * Fraction(8192, 100)) / 10
        self.assertEqual(solo["median_of_prompt_medians_tps"], float(expected))
        self.assertNotEqual(float(expected), float(pooled))
        self.assertNotEqual(float(expected), float(mean))
        self.assertEqual(pair["median_of_prompt_medians_tps"], float(2 * expected))
        self.assertEqual(solo["per_prompt"][4]["median_latency_ns"], 2 * 10**9)
        self.assertEqual(solo["p95_latency_ns"], 100 * 10**9)
        self.assertEqual(len(solo["measured_elapsed_ns"]), 30)
        self.assertNotIn(1, solo["measured_elapsed_ns"])
        self.assertEqual(result["median_paired_prompt_speedup"], 2.0)
        self.assertTrue(all(row["distributed_over_solo_speedup"] == 2.0 for row in result["paired_prompt_speedups"]))
        self.assertFalse(result["warmups_included_in_statistics"])
        self.assertFalse(result["performance_qualification"])
        self.assertFalse(result["runtime_admission"])

    def test_nearest_rank_p95_is_not_interpolated(self):
        def duration(cohort, request):
            return INT63_MAX if request["phase"] == "warmup" else (int(cohort["prompt_id"][1:]) * 3 + request["iteration"] + 1) * 1000
        result = self.summary(completed(self.schedule, duration))
        self.assertEqual(result["conditions"][0]["p95_latency_ns"], 29000)
        self.assertEqual(result["conditions"][0]["p95_sample_count"], 30)

    def test_missing_failed_skipped_and_warmup_failure_withhold_both_aggregates(self):
        for index, status in ((1, "missing"), (1, "failed"), (1, "skipped"), (0, "failed"), (0, "missing")):
            with self.subTest(index=index, status=status):
                outcomes = copy.deepcopy(self.outcomes)
                if status == "missing":
                    outcomes.pop(index)
                else:
                    outcomes[index].update(status=status, measurement=None, error="invented refusal")
                result = self.summary(outcomes)
                self.assert_incomplete(result)
                self.assertEqual(result["request_counts"][status], 1)
                successful = sum(row["measured_counts"]["completed"] for row in result["conditions"])
                self.assertEqual(successful, 59 if index else 60)
                self.assertTrue(any(sample["tps"] == 8192.0 for condition in result["conditions"]
                                    for prompt in condition["per_prompt"] for sample in prompt["measured_samples"]))

    def test_cohort_close_failure_after_all_measurements_is_incomplete(self):
        cohort = self.schedule[-1]["cohort_id"]
        errors = [dict(cohort_id=cohort, error="close failed"), dict(cohort_id=cohort, error="cleanup failed")]
        result = self.summary(errors=errors)
        self.assert_incomplete(result)
        self.assertEqual(result["request_counts"]["completed"], 80)
        self.assertEqual(result["cohort_error_count"], 2)
        self.assertEqual(sum(len(row["measured_elapsed_ns"]) for row in result["conditions"]), 60)

    def test_empty_outcomes_preserve_all_missing_counts(self):
        result = self.summary([])
        self.assert_incomplete(result)
        self.assertEqual(result["request_counts"], dict(planned=80, completed=0, failed=0, skipped=0, missing=80))
        self.assertTrue(all(row["p95_latency_ns"] is None for row in result["conditions"]))

    def test_duplicate_unplanned_outcomes_and_wrong_schedule_refused(self):
        for outcomes in (self.outcomes + [self.outcomes[0]],
                         self.outcomes[:-1] + [self.outcomes[0]],
                         [dict(self.outcomes[0], request_id="unplanned")]):
            with self.assertRaises(ValueError):
                self.summary(outcomes)
        for change in (lambda rows: rows.reverse(),
                       lambda rows: rows[0]["requests"][2].update(iteration=True),
                       lambda rows: rows[0].update(prompt_sha256="0" * 64)):
            schedule = copy.deepcopy(self.schedule)
            change(schedule)
            with self.assertRaises(ValueError):
                summarize(self.study, schedule, self.outcomes, [])

    def test_invalid_measurements_including_warmup_and_exact_bounds(self):
        changes = [dict(elapsed_ns=value) for value in (True, False, 0, -1, INT63_MAX + 1, 1.0, None)]
        changes += [dict(prompt_tokens=True), dict(prompt_tokens=8191), dict(generated_tokens=True),
                    dict(generated_tokens=2), dict(source_sha256="A" * 64), dict(extra=0)]
        for change in changes:
            with self.subTest(change=change):
                outcomes = copy.deepcopy(self.outcomes)
                outcomes[0]["measurement"].update(change)
                with self.assertRaises(ValueError):
                    self.summary(outcomes)
        for elapsed in (1, INT63_MAX):
            result = self.summary(completed(self.schedule, lambda cohort, request: elapsed))
            self.assertEqual(result["conditions"][0]["per_prompt"][0]["median_latency_ns"], elapsed)
            self.assertTrue(math.isfinite(result["conditions"][0]["median_of_prompt_medians_tps"]))
            json.dumps(result, allow_nan=False)

    def test_target_and_stretch_thresholds(self):
        for rate in (799, 800, 999, 1000):
            elapsed = (8192 * 10**9 + rate - 1) // rate
            result = self.summary(completed(self.schedule, lambda cohort, request: elapsed))
            exact = Fraction(8192 * 10**9, elapsed)
            self.assertEqual(result["conditions"][0]["supplied_result_target_met"], exact >= 800)
            self.assertEqual(result["conditions"][0]["supplied_result_stretch_met"], exact >= 1000)

    def test_conflicting_status_error_shapes_and_cohort_ids_refused(self):
        for update in (dict(status="other"), dict(measurement=None), dict(error="completed error"),
                       dict(status="failed", error="failure"), dict(status="skipped", measurement=None),
                       dict(status="failed", measurement=None, error="x" * 4097),
                       dict(status="failed", measurement=None, error="bad\x00error")):
            outcomes = copy.deepcopy(self.outcomes)
            outcomes[0].update(update)
            with self.assertRaises(ValueError):
                self.summary(outcomes)
        for errors in ([dict(cohort_id="unknown", error="failed")],
                       [dict(cohort_id=self.schedule[0]["cohort_id"], error=True)]):
            with self.assertRaises(ValueError):
                self.summary(errors=errors)

    def test_reordering_outcomes_and_mutating_returned_values_do_not_change_inputs(self):
        previous = copy.deepcopy((self.study, self.schedule, self.outcomes))
        result = self.summary()
        self.assertEqual(result, self.summary(list(reversed(self.outcomes))))
        result["conditions"][0]["device_ids"].append("annotation")
        result["conditions"][0]["per_prompt"][0]["measured_samples"][0]["tps"] = -1
        self.assertEqual((self.study, self.schedule, self.outcomes), previous)
        original = measurement()
        validated = validate_measurement(original)
        validated["elapsed_ns"] = 0
        self.assertEqual(original["elapsed_ns"], 10**9)


if __name__ == "__main__":
    unittest.main()
