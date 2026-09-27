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


class ForwardShapeTests(unittest.TestCase):
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
