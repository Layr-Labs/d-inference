import copy
import json
from pathlib import Path
import unittest

from radix_forward_shapes import report_forward_shape_errors, validate_packet


def packet(rows=4, columns=1, phase="decode", physical=None, kind="target", before_count=0, calls=2):
    axes = {"phase": phase, "kind": kind, "live_batch_rows": rows,
            "sequence_width": columns, "physical_batch_rows": physical or rows}
    if kind == "compiled_component":
        axes.update(component="gptossExperts", physical_component_rows=8)
    def entry(count):
        return {"axes": dict(axes), "submitted_calls": count, "completed_calls": count}
    def snapshot(count):
        return {"schema": 1, "scope": 7, "enabled": True, "entries": [entry(count)] if count else [],
                "pending_steps": 0, "abandoned_steps": 0, "unobserved_dispatches": 0, "dropped_calls": 0}
    return {"schema": 1, "before": snapshot(before_count), "after": snapshot(before_count + calls),
            "delta": {"schema": 1, "scope": 7, "complete": True, "reasons": [],
                      "pending_steps_before": 0, "pending_steps_after": 0, "entries": [entry(calls)]}}


def timed_packet():
    value = packet(rows=1)
    for moment in ("before", "after"):
        value[moment].update(completed_step_timings=[], confirmed_token_timings=[],
                             dropped_step_timings=0, dropped_token_timings=0)
    value["after"]["completed_step_timings"] = [{"phase": "decode", "wall_nanos": 1000}]
    value["after"]["confirmed_token_timings"] = [
        {"row_ordinal": 0, "token_count": 1, "relative_nanos": 0},
        {"row_ordinal": 0, "token_count": 1, "relative_nanos": 1000},
    ]
    return value


class ForwardShapeTests(unittest.TestCase):
    def test_real_native_cache_packet_accepts_current_sdk_timing_receipts(self):
        fixture = json.loads((Path(__file__).parent / "fixtures"
                              / "native-cache-forward-shapes-with-timings.json").read_text())
        value = fixture["packet"]
        result = validate_packet(value, fixture["requested_width"])
        self.assertTrue(result["requested_target_width_observed"])
        self.assertEqual(result["completed_target_calls"], 66)
        self.assertEqual(value["after"]["pending_steps"], 0)
        self.assertTrue(value["after"]["completed_step_timings"])
        self.assertEqual(len(value["after"]["confirmed_token_timings"]), 64)

    def test_timing_receipts_reject_private_invalid_partial_and_unbounded_fields(self):
        variants = []
        for key in ("completed_step_timings", "confirmed_token_timings"):
            value = timed_packet(); value["after"][key][0]["prompt"] = "private"; variants.append(value)
        for key in ("dropped_step_timings", "dropped_token_timings"):
            for invalid in (-1, True, 1 << 64):
                value = timed_packet(); value["after"][key] = invalid; variants.append(value)
        for key, invalid in (("phase", "unknown"), ("wall_nanos", 0), ("wall_nanos", True)):
            value = timed_packet(); value["after"]["completed_step_timings"][0][key] = invalid; variants.append(value)
        for key, invalid in (("row_ordinal", 256), ("row_ordinal", True), ("token_count", 0),
                             ("token_count", 9), ("relative_nanos", -1), ("relative_nanos", True)):
            value = timed_packet(); value["after"]["confirmed_token_timings"][0][key] = invalid; variants.append(value)
        value = timed_packet(); value["after"]["confirmed_token_timings"][0]["relative_nanos"] = 1; variants.append(value)
        value = timed_packet(); value["after"]["confirmed_token_timings"].append(
            {"row_ordinal": 0, "token_count": 1, "relative_nanos": 999}); variants.append(value)
        value = timed_packet(); value["after"]["completed_step_timings"] *= 8193; variants.append(value)
        value = timed_packet(); value["after"]["confirmed_token_timings"] = [
            value["after"]["confirmed_token_timings"][0]] * 65_537; variants.append(value)
        value = timed_packet(); del value["after"]["dropped_token_timings"]; variants.append(value)
        for value in variants:
            with self.subTest(value=value["after"].keys()), self.assertRaises(ValueError):
                validate_packet(value, 1)

    def test_timing_arrays_append_in_one_scope_without_refunding_dropped_data(self):
        value = timed_packet()
        self.assertTrue(validate_packet(value, 1)["requested_target_width_observed"])
        for key in ("dropped_step_timings", "dropped_token_timings"):
            invalid = copy.deepcopy(value); invalid["after"][key] = 1
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, key):
                validate_packet(invalid, 1)
        for key in ("completed_step_timings", "confirmed_token_timings"):
            invalid = copy.deepcopy(value)
            invalid["before"][key] = copy.deepcopy(invalid["after"][key])
            invalid["after"][key] = []
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, "timing_counter_regression"):
                validate_packet(invalid, 1)
        invalid = timed_packet()
        for key in ("completed_step_timings", "confirmed_token_timings", "dropped_step_timings", "dropped_token_timings"):
            del invalid["before"][key]
        with self.assertRaisesRegex(ValueError, "timing_observation_changed"):
            validate_packet(invalid, 1)

    def test_real_target_width_is_required_despite_admission_and_row_totals(self):
        self.assertTrue(validate_packet(packet(), 4)["requested_target_width_observed"])
        self.assertFalse(validate_packet(packet(rows=1, calls=4), 4)["requested_target_width_observed"])
        report = {"schema": 3, "forward_shape_telemetry_schema": 1, "max_concurrent_requests": 4,
                  "batches": [{"id": "first", "peak_active_requests": 4,
                               "forward_shapes": packet(rows=1, calls=4)}],
                  "capacity": {"decode_rows_total": 400, "steps_executed": 100}}
        self.assertTrue(report_forward_shape_errors(report))

    def test_speculative_columns_and_padding_do_not_inflate_live_batch(self):
        for value in [packet(rows=1, columns=4, phase="mtp_verification"), packet(rows=2, physical=8)]:
            self.assertFalse(validate_packet(value, 4)["requested_target_width_observed"])
        with self.assertRaisesRegex(ValueError, "no_completed_target_calls"):
            validate_packet(packet(rows=4, kind="compiled_component"), 4)

    def test_actual_mtp_rows_are_distinct_from_sequence_width(self):
        result = validate_packet(packet(rows=4, columns=5, phase="mtp_verification"), 4)
        self.assertTrue(result["requested_decode_width_observed"])
        self.assertEqual(result["live_widths_by_phase"]["mtp_verification"], [4])

    def test_prefill_width_does_not_certify_decode_batching(self):
        result = validate_packet(packet(rows=4, columns=512, phase="prefill"), 4)
        self.assertTrue(result["requested_prefill_width_observed"])
        self.assertFalse(result["requested_decode_width_observed"])

    def test_delta_subtracts_prior_calls_and_rejects_forged_totals(self):
        value = packet(before_count=10, calls=2)
        self.assertEqual(validate_packet(value, 4)["completed_target_calls"], 2)
        value["delta"]["entries"][0].update(submitted_calls=12, completed_calls=12)
        with self.assertRaisesRegex(ValueError, "inconsistent_delta"):
            validate_packet(value, 4)

    def test_unconfirmed_refused_unknown_and_pending_work_cannot_pass(self):
        for counter in ["pending_steps", "abandoned_steps", "unobserved_dispatches", "dropped_calls"]:
            value = packet(); value["after"][counter] = 1
            with self.subTest(counter=counter), self.assertRaises(ValueError):
                validate_packet(value, 4)
        value = packet(); value["after"]["entries"][0]["completed_calls"] = 0
        with self.assertRaisesRegex(ValueError, "unconfirmed_calls"):
            validate_packet(value, 4)

    def test_scope_regression_duplicate_unbounded_and_private_payloads_refuse(self):
        variants = []
        value = packet(); value["after"]["scope"] = 8; variants.append(value)
        value = packet(before_count=3); value["after"]["entries"][0].update(submitted_calls=2, completed_calls=2); variants.append(value)
        value = packet(); value["after"]["entries"] *= 2; variants.append(value)
        value = packet(); value["after"]["entries"] *= 257; variants.append(value)
        value = packet(); value["after"]["entries"][0]["axes"]["token_ids"] = [123]; variants.append(value)
        value = packet(); value["after"]["entries"][0]["axes"]["live_batch_rows"] = 257; variants.append(value)
        for container in [None, "before", "after", "delta"]:
            value = packet()
            (value if container is None else value[container])["prompt"] = "private"
            variants.append(value)
        value = packet(); value["delta"]["pending_steps_after"] = False; variants.append(value)
        value = packet(); value["after"]["entries"][0]["submitted_calls"] = True; variants.append(value)
        for value in variants:
            with self.subTest(value=value), self.assertRaises(ValueError):
                validate_packet(value, 4)

    def test_schema3_requires_each_measured_cohort_and_ignores_warmup_proxy(self):
        report = {"schema": 3, "forward_shape_telemetry_schema": 1, "max_concurrent_requests": 2,
                  "warmup": {"forward_shapes": packet(rows=2)},
                  "batches": [{"id": "first"}, {"id": "repeat", "forward_shapes": packet(rows=2)}]}
        self.assertTrue(report_forward_shape_errors(report))
        report["batches"][0]["forward_shapes"] = packet(rows=2)
        self.assertFalse(report_forward_shape_errors(report))
        self.assertFalse(report_forward_shape_errors({"schema": 2}))  # historical integrity only


if __name__ == "__main__":
    unittest.main()
