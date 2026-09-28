"""Comparator CLI must reject inputs that could turn parity checks into a pass."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


CHECKER = Path(__file__).parent / 'inference' / 'check_logits.py'


class LogitComparatorTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)

    def run_check(self, reference, candidate, absolute='0.01', rms='0.01', greedy=False):
        paths = [self.directory / 'reference.json', self.directory / 'candidate.json']
        for path, matrix in zip(paths, (reference, candidate)):
            path.write_text(json.dumps(matrix))
        command = [sys.executable, str(CHECKER), *map(str, paths),
                   '--max-relative-rms=' + rms, '--max-absolute=' + absolute]
        if greedy:
            command.append('--require-greedy-agreement')
        return subprocess.run(command, capture_output=True, text=True, timeout=5)

    def assert_invalid(self, result):
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(result.stdout, '')
        self.assertNotIn('Traceback', result.stderr)

    def test_infinite_nan_zero_and_negative_thresholds_cannot_disable_the_gate(self):
        for threshold in ('inf', '+Infinity', '-inf', 'nan', '0', '-1', 'true'):
            for field in ('absolute', 'rms'):
                with self.subTest(threshold=threshold, field=field):
                    self.assert_invalid(self.run_check([[1, 0]], [[0, 1]], **{field: threshold}))

    def test_boolean_and_nonnumeric_logits_are_rejected_on_either_side(self):
        for value in (True, False, '1', None, {}, [], float('nan'), float('inf'), 10**1000):
            for side in (0, 1):
                matrices = [[[1, 0]], [[1, 0]]]
                matrices[side] = [[1, value]]
                with self.subTest(value=str(value)[:30], side=side):
                    self.assert_invalid(self.run_check(*matrices))

    def test_malformed_matrix_or_row_cannot_be_treated_as_numeric_sequences(self):
        for matrix in ({'row': [1, 2]}, True, [1, 2], ['12'], [], [[]]):
            with self.subTest(matrix=matrix):
                self.assert_invalid(self.run_check(matrix, matrix))

    def test_valid_pass_and_failure_report_the_exact_finite_thresholds(self):
        for candidate, code in (([[1.001, 0]], 0), ([[2, 0]], 1)):
            result = self.run_check([[1, 0]], candidate, absolute='0.02', rms='0.005')
            self.assertEqual(result.returncode, code, result.stderr)
            report = json.loads(result.stdout)
            self.assertEqual(report['requested_tolerances'], dict(max_relative_rms=0.005, max_absolute=0.02))
            self.assertEqual(report['passed'], code == 0)

    def test_greedy_disagreement_remains_a_separate_explicit_gate(self):
        # Numerically close outputs can have different winning tokens.
        reference, candidate = [[1, 0.999]], [[0.999, 1]]
        self.assertEqual(self.run_check(reference, candidate).returncode, 0)
        result = self.run_check(reference, candidate, greedy=True)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertFalse(json.loads(result.stdout)['greedy_tokens_equal'])

    def test_nonfinite_derived_error_cannot_emit_a_pass_or_invalid_json(self):
        self.assert_invalid(self.run_check([[1e308]], [[-1e308]]))


if __name__ == '__main__':
    unittest.main()
