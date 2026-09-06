import json
from pathlib import Path
import tempfile
import unittest

import numpy as np

from attention_packet.files import PacketError
from attention_packet.packet import load_packet
from attention_packet.reference import analyze, attention, statistics
from attention_packet_fixtures import Fixture, oracle


class AttentionNumericsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def test_d256_qh16_kvh2_all_native_dtypes_and_wider_query(self):
        combinations = [("float16", "float16"), ("bfloat16", "bfloat16"), ("float32", "float32"),
                        ("float32", "bfloat16"), ("float32", "float16")]
        for index, (q_dtype, kv_dtype) in enumerate(combinations):
            with self.subTest(q_dtype=q_dtype, kv_dtype=kv_dtype):
                f = Fixture(self.root / str(index), q_dtype=q_dtype, kv_dtype=kv_dtype,
                            output_dtype=q_dtype, dimension=256, length=17)
                report = analyze(load_packet(f.save()))
                self.assertEqual(report["status"], "analyzed")
                primary = report["originalQueryReference"]["comparison"]
                self.assertEqual(len(primary["perHead"]), 16)
                self.assertLess(primary["global"]["relativeL2"], 0.003)
                self.assertLess(report["referenceRoundedToOutputDType"]["comparison"]["global"]["linf"], 2e-5)
                counterfactual = report["narrowedQueryCounterfactual"]
                if q_dtype == "float32" and kv_dtype != "float32":
                    self.assertGreater(counterfactual["differenceFromOriginalReference"]["global"]["linf"], 0)
                    self.assertGreater(counterfactual["queryRoundingDifference"]["global"]["linf"], 0)
                else:
                    self.assertIsNone(counterfactual)
                json.dumps(report, allow_nan=False)

    def test_uniform_softmax_analytic_reference_and_contiguous_gqa_groups(self):
        f = Fixture(self.root / "uniform", uniform=True, length=19, dimension=16)
        actual, stages = attention(f.values["queries"], f.values["storedKeys"], f.values["storedValues"], f.scale)
        self.assertEqual(actual.dtype, np.float32)
        for head in range(16):
            expected = f.values["storedValues"][0, head // 8].astype(np.float64).mean(axis=0)
            np.testing.assert_allclose(actual[0, head, 0], expected, rtol=1e-6, atol=1e-6)
            self.assertEqual(stages[head]["kvHead"], head // 8)

    def test_full_t5585_d256_packet_fits_bound_for_bf16_and_fp32_storage(self):
        for dtype in ("bfloat16", "float32"):
            with self.subTest(dtype=dtype):
                f = Fixture(self.root / ("long-" + dtype), kv_dtype=dtype, length=5585, dimension=256)
                report = analyze(load_packet(f.save()))
                self.assertEqual(report["status"], "analyzed")
                self.assertEqual(report["selection"]["offsetAfter"], 5585)
                self.assertLess(report["originalQueryReference"]["comparison"]["global"]["linf"], 5e-6)

    def test_planted_transpose_wrong_head_map_and_dropped_last_attention_are_visible(self):
        f = Fixture(self.root / "faults")
        normal = analyze(load_packet(f.save()))["originalQueryReference"]["comparison"]["global"]["linf"]
        self.assertLess(normal, 5e-6)
        faults = {"transpose_keys": {"transpose_keys": True},
                  "interleaved_head_map": {"head_map": lambda head: head % 2},
                  "drop_last_token": {"drop_last": True}}
        for name, options in faults.items():
            wrong = oracle(f.values["queries"], f.values["storedKeys"], f.values["storedValues"], f.scale, **options)
            f.set_tensor("output", wrong)
            report = analyze(load_packet(f.save()))
            comparison = report["originalQueryReference"]["comparison"]
            with self.subTest(fault=name):
                self.assertGreater(comparison["global"]["linf"], 0.5)
                self.assertGreater(comparison["global"]["rmse"], 0.1)
                self.assertTrue(any(row["linf"] > 0.5 for row in comparison["perHead"]))
                self.assertEqual(report["lastRowConsistency"]["storedKeys"]["mismatchedNativeElements"], 0)

    def test_shortened_postwrite_packet_cannot_silently_drop_final_token(self):
        f = Fixture(self.root / "shortened")
        f.set_tensor("storedKeys", f.values["storedKeys"][:, :, :-1])
        f.set_tensor("storedValues", f.values["storedValues"][:, :, :-1])
        with self.assertRaisesRegex(PacketError, "visible range/last token mismatch"):
            load_packet(f.save())

    def test_bitwise_last_row_detects_signed_zero_without_claiming_full_history(self):
        f = Fixture(self.root / "signedzero")
        keys = f.values["storedKeys"].copy()
        keys[0, 0, -1, 0] = 0.0
        f.set_tensor("storedKeys", keys)
        incoming = keys[:, :, -1:, :].copy()
        incoming[0, 0, 0, 0] = -0.0
        f.set_tensor("incomingKeys", incoming)
        report = analyze(load_packet(f.save()))
        self.assertEqual(report["lastRowConsistency"]["storedKeys"]["mismatchedNativeElements"], 1)
        self.assertEqual(report["status"], "inconclusive")
        self.assertTrue(any("independent mirror" in note for note in report["limitations"]))

    def test_self_consistent_wrong_history_remains_outside_comparator_proof(self):
        f = Fixture(self.root / "shared-fault")
        corrupt = f.values["storedValues"][:, ::-1].copy()
        f.set_tensor("storedValues", corrupt)
        f.set_tensor("incomingValues", corrupt[:, :, -1:, :])
        f.set_tensor("output", oracle(f.values["queries"], f.values["storedKeys"], corrupt, f.scale))
        report = analyze(load_packet(f.save()))
        self.assertEqual(report["status"], "analyzed")
        self.assertLess(report["originalQueryReference"]["comparison"]["global"]["linf"], 5e-6)
        self.assertNotIn("storageCorrect", report)
        self.assertTrue(any("layout fault" in note for note in report["limitations"]))

    def test_nonfinite_input_output_and_zero_norm_are_explicit_not_hidden(self):
        f = Fixture(self.root / "nonfinite")
        original = f.values["queries"].copy()
        query = original.copy()
        query[0, 0, 0, 0] = np.nan
        f.set_tensor("queries", query)
        report = analyze(load_packet(f.save()))
        self.assertEqual(report["tensorNonfinite"]["queries"]["nan"], 1)
        self.assertEqual(report["status"], "inconclusive")
        self.assertNotIn("originalQueryReference", report)
        f.set_tensor("queries", original)
        output = f.values["output"].copy()
        output[0, 0, 0, :3] = [np.nan, np.inf, -np.inf]
        f.set_tensor("output", output)
        report = analyze(load_packet(f.save()))
        self.assertEqual(report["tensorNonfinite"]["output"], {"nan": 1, "positiveInfinity": 1, "negativeInfinity": 1})
        self.assertIsNone(report["originalQueryReference"]["comparison"]["global"]["linf"])
        self.assertEqual(report["status"], "inconclusive")
        json.dumps(report, allow_nan=False)
        zero = np.zeros((1, 1, 1, 4), dtype=np.float32)
        self.assertEqual(statistics(zero, zero)["relativeL2"], 0)
        undefined = statistics(np.ones_like(zero), zero)
        self.assertIsNone(undefined["relativeL2"])
        self.assertEqual(undefined["undefinedReason"], "zero reference norm with nonzero error")


if __name__ == "__main__":
    unittest.main()
