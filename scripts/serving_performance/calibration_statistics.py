"""Deterministic upper-bound fitting and held-out coverage statistics."""
import math


def fit_upper_bound(points, minimum_ratio=1.0):
    """Minimize mean training bound subject to covering every training point.

    The convex objective is piecewise linear. Its minimum occurs at ratio=1,
    a residual/zero intersection, or a pairwise residual intersection. No
    validation observation enters the fit and no arbitrary margin is added.
    """
    # Upper envelope of residual lines y-r*x (plus zero), sorted by slope.
    # This avoids an O(n²) candidate set for large qualification receipts.
    lines = {0.0: 0.0}
    for x, y in points:
        lines[-x] = max(lines.get(-x, -math.inf), y)
    hull = []
    for slope, intercept in sorted(lines.items()):
        start = -math.inf
        while hull:
            previous_slope, previous_intercept, previous_start = hull[-1]
            start = (previous_intercept - intercept) / (slope - previous_slope)
            if start > previous_start:
                break
            hull.pop()
        hull.append((slope, intercept, start if hull else -math.inf))
    mean_x = math.fsum(x for x, _ in points) / len(points)
    initial_additive = max(0.0, max(y - minimum_ratio * x for x, y in points))
    fitted = [(minimum_ratio * mean_x + initial_additive, minimum_ratio, initial_additive)]
    for slope, intercept, ratio in hull:
        if math.isfinite(ratio) and ratio >= minimum_ratio:
            additive = max(0.0, slope * ratio + intercept)
            fitted.append((ratio * mean_x + additive, ratio, additive))
    _, ratio, _ = min(fitted)
    additive = max(0.0, max(y - ratio * x for x, y in points))
    # Round outward so serialization cannot turn a training boundary inward.
    return math.nextafter(ratio, math.inf), math.nextafter(additive, math.inf) if additive else 0.0


def percentile(values, quantile):
    """Nearest-rank percentile; tails are never interpolated downward."""
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * quantile) - 1)]


def coverage_lower_bound(covered, total, confidence=.95):
    """Exact one-sided Clopper-Pearson lower bound, no scipy dependency."""
    if covered == 0:
        return 0.0
    # P_p(X >= covered)=1-confidence, monotone in p. Log-space summation
    # keeps the binomial tail stable even with hundreds of observations.
    def tail(p):
        if p <= 0:
            return 0.0
        if p >= 1:
            return 1.0
        terms = [math.lgamma(total + 1) - math.lgamma(k + 1)
                 - math.lgamma(total - k + 1) + k * math.log(p)
                 + (total - k) * math.log1p(-p) for k in range(covered, total + 1)]
        largest = max(terms)
        return math.exp(largest) * math.fsum(math.exp(term - largest) for term in terms)
    lo, hi = 0.0, 1.0
    for _ in range(70):
        mid = (lo + hi) / 2
        if tail(mid) < 1 - confidence:
            lo = mid
        else:
            hi = mid
    return lo
