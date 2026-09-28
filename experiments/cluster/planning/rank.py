"""Rank conditional prefill scenarios without admitting any execution plan."""

from .costs import read_profile
from .schedule import evaluate_candidate


def analyze(document):
    profile = read_profile(document)
    workload = profile["workload"]
    results = [evaluate_candidate(candidate, workload["prompt_tokens"])
               for candidate in profile["candidates"]]
    ranked = sorted((item for item in results if item["status"] == "estimated"),
                    key=lambda item: (item["ttft_ns"]["typical"], item["id"]))
    baseline = profile["baseline"]
    baseline_cost = baseline["ttft_ns"] if baseline else None
    for item in results:
        item["baseline_comparison"] = None
        if item["ttft_ns"] and baseline_cost and baseline["device"] in item["devices"]:
            cost = item["ttft_ns"]
            item["baseline_comparison"] = {
                "id": baseline["id"], "evidence_kind": baseline["evidence_kind"],
                "source_sha256": baseline["source_sha256"],
                "typical_speedup": baseline_cost.typical / cost["typical"],
                "faster_across_supplied_ranges": cost["high"] < baseline_cost.low,
                "slower_across_supplied_ranges": cost["low"] > baseline_cost.high,
            }
    # A global winner requires comparable physical resources; different device
    # pairs remain separate experiments, even if each has complete cost data.
    groups = {}
    for item in ranked:
        key = tuple(sorted(item["devices"]))
        groups.setdefault(key, []).append(item)
    comparisons = []
    for devices, items in sorted(groups.items()):
        options = [(item["id"], "candidate", item["ttft_ns"]) for item in items]
        if baseline_cost and baseline["device"] in devices:
            options.append((baseline["id"], "baseline", vars(baseline_cost)))
        options.sort(key=lambda option: (option[2]["typical"], option[1], option[0]))
        winner = None
        if len(options) > 1:
            for index, option in enumerate(options):
                if all(option[2]["high"] < other[2]["low"]
                       for other_index, other in enumerate(options) if index != other_index):
                    winner = {"id": option[0], "kind": option[1]}
        comparisons.append({"devices": list(devices),
                            "typical_ranking": [{"id": item[0], "kind": item[1]} for item in options],
                            "winner_across_supplied_ranges": winner})
    return {
        "schema": "cluster_prefill_cost_analysis_v1", "workload": workload,
        "model": "collapsed_receive_credit_fork_consumed_credit_join_v1",
        "execution_admission": False, "physical_measurement_verified": False,
        "performance_qualification": False,
        "assumptions": [
            "Caller supplies source identities, common workload and complete cost boundaries; references are not audited.",
            "Device identity and independent service under concurrent work are caller assumptions.",
            "Low/typical/high are supplied scenarios, not statistical confidence intervals or physical bounds.",
            "Handoff precedes the receive-credit fork; completion follows the consumed-credit join.",
            "Final consume includes the vocabulary projection and first-token selection.",
            "Startup and token-return costs cover the remainder of prepared-input-to-first-token time.",
            "Memory screens use supplied per-device budgets and high scenarios, not runtime admission.",
        ],
        "candidates": results, "comparisons": comparisons,
    }
