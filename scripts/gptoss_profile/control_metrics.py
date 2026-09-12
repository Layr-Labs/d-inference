"""Latency and resource metrics for raw-token ABBA controls."""

from statistics import mean, median

from .summary import dispersion


METRIC_DIRECTIONS = {"aggregateDecodeTPS": "higher_is_better", "ttftMedianMs": "lower_is_better",
                     "endToEndMedianMs": "lower_is_better", "batchEndToEndMs": "lower_is_better",
                     "peakMemoryBytes": "lower_is_better"}
PREFILL_METRIC_DIRECTIONS = {"ttftMedianMs": "lower_is_better", "promptTokensPerSecond": "higher_is_better",
                            "peakMemoryBytes": "lower_is_better"}


def metric_directions(phase):
    return PREFILL_METRIC_DIRECTIONS if phase == "prefill" else METRIC_DIRECTIONS


def row_latencies(rows):
    rows = sorted(rows, key=lambda row: row["row"])
    if any(row["tokenArrivalMs"][0] < row["submittedAtMs"] or row["finishedAtMs"] < row["tokenArrivalMs"][-1] for row in rows):
        raise ValueError("Token/finish timestamps precede their request boundaries")
    ttfts = [row["tokenArrivalMs"][0] - row["submittedAtMs"] for row in rows]
    end_to_end = [row["finishedAtMs"] - row["submittedAtMs"] for row in rows]
    return {"rowTTFTMs": ttfts, "rowEndToEndMs": end_to_end,
            "ttftMedianMs": median(ttfts), "endToEndMedianMs": median(end_to_end),
            "batchEndToEndMs": max(row["finishedAtMs"] for row in rows) - min(row["submittedAtMs"] for row in rows)}


def distributions(observations):
    if observations[0]["phase"] == "prefill":
        return {name: dispersion([row[name] for row in observations]) for name in PREFILL_METRIC_DIRECTIONS}
    result = {name: dispersion([row[name] for row in observations])
              for name in (*METRIC_DIRECTIONS, "fairShareDecodeTPS", "endToEndTPS")}
    result.update({name: dispersion([value for row in observations for value in row[name]])
                   for name in ("rowTTFTMs", "rowEndToEndMs")})
    return result


def compare_cycle(observations):
    selected = {arm: [row for row in observations if row["arm"] == arm] for arm in ("A", "B")}
    metrics = {}
    prefill = observations[0]["phase"] == "prefill"
    for name, direction in metric_directions(observations[0]["phase"]).items():
        a, b = [mean(row[name] for row in selected[arm]) for arm in ("A", "B")]
        ratio = b / a if a else None
        change = (ratio - 1) * 100 if ratio is not None else None
        metrics[name] = {"meanA": a, "meanB": b, "ratioBOverA": ratio, "changePercent": change,
                         "direction": direction,
                         "improvementPercent": change if direction == "higher_is_better" else -change if change is not None else None}
    primary = metrics["ttftMedianMs" if prefill else "aggregateDecodeTPS"]
    return {"cycle": observations[0]["cycle"],
            ("meanTTFTMsA" if prefill else "meanAggregateA"): primary["meanA"],
            ("meanTTFTMsB" if prefill else "meanAggregateB"): primary["meanB"],
            "ratioBOverA": primary["ratioBOverA"],
            "changePercent": primary["changePercent"], "metrics": metrics,
            "distributionsByArm": {arm: distributions(selected[arm]) for arm in ("A", "B")}}
