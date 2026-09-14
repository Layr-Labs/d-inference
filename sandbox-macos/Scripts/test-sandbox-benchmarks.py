#!/usr/bin/env python3
"""Validate native workload results and paired evidence rejection boundaries."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

MODULE_PATH = Path(__file__).with_name('benchmark-sandbox.py')
SPEC = importlib.util.spec_from_file_location('sandbox_benchmark', MODULE_PATH)
BENCHMARK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BENCHMARK)


class BenchmarkTests(unittest.TestCase):
    def test_native_result_matches_independent_integer_reference(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / 'cpu'
            subprocess.run(['xcrun', 'clang', '-O3', '-std=c11', '-pthread',
                            str(BENCHMARK.SOURCE), '-o', str(binary)], check=True)
            actual = json.loads(subprocess.check_output([str(binary), '3', '1000']))
            expected = 0
            mask = 2**64 - 1
            for index in range(3):
                value = 0x9e3779b97f4a7c15 ^ (index + 1)
                for _ in range(1000):
                    value ^= value >> 12
                    value ^= (value << 25) & mask
                    value ^= value >> 27
                    value = value * 2685821657736338717 & mask
                expected ^= value
            self.assertEqual(actual['checksum'], f'{expected:016x}')
            BENCHMARK.validate_sample(actual, 3, 1000)
            for workers, iterations in [('0', '1'), ('33', '1'), ('-1', '100'), ('1', '2000000001')]:
                result = subprocess.run([str(binary), workers, iterations], capture_output=True)
                self.assertEqual(result.returncode, 64)

    def test_invalid_or_wrong_workload_cannot_enter_evidence(self):
        sample = self.sample(1.0)
        for value in [0, -1, True, float('nan'), float('inf'), None, '1']:
            with self.assertRaises(ValueError):
                BENCHMARK.validate_sample({**sample, 'elapsed_seconds': value}, 4, 100)
        with self.assertRaises(ValueError):
            BENCHMARK.validate_sample({**sample, 'workers': 2}, 4, 100)

    def test_comparison_requires_same_result_and_separates_api_latency(self):
        host, guest = self.sample(1.0), self.sample(1.2)
        guest['caller_wall_seconds'] = 8.0
        result = BENCHMARK.summarize([{'host': host, 'guest': guest}])
        self.assertAlmostEqual(result['median_overhead_percent'], 20)
        self.assertEqual(result['median_guest_api_wall_seconds'], 8.0)
        with self.assertRaises(ValueError):
            BENCHMARK.summarize([{'host': host, 'guest': {**guest, 'checksum': 'f' * 16}}])
        with self.assertRaises(ValueError):
            BENCHMARK.summarize([])

    @staticmethod
    def sample(seconds):
        return {'schema_version': 1, 'workload': 'integer_recurrence_v1', 'workers': 4,
                'iterations': 100, 'checksum': '0' * 16, 'elapsed_seconds': seconds,
                'caller_wall_seconds': seconds}


if __name__ == '__main__':
    unittest.main()
