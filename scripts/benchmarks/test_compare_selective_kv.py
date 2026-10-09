import copy
import unittest
from compare_selective_kv import compare


class SelectiveKVComparisonTests(unittest.TestCase):
    def reports(self):
        dense = dict(status="observed", inconclusiveReasons=[], scope="ordinary_teacher_forced_scores",
                     resolvedBackend="contiguous", concurrency=1, mtpEnabled=False, cacheMode="off",
                     peakMLXMemoryBytes=2000, meanForcedTokenNLL=1.5, plainTop1=[1, 2, 3],
                     selectiveKVMode="0", kvCapacityBytes=4096,
                     gemmaOptimizations={"prefillLayer18": True, "weightedR1": True})
        for key in ("inputSHA256", "verifiedModelAggregateSHA256", "executableSHA256", "metallibSHA256"):
            dense[key] = "a" * 64
        candidate = copy.deepcopy(dense)
        candidate.update(selectiveKVMode="half", meanForcedTokenNLL=1.75, plainTop1=[1, 9, 3],
                         peakMLXMemoryBytes=2200,
                         selectiveKVStatistics=dict(pruningEvents=2, tokenEntriesRemoved=32,
                             lastPruneSourceStorageBytes=1000, lastPruneRetainedStorageBytes=600))
        return dense, candidate

    def test_reports_quality_and_peak_cost_without_calling_it_a_pass(self):
        result = compare(*self.reports())
        self.assertEqual(result["status"], "observed")
        self.assertAlmostEqual(result["top1_agreement"], 2 / 3)
        self.assertEqual(result["mean_nll_delta"], 0.25)
        self.assertEqual(result["peak_mlx_bytes_delta"], 200)

    def test_refuses_cross_binary_comparison(self):
        dense, candidate = self.reports()
        candidate["executableSHA256"] = "b" * 64
        with self.assertRaisesRegex(ValueError, "executableSHA256"):
            compare(dense, candidate)

    def test_refuses_different_or_missing_execution_controls(self):
        for changes in ({"kvCapacityBytes": 8192}, {"kvCapacityBytes": None},
                        {"gemmaOptimizations": {"prefillLayer18": False, "weightedR1": True}},
                        {"gemmaOptimizations": None}, {"kvQuantization": "int4"}):
            dense, candidate = self.reports()
            candidate.update(changes)
            with self.assertRaises(ValueError):
                compare(dense, candidate)

    def test_refuses_unexecuted_retention(self):
        dense, candidate = self.reports()
        candidate["selectiveKVStatistics"]["pruningEvents"] = 0
        with self.assertRaisesRegex(ValueError, "did not execute"):
            compare(dense, candidate)

    def test_refuses_inconclusive_or_incomplete_scores(self):
        for change in ({"status": "inconclusive"}, {"plainTop1": []}, {"meanForcedTokenNLL": float("nan")}):
            dense, candidate = self.reports()
            candidate.update(change)
            with self.assertRaises(ValueError):
                compare(dense, candidate)

    def test_refuses_another_retention_candidate_as_control(self):
        dense, candidate = self.reports()
        dense["selectiveKVMode"] = "half"
        with self.assertRaisesRegex(ValueError, "dense control"):
            compare(dense, candidate)


if __name__ == "__main__":
    unittest.main()
