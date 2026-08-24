#!/usr/bin/env python3

from __future__ import annotations

import math
import unittest

import numpy as np

import budget
import probe


class ArithmeticBudgetTests(unittest.TestCase):
    def test_binding_composition_threshold_matches_measured_ledger(self) -> None:
        composition = budget.b4_8k_composition(0.35812222392962534)

        self.assertAlmostEqual(composition.native_speedup, 2.5, places=10)
        self.assertAlmostEqual(
            composition.maximum_linear_fraction,
            0.35812222392962534,
            places=10,
        )
        self.assertAlmostEqual(
            1 / composition.maximum_linear_fraction,
            2.792342762275793,
            places=10,
        )

    def test_dense_budget_charges_every_declared_term(self) -> None:
        result = budget.dense_budget(
            rows=64,
            input_width=32,
            output_width=48,
            rank=4,
            sentinel_columns=3,
            repair_rows=5,
            power_iterations=1,
        )

        self.assertEqual(result.baseline_macs, 64 * 32 * 48)
        self.assertEqual(result.candidate_macs, sum(result.components.values()))
        self.assertEqual(
            result.components["power_iterations"], 2 * 64 * 32 * 4
        )
        self.assertEqual(
            result.components["repair_weight_projection"], 5 * 32 * 48
        )

    def test_expert_budget_projects_basis_through_every_expert(self) -> None:
        result = budget.expert_budget(
            assignments=128,
            experts=8,
            input_width=32,
            output_width=64,
            rank=4,
            sentinel_columns=2,
            repair_assignments=10,
        )

        self.assertEqual(result.baseline_macs, 128 * 32 * 64)
        self.assertEqual(
            result.components["all_expert_basis_projection"],
            8 * 4 * 32 * 64,
        )
        self.assertEqual(
            result.components["routed_output_reconstruction"], 128 * 4 * 64
        )

    def test_preregistered_schedule_covers_topk4_linear_ledger(self) -> None:
        schedule = budget.preregistered_b4_schedule()

        self.assertAlmostEqual(
            schedule["topk4_linear_gflop_per_token"],
            budget.TOPK4_LINEAR_GFLOP_PER_TOKEN,
            places=12,
        )
        self.assertAlmostEqual(
            schedule["candidate_linear_gflop_per_token"],
            0.94326088,
            places=8,
        )
        self.assertAlmostEqual(
            schedule["effective_linear_fraction"],
            0.24393913476256304,
            places=12,
        )
        self.assertGreater(
            schedule["composition"]["native_speedup"],
            3.10,
        )


class NumericalProbeTests(unittest.TestCase):
    def test_rank_complete_fixture_reconstructs_projection(self) -> None:
        activations, weights = probe.synthetic_matrices(
            rows=128,
            input_width=32,
            output_width=64,
            intrinsic_rank=4,
            noise=0,
            seed=7,
        )
        q, coefficients = probe.orthonormal_activation_basis(
            activations, rank=4, power_iterations=0, seed=11
        )
        metrics, _ = probe.output_metrics(
            activations=activations,
            weights=weights,
            basis_rows=q,
            basis_coefficients=coefficients,
            repair_indices=np.empty(0, dtype=np.int64),
            chunk_rows=17,
        )

        self.assertLess(metrics["nrmse"], 2e-6)
        self.assertLess(metrics["p99_row_relative_l2"], 3e-6)
        self.assertGreater(metrics["p01_row_cosine"], 0.999999)

    def test_full_residual_repair_recovers_all_rows(self) -> None:
        activations, weights = probe.synthetic_matrices(
            rows=96,
            input_width=24,
            output_width=40,
            intrinsic_rank=12,
            noise=0.01,
            seed=13,
        )
        q, coefficients = probe.orthonormal_activation_basis(
            activations, rank=2, power_iterations=0, seed=17
        )
        repairs = np.arange(activations.shape[0], dtype=np.int64)
        metrics, before = probe.output_metrics(
            activations=activations,
            weights=weights,
            basis_rows=q,
            basis_coefficients=coefficients,
            repair_indices=repairs,
            chunk_rows=19,
        )

        self.assertGreater(float(np.mean(before)), 0.1)
        self.assertLess(metrics["nrmse"], 5e-7)
        self.assertTrue(math.isfinite(metrics["max_absolute_error"]))

    def test_sentinel_recall_uses_oracle_only_for_evaluation(self) -> None:
        selected = np.array([1, 3, 5], dtype=np.int64)
        oracle_scores = np.array([0, 9, 1, 8, 2, 7, 6], dtype=np.float64)

        self.assertEqual(probe.sentinel_recall(selected, oracle_scores), 1.0)


if __name__ == "__main__":
    unittest.main()
