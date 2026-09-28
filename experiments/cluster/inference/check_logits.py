#!/usr/bin/env python3
"""Compare teacher-forced logit matrices from two probe runs."""

import argparse
import json
import math
from pathlib import Path


def finite_positive(value):
    try:
        result = float(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("tolerances must be positive finite numbers") from error
    if not math.isfinite(result) or result <= 0:
        raise argparse.ArgumentTypeError("tolerances must be positive finite numbers")
    return result


def logit_matrix(path, parser):
    try:
        matrix = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        parser.error(f"cannot read logit matrix {path}: {error}")
    if not isinstance(matrix, list) or not matrix:
        parser.error("logit matrix must be a nonempty array of rows")
    for index, row in enumerate(matrix):
        if not isinstance(row, list) or not row:
            parser.error(f"logit row {index} must be a nonempty array")
        for value in row:
            try:
                valid = type(value) in (int, float) and math.isfinite(value)
            except OverflowError:
                valid = False
            if not valid:
                parser.error(f"logit row {index} must contain only finite numbers, not booleans")
    return matrix


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reference", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--max-relative-rms", type=finite_positive, required=True)
    parser.add_argument("--max-absolute", type=finite_positive, required=True)
    parser.add_argument("--require-greedy-agreement", action="store_true")
    args = parser.parse_args()
    reference = logit_matrix(args.reference, parser)
    candidate = logit_matrix(args.candidate, parser)
    if len(reference) != len(candidate):
        parser.error("logit row count mismatch or empty input")
    rows = []
    for index, (left, right) in enumerate(zip(reference, candidate, strict=True)):
        if not left or len(left) != len(right):
            parser.error(f"logit width mismatch or empty row {index}")
        try:
            differences = [a - b for a, b in zip(left, right, strict=True)]
            relative_rms = math.sqrt(
                math.fsum(x * x for x in differences)
                / max(math.fsum(x * x for x in left), 1e-30)
            )
            maximum = max(abs(x) for x in differences)
            finite = math.isfinite(relative_rms) and math.isfinite(maximum)
        except (OverflowError, ValueError):
            finite = False
        if not finite:
            parser.error(f"logit error calculation is outside the finite numeric range in row {index}")
        rows.append({
            "row": index,
            "relative_rms_error": relative_rms,
            "max_absolute_error": maximum,
            "argmax_equal": max(range(len(left)), key=left.__getitem__)
            == max(range(len(right)), key=right.__getitem__),
            "passed": relative_rms <= args.max_relative_rms
            and maximum <= args.max_absolute,
        })
    numeric_passed = all(row["passed"] for row in rows)
    greedy_equal = all(row["argmax_equal"] for row in rows)
    passed = numeric_passed and (greedy_equal or not args.require_greedy_agreement)
    print(json.dumps({
        "passed": passed, "numeric_parity_passed": numeric_passed,
        "greedy_tokens_equal": greedy_equal,
        "requested_tolerances": {"max_relative_rms": args.max_relative_rms,
                                 "max_absolute": args.max_absolute},
        "greedy_agreement_required": args.require_greedy_agreement, "rows": rows,
    }, sort_keys=True, allow_nan=False))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
