"""Explicitly fabricated cost inputs for CPU tests and the documented example."""


def cost(typical, low=None, high=None):
    return {"low": typical if low is None else low, "typical": typical,
            "high": typical if high is None else high}


def candidate(identifier="cut-4-lookahead", prepare=(10, 10, 10), consume=(10, 10, 10),
              handoff=0, completion=0, policy="prompt_lookahead_one_v1"):
    return {
        "id": identifier, "plan_sha256": "1" * 64,
        "devices": ["fabricated-device-a", "fabricated-device-b"],
        "resource_layout": "independent_devices", "policy": policy,
        "evidence_kind": "assumed", "source_sha256": ["2" * 64],
        "memory": [{"peak_bytes": cost(10), "budget_bytes": 100} for _ in range(2)],
        "startup_ns": cost(0), "return_token_ns": cost(0),
        "frames": [{"prepare_ns": cost(p), "consume_ns": cost(c),
                    "handoff_ns": cost(handoff), "completion_ns": cost(completion)}
                   for p, c in zip(prepare, consume)],
    }


def profile(*candidates):
    return {
        "schema": "cluster_prefill_costs_v1",
        "workload": {"artifact_sha256": "3" * 64, "tokens_sha256": "4" * 64,
                     "arithmetic": "fabricated-bf16", "prompt_tokens": 12,
                     "chunk_tokens": 4, "batch_size": 1, "cache_mode": "uncached"},
        "baseline": {"id": "solo", "device": "fabricated-device-a", "ttft_ns": cost(60),
                     "evidence_kind": "assumed", "source_sha256": ["5" * 64]},
        "candidates": list(candidates) or [candidate()],
    }


if __name__ == "__main__":
    import json
    print(json.dumps(profile(candidate(), candidate("cut-4-serial", policy="serial_v1")), indent=2))
