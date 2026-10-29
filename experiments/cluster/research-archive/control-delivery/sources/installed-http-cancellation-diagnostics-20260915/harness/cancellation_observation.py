"""Observe autonomous process/journal cleanup before any harness fallback stop."""

import math
import time


def system_monotonic():
    """An OS clock with the same epoch in the client and parent processes."""
    return time.clock_gettime_ns(time.CLOCK_MONOTONIC) / 1e9


def observe_after_close(close_origin, seconds, collect, interrupted, clock=system_monotonic,
                        sleep=time.sleep):
    now = clock()
    if (not math.isfinite(close_origin) or close_origin > now or now - close_origin > 5
            or not math.isfinite(seconds) or not 1 <= seconds <= 60):
        raise ValueError("Invalid client-close observation origin/budget")
    deadline = close_origin + seconds
    record = dict(schema="http_disconnect_self_retirement_observation_v1",
                  seconds=seconds, samples=[], self_retirement_observed=False,
                  harness_interference_observed=False, native_retirement_ack_verified=False,
                  cause_independently_verified=False)
    while clock() < deadline:
        if interrupted():
            record["harness_interference_observed"] = True
            break
        sample = dict(start_after_client_close_seconds=clock() - close_origin, nodes=[])
        try:
            for rank in range(2):
                remaining = deadline - clock()
                if remaining <= 0:
                    raise TimeoutError("Self-retirement observation deadline")
                value = collect(rank, min(15, remaining))
                active, size = value.get("active"), value.get("journalBytes")
                if (type(active) is not list or len(active) > 64
                        or any(type(line) is not str or len(line) > 4096 for line in active)
                        or type(size) is not int or not 0 <= size <= 65536):
                    raise ValueError("Invalid process/journal observation")
                sample["nodes"].append(value)
        except Exception as error:
            # A missing/failed observation cannot establish absence or clear a
            # journal. Record fixed error type only; remote stderr is separate.
            sample["error_type"] = type(error).__name__
        sample["end_after_client_close_seconds"] = clock() - close_origin
        record["samples"].append(sample)
        if interrupted():
            record["harness_interference_observed"] = True
            break
        if (clock() <= deadline and "error_type" not in sample and len(sample["nodes"]) == 2
                and all(not node["active"] and node["journalBytes"] == 0 for node in sample["nodes"])):
            record["self_retirement_observed"] = True
            break
        sleep(min(1, max(0, deadline - clock())))
    record["elapsed_after_client_close_seconds"] = clock() - close_origin
    return record
