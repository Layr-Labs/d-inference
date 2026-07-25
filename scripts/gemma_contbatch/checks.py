"""Shared fail-closed primitives used by the raw-payload validators.

Every helper raises `RuntimeError` with the JSON path that failed, so a bad
payload names the field that broke instead of surfacing later as a confusing
summary number.
"""

from __future__ import annotations

import math


def is_number(value: object) -> bool:
    """True for real JSON numbers. `bool` is a subclass of `int`, so exclude it."""
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def assert_finite(value: object, path: str = "root") -> None:
    if isinstance(value, float) and not math.isfinite(value):
        raise RuntimeError(f"non-finite metric at {path}: {value}")
    if isinstance(value, dict):
        for key, child in value.items():
            assert_finite(child, f"{path}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            assert_finite(child, f"{path}[{index}]")


def require_positive(value: object, path: str) -> None:
    if not is_number(value) or value <= 0:
        raise RuntimeError(f"expected positive metric at {path}, got {value!r}")


def require_finite(value: object, path: str) -> float:
    """A finite number, returned as a float for arithmetic."""
    if not is_number(value) or not math.isfinite(float(value)):
        raise RuntimeError(f"expected a finite number at {path}, got {value!r}")
    return float(value)


def require_non_negative(value: object, path: str) -> float:
    number = require_finite(value, path)
    if number < 0:
        raise RuntimeError(f"expected a non-negative number at {path}, got {value!r}")
    return number


def require_bool(value: object, path: str) -> bool:
    if not isinstance(value, bool):
        raise RuntimeError(f"expected a boolean at {path}, got {value!r}")
    return value


def require_non_negative_int(value: object, path: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        raise RuntimeError(f"expected a non-negative integer at {path}, got {value!r}")
    return value


def close_enough(left: float, right: float) -> bool:
    """The tolerance the module uses when recomputing a reported aggregate."""
    return math.isclose(left, right, rel_tol=1e-9, abs_tol=1e-6)
