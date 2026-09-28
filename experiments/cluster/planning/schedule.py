"""Collapsed receive-credit fork / consumed-credit join, in integer nanoseconds.

These are conditional scenarios, not trace replay, confidence intervals, or
physical bounds. Shared-device contention is deliberately not predicted.
"""


def scenario(candidate, level, *, omit_overhead=False):
    frames = candidate["frames"]
    value = lambda frame, name: getattr(frame[name], level)
    overhead = lambda frame, name: 0 if omit_overhead else value(frame, name)
    total = 0 if omit_overhead else getattr(candidate["startup_ns"], level)
    timeline = []
    overlap = candidate["policy"] == "prompt_lookahead_one_v1"
    total += value(frames[0], "prepare_ns")
    for index, frame in enumerate(frames):
        if index and not overlap:
            total += value(frame, "prepare_ns")
        total += overhead(frame, "handoff_ns")
        fork = total
        consumer_end = fork + value(frame, "consume_ns")
        next_prepare_end = None
        if overlap and index + 1 < len(frames):
            next_prepare_end = fork + value(frames[index + 1], "prepare_ns")
        join = max(consumer_end, next_prepare_end or consumer_end)
        total = join + overhead(frame, "completion_ns")
        timeline.append({"frame": index, "fork_ns": fork, "consume_end_ns": consumer_end,
                         "next_prepare_end_ns": next_prepare_end,
                         "join_ns": join, "completed_ns": total})
    if not omit_overhead:
        total += getattr(candidate["return_token_ns"], level)
    return total, timeline


def missing_costs(candidate, *, compute_only=False):
    missing = []
    if not compute_only:
        for name in ("startup_ns", "return_token_ns"):
            if candidate[name] is None:
                missing.append(name)
    names = ("prepare_ns", "consume_ns") if compute_only else (
        "prepare_ns", "handoff_ns", "consume_ns", "completion_ns")
    for index, frame in enumerate(candidate["frames"]):
        for name in names:
            if frame[name] is None:
                missing.append(f"frames[{index}].{name}")
    return missing


def memory_issues(candidate):
    issues = []
    for index, (peak, budget) in enumerate(candidate["memory"]):
        if budget is None:
            issues.append(f"memory[{index}].budget_bytes unknown")
        if peak is None:
            issues.append(f"memory[{index}].peak_bytes unknown")
        elif budget is not None and peak.high > budget:
            issues.append(f"memory[{index}] high scenario exceeds supplied budget")
    return issues


def typical_breakdown(candidate):
    """Attribute the modeled path to consumer work and exposed producer work."""
    frames = candidate["frames"]
    prepare = [frame["prepare_ns"].typical for frame in frames]
    consume = [frame["consume_ns"].typical for frame in frames]
    exposed = sum(prepare)
    if candidate["policy"] == "prompt_lookahead_one_v1":
        exposed = prepare[0] + sum(max(0, following - current)
                                   for following, current in zip(prepare[1:], consume[:-1]))
    return {
        "startup": candidate["startup_ns"].typical,
        "exposed_prepare": exposed,
        "consume_including_final_selection": sum(consume),
        "handoff": sum(frame["handoff_ns"].typical for frame in frames),
        "completion": sum(frame["completion_ns"].typical for frame in frames),
        "return_token": candidate["return_token_ns"].typical,
    }


def evaluate_candidate(candidate, prompt_tokens):
    missing = missing_costs(candidate)
    memory = memory_issues(candidate)
    shared = candidate["resource_layout"] == "shared_device"
    result = {name: candidate[name] for name in ("id", "plan_sha256", "devices", "policy",
                                                "evidence_kind", "source_sha256")}
    result.update(missing_costs=missing, memory_issues=memory,
                  status="shared_device_not_modeled" if shared else
                  "missing_costs" if missing else "memory_screen_failed" if memory else "estimated",
                  ttft_ns=None, prefill_tps=None, typical_timeline=None,
                  typical_breakdown_ns=None, zero_overhead_scenario_ns=None)
    if shared:
        return result
    if not missing_costs(candidate, compute_only=True):
        result["zero_overhead_scenario_ns"] = {
            level: scenario(candidate, level, omit_overhead=True)[0]
            for level in ("low", "typical", "high")}
    if missing:
        return result
    times = {level: scenario(candidate, level)[0] for level in ("low", "typical", "high")}
    if times["low"] == 0:
        result["status"] = "nonpositive_modeled_time"
        return result
    result["ttft_ns"] = times
    result["typical_breakdown_ns"] = typical_breakdown(candidate)
    # TPS endpoints reverse duration order. Preserve exact integer times above.
    result["prefill_tps"] = {"low": prompt_tokens * 1e9 / times["high"],
                             "typical": prompt_tokens * 1e9 / times["typical"],
                             "high": prompt_tokens * 1e9 / times["low"]}
    result["typical_timeline"] = scenario(candidate, "typical")[1]
    return result
