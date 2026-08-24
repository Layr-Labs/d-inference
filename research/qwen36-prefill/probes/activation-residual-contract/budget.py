#!/usr/bin/env python3
"""Arithmetic accounting for activation-subspace contraction probes."""

from __future__ import annotations

import math
from dataclasses import dataclass


NATIVE_LINEAR_GFLOP_PER_TOKEN = 4.8734208
NATIVE_ROUTED_TOP8_GFLOP_PER_TOKEN = 2.01326592
TOPK4_LINEAR_GFLOP_PER_TOKEN = (
    NATIVE_LINEAR_GFLOP_PER_TOKEN - NATIVE_ROUTED_TOP8_GFLOP_PER_TOKEN / 2
)
GDN_SCAN_GFLOP_PER_TOKEN = 0.11010048
ATTENTION_8K_GFLOP_PER_TOKEN = 0.6712
NATIVE_8K_GFLOP_PER_TOKEN = (
    NATIVE_LINEAR_GFLOP_PER_TOKEN
    + GDN_SCAN_GFLOP_PER_TOKEN
    + ATTENTION_8K_GFLOP_PER_TOKEN
)
MEASURED_TOPK4_B4_8K_SPEEDUP = 1.192
TARGET_NATIVE_SPEEDUP = 2.5


def _positive(name: str, value: int) -> int:
    if value <= 0:
        raise ValueError(f"{name} must be positive")
    return value


@dataclass(frozen=True)
class ContractionBudget:
    """MAC-equivalent cost of one contracted projection."""

    baseline_macs: int
    candidate_macs: int
    components: dict[str, int]

    @property
    def candidate_fraction(self) -> float:
        return self.candidate_macs / self.baseline_macs

    @property
    def contraction_speedup(self) -> float:
        return self.baseline_macs / self.candidate_macs

    def as_dict(self) -> dict[str, object]:
        return {
            "baseline_macs": self.baseline_macs,
            "candidate_macs": self.candidate_macs,
            "candidate_fraction": self.candidate_fraction,
            "contraction_speedup": self.contraction_speedup,
            "components": self.components,
        }


def dense_budget(
    *,
    rows: int,
    input_width: int,
    output_width: int,
    rank: int,
    sentinel_columns: int,
    repair_rows: int,
    power_iterations: int = 0,
) -> ContractionBudget:
    """Account for ``X @ W`` with a runtime token-axis basis.

    QR is charged conservatively as ``2 * rows * rank**2`` MAC-equivalents per
    range-finder pass. The accounting includes reconstructing repaired input
    rows before applying their exact residual through the original weight.
    """

    rows = _positive("rows", rows)
    input_width = _positive("input_width", input_width)
    output_width = _positive("output_width", output_width)
    rank = _positive("rank", rank)
    if rank > min(rows, input_width):
        raise ValueError("rank exceeds the activation matrix dimensions")
    if not 0 <= sentinel_columns <= output_width:
        raise ValueError("sentinel_columns must be within the output width")
    if not 0 <= repair_rows <= rows:
        raise ValueError("repair_rows must be within the row count")
    if power_iterations < 0:
        raise ValueError("power_iterations cannot be negative")

    components = {
        "range_projection": rows * input_width * rank,
        "power_iterations": 2 * power_iterations * rows * input_width * rank,
        "basis_coefficients": rows * input_width * rank,
        "basis_weight_projection": rank * input_width * output_width,
        "output_reconstruction": rows * rank * output_width,
        "sentinel_projection": rows * input_width * sentinel_columns,
        "repair_input_reconstruction": repair_rows * rank * input_width,
        "repair_weight_projection": repair_rows * input_width * output_width,
        "qr_equivalent": 2 * (power_iterations + 1) * rows * rank * rank,
    }
    baseline = rows * input_width * output_width
    return ContractionBudget(
        baseline_macs=baseline,
        candidate_macs=sum(components.values()),
        components=components,
    )


def expert_budget(
    *,
    assignments: int,
    experts: int,
    input_width: int,
    output_width: int,
    rank: int,
    sentinel_columns: int,
    repair_assignments: int,
    power_iterations: int = 0,
) -> ContractionBudget:
    """Account for one global assignment basis across immutable expert weights.

    Each basis row is projected through every expert. Reconstruction gathers the
    basis output for the routed expert of each assignment. Repair assignments
    apply their exact residual through that same expert's original weight.
    """

    assignments = _positive("assignments", assignments)
    experts = _positive("experts", experts)
    input_width = _positive("input_width", input_width)
    output_width = _positive("output_width", output_width)
    rank = _positive("rank", rank)
    if rank > min(assignments, input_width):
        raise ValueError("rank exceeds the assignment matrix dimensions")
    if not 0 <= sentinel_columns <= output_width:
        raise ValueError("sentinel_columns must be within the output width")
    if not 0 <= repair_assignments <= assignments:
        raise ValueError("repair_assignments must be within the assignment count")
    if power_iterations < 0:
        raise ValueError("power_iterations cannot be negative")

    components = {
        "range_projection": assignments * input_width * rank,
        "power_iterations": (
            2 * power_iterations * assignments * input_width * rank
        ),
        "basis_coefficients": assignments * input_width * rank,
        "all_expert_basis_projection": (
            experts * rank * input_width * output_width
        ),
        "routed_output_reconstruction": assignments * rank * output_width,
        "sentinel_projection": assignments * input_width * sentinel_columns,
        "repair_input_reconstruction": (
            repair_assignments * rank * input_width
        ),
        "repair_weight_projection": (
            repair_assignments * input_width * output_width
        ),
        "qr_equivalent": (
            2 * (power_iterations + 1) * assignments * rank * rank
        ),
    }
    baseline = assignments * input_width * output_width
    return ContractionBudget(
        baseline_macs=baseline,
        candidate_macs=sum(components.values()),
        components=components,
    )


@dataclass(frozen=True)
class CompositionBudget:
    """Measured-top-k4 wall model for the binding B=4 x 8K cell."""

    effective_linear_fraction: float
    algorithm_overhead_native_fraction: float
    candidate_native_fraction: float
    native_speedup: float
    maximum_linear_fraction: float

    @property
    def passes_target(self) -> bool:
        return self.native_speedup >= TARGET_NATIVE_SPEEDUP

    def as_dict(self) -> dict[str, object]:
        return {
            "effective_linear_fraction": self.effective_linear_fraction,
            "algorithm_overhead_native_fraction": (
                self.algorithm_overhead_native_fraction
            ),
            "candidate_native_fraction": self.candidate_native_fraction,
            "native_speedup": self.native_speedup,
            "maximum_linear_fraction": self.maximum_linear_fraction,
            "minimum_linear_contraction": 1 / self.maximum_linear_fraction,
            "target_native_speedup": TARGET_NATIVE_SPEEDUP,
            "passes_target": self.passes_target,
        }


def b4_8k_composition(
    effective_linear_fraction: float,
    *,
    algorithm_overhead_native_fraction: float = 0,
) -> CompositionBudget:
    """Compose a linear contraction with the measured 1.192x top-k4 arm.

    The fixed wall fraction is the measured top-k4 wall fraction less top-k4's
    modeled linear work. It deliberately retains all unexplained overhead.
    """

    if effective_linear_fraction < 0:
        raise ValueError("effective_linear_fraction cannot be negative")
    if algorithm_overhead_native_fraction < 0:
        raise ValueError("algorithm overhead cannot be negative")

    topk4_wall_fraction = 1 / MEASURED_TOPK4_B4_8K_SPEEDUP
    topk4_linear_native_fraction = (
        TOPK4_LINEAR_GFLOP_PER_TOKEN / NATIVE_8K_GFLOP_PER_TOKEN
    )
    fixed_wall_fraction = topk4_wall_fraction - topk4_linear_native_fraction
    target_fraction = 1 / TARGET_NATIVE_SPEEDUP
    maximum_linear_fraction = (
        target_fraction
        - fixed_wall_fraction
        - algorithm_overhead_native_fraction
    ) / topk4_linear_native_fraction
    candidate_fraction = (
        fixed_wall_fraction
        + topk4_linear_native_fraction * effective_linear_fraction
        + algorithm_overhead_native_fraction
    )
    speedup = math.inf if candidate_fraction == 0 else 1 / candidate_fraction
    return CompositionBudget(
        effective_linear_fraction=effective_linear_fraction,
        algorithm_overhead_native_fraction=algorithm_overhead_native_fraction,
        candidate_native_fraction=candidate_fraction,
        native_speedup=speedup,
        maximum_linear_fraction=maximum_linear_fraction,
    )
