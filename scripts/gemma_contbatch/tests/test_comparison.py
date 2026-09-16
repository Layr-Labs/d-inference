"""Comparison schema, row identity, and refusal order without a benchmark."""

import copy
import unittest

from ..results import compare


def comparison_fixture():
    # Distinct changes make crossing a column or phase observable.
    current = {
        "prefill": [{"promptTokens": 128, "medianTokensPerSecond": 120, "medianElapsedMs": 40}],
        "schedulerTTFT": [{"promptTokens": 128, "medianTTFTMs": 75}],
        "decode": [{"batchSize": 4, "perRequestTokensPerSecond": 24, "aggregateTokensPerSecond": 96}],
        "arrival": [{"name": "burst", "medianTTFTMs": 90,
                     "medianAggregateDecodeTokensPerSecond": 150,
                     "medianEndToEndTokensPerSecond": 40, "medianMakespanMs": 600}],
    }
    baseline = {"name": "reference", "summary": {
        "prefill": [{"promptTokens": 128, "medianTokensPerSecond": 100, "medianElapsedMs": 50}],
        "schedulerTTFT": [{"promptTokens": 128, "medianTTFTMs": 100}],
        "decode": [{"batchSize": 4, "perRequestTokensPerSecond": 16, "aggregateTokensPerSecond": 120}],
        "arrival": [{"name": "burst", "medianTTFTMs": 60,
                     "medianAggregateDecodeTokensPerSecond": 100,
                     "medianEndToEndTokensPerSecond": 0, "medianMakespanMs": 800}],
    }}
    return current, baseline


class ComparisonTests(unittest.TestCase):
    def test_every_metric_preserves_schema_and_zero_baseline(self):
        current, baseline = comparison_fixture()
        original = copy.deepcopy((current, baseline))
        actual = compare(current, baseline)
        expected = {
            "baselineName": "reference",
            "prefill": [{"promptTokens": 128, "tokensPerSecondPercent": 20, "elapsedMsPercent": -20}],
            "schedulerTTFT": [{"promptTokens": 128, "ttftMsPercent": -25}],
            "decode": [{"batchSize": 4, "perRequestPercent": 50, "aggregatePercent": -20}],
            "arrival": [{"name": "burst", "ttftMsPercent": 50, "aggregateDecodePercent": 50,
                         "endToEndPercent": None, "makespanPercent": -25}],
        }
        self.assertEqual(list(actual), list(expected))
        self.assertEqual(actual.pop("baselineName"), expected.pop("baselineName"))
        for section in expected:
            self.assertEqual(len(actual[section]), 1)
            self.assertEqual(list(actual[section][0]), list(expected[section][0]))
            for key, value in expected[section][0].items():
                if isinstance(value, (float, int)):
                    self.assertAlmostEqual(actual[section][0][key], value)
                else:
                    self.assertEqual(actual[section][0][key], value)
        self.assertEqual((current, baseline), original)

    def test_duplicate_and_missing_rows_refuse_every_phase(self):
        for section in ("prefill", "schedulerTTFT", "decode", "arrival"):
            for side in ("current", "baseline"):
                for mutation in ("duplicate", "missing"):
                    with self.subTest(section=section, side=side, mutation=mutation):
                        current, baseline = comparison_fixture()
                        target = current if side == "current" else baseline["summary"]
                        target[section] = target[section] * 2 if mutation == "duplicate" else []
                        with self.assertRaisesRegex(RuntimeError, f"baseline {section} shape"):
                            compare(current, baseline)

    def test_first_invalid_phase_still_fails_first(self):
        current, baseline = comparison_fixture()
        baseline["summary"]["prefill"] = []
        baseline["summary"]["decode"] = []
        with self.assertRaisesRegex(RuntimeError, "baseline prefill shape"):
            compare(current, baseline)
