import unittest

from .token_timings import measure


class TokenTimingsTests(unittest.TestCase):
    def test_accepted_bursts_preserve_rate_and_zero_gaps(self):
        shapes = {"droppedTokenTimings": 0, "confirmedTokenTimings": [
            {"rowOrdinal": 0, "tokenCount": 1, "relativeNanos": 0},
            {"rowOrdinal": 1, "tokenCount": 1, "relativeNanos": 0},
            {"rowOrdinal": 0, "tokenCount": 3, "relativeNanos": 100_000_000},
            {"rowOrdinal": 1, "tokenCount": 1, "relativeNanos": 100_000_000}]}
        rates, gaps, failures = measure(shapes, 2, 6)
        self.assertEqual(rates, [30., 10.])
        self.assertEqual(gaps, [100., 0., 0., 100.])
        self.assertEqual(failures, [])

    def test_partial_or_invalid_receipts_never_return_rates(self):
        for shapes in ({}, {"confirmedTokenTimings": [], "droppedTokenTimings": 1},
                       {"confirmedTokenTimings": [], "droppedTokenTimings": 0},
                       {"confirmedTokenTimings": [{"rowOrdinal": 0, "tokenCount": 9, "relativeNanos": 0}],
                        "droppedTokenTimings": 0}):
            rates, gaps, errors = measure(shapes, 1, 1)
            self.assertFalse(rates or gaps)
            self.assertTrue(errors)


if __name__ == "__main__":
    unittest.main()
