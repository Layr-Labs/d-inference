#!/usr/bin/env python3
"""CPU-only regressions for executed MTP work versus retained cost learning."""
from copy import deepcopy
import importlib.util
from pathlib import Path
import sys
import unittest

spec = importlib.util.spec_from_file_location('mtp_supervisor', Path(__file__).with_name('run-mtp-benchmark.py'))
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)


def seed_only():
    return dict(active=True, verificationMode='automatic', maxAutomaticRectangularTokens=8,
                rectangularVerificationRounds=0, serialVerificationRounds=0,
                selectedDepth=0, decodeRowBucket=8, rounds=0, seedRows=1,
                proposedTokens=0, acceptedDraftTokens=0, committedTokens=0,
                acceptanceByPosition=[], conditionalAcceptance=[], skippedRows={},
                depthSelections={'0': 127, '3': 1}, controllerFallbacks={'automatic_rectangular_limit': 127},
                costInputs=[], totalRoundWallTimeNanos=0)


class MetricContracts(unittest.TestCase):
    def test_observed_seed_only_cap_fallback(self):
        self.assertTrue(module.validate_automatic_fixed_fallback(seed_only(), 8, 3, 'observed'))

    def test_original_zero_seed_fallback(self):
        value = seed_only()
        value.update(seedRows=0, depthSelections={'0': 127})
        self.assertTrue(module.validate_automatic_fixed_fallback(value, 8, 3, 'zero'))

    def test_unexplained_seed_or_positive_plans_are_rejected(self):
        for updates in [dict(seedRows=0), dict(depthSelections={'0': 127}),
                        dict(depthSelections={'0': 127, '3': 2}), dict(seedRows=-1),
                        dict(depthSelections={'bad': 1}), dict(depthSelections={'3': True})]:
            value = seed_only(); value.update(updates)
            with self.subTest(updates=updates), self.assertRaises(ValueError):
                module.validate_automatic_fixed_fallback(value, 8, 3, 'invalid')

    def test_seed_does_not_excuse_speculative_residue(self):
        for field in ['proposedTokens', 'acceptedDraftTokens', 'committedTokens',
                      'rectangularVerificationRounds', 'serialVerificationRounds',
                      'totalRoundWallTimeNanos']:
            value = seed_only(); value[field] = 1
            with self.subTest(field=field), self.assertRaises(ValueError):
                module.validate_automatic_fixed_fallback(value, 8, 3, 'residue')

    def test_fallback_reason_and_work_cap_remain_required(self):
        value = seed_only(); value['controllerFallbacks'] = {}
        with self.assertRaises(ValueError):
            module.validate_automatic_fixed_fallback(value, 8, 3, 'missing reason')
        value = seed_only()
        value['costInputs'] = [dict(decodeRowBucket=8, draftDepth=1, sampleCount=1)]
        with self.assertRaises(ValueError):
            module.validate_automatic_fixed_fallback(value, 8, 3, 'over cap')
        self.assertFalse(module.validate_automatic_fixed_fallback(seed_only(), 1, 3, 'inside cap'))

    def test_actual_clamped_rounds_still_pass(self):
        value = seed_only()
        value.update(rounds=2, proposedTokens=2, rectangularVerificationRounds=2,
                     selectedDepth=1, decodeRowBucket=4, depthSelections={'1': 2})
        self.assertTrue(module.validate_automatic_fixed_fallback(value, 4, 2, 'clamped'))

    def test_executed_work_without_retained_cost_is_correctness_only(self):
        value = dict(rectangularVerificationRounds=8, serialVerificationRounds=0,
                     acceptanceByPosition=[7], costInputs=[])
        self.assertTrue(module.has_cost_or_verified_depth(value, 1, 1, exact=False, require_cost=False))
        self.assertFalse(module.has_cost_or_verified_depth(value, 1, 1, exact=False, require_cost=True))

    def test_cost_exemption_requires_real_verification_and_requested_depth(self):
        valid = dict(rectangularVerificationRounds=8, serialVerificationRounds=0,
                     acceptanceByPosition=[0, 0], costInputs=[])
        self.assertTrue(module.has_cost_or_verified_depth(valid, 1, 2, exact=True, require_cost=False))
        for updates in [dict(rectangularVerificationRounds=0), dict(acceptanceByPosition=[0]),
                        dict(rectangularVerificationRounds=-1), dict(serialVerificationRounds=False)]:
            value = deepcopy(valid); value.update(updates)
            with self.subTest(updates=updates):
                self.assertFalse(module.has_cost_or_verified_depth(value, 1, 2, exact=True, require_cost=False))

    def test_performance_cost_must_match_bucket_depth_and_samples(self):
        value = dict(costInputs=[dict(decodeRowBucket=2, draftDepth=3, sampleCount=1)])
        self.assertTrue(module.has_cost_or_verified_depth(value, 2, 3, exact=True, require_cost=True))
        self.assertFalse(module.has_cost_or_verified_depth(value, 1, 3, exact=True, require_cost=True))
        self.assertFalse(module.has_cost_or_verified_depth(value, 2, 2, exact=True, require_cost=True))
        value['costInputs'][0]['sampleCount'] = 0
        self.assertFalse(module.has_cost_or_verified_depth(value, 2, 3, exact=True, require_cost=True))


if __name__ == '__main__':
    unittest.main()
