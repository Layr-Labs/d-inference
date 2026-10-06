"""Assemble isolated deadline cells from intact supervised numeric receipts."""
import hashlib
import json

from .live_receipts import summarize
from .build_identity import verified_build_identity
from .posture import COOLED_DEADLINE_APPLICABILITY, automatic_ac_run, nominal_trial, valid_cooldown
from .matrix import positive


def _only_digest(values, label):
    digests = set(values.values())
    if len(digests) != 1:
        raise ValueError(f"one exact {label} digest required")
    return next(iter(digests))


def assemble_deadline_receipt(runs, *, profile_id, prompt_min, prompt_max, checks):
    """Each (raw_report, raw_provenance) pair is preserved verbatim by callers.

    Bounds are declared before collection. Training alone selects phase rates;
    validation retains all observations. This first collector certifies only
    isolated cold work, without guessing a contended scheduler's work ahead.
    """
    identity, build, contract = None, None, None
    samples, prefill_rates, decode_rates = [], [], []
    for raw, raw_provenance in runs:
        report, provenance = json.loads(raw), json.loads(raw_provenance)
        if (not report.get("complete") or provenance.get("return_code") != 0 or
                not all(provenance.get(key) is True for key in
                        ("artifact_unchanged", "source_unchanged", "binary_unchanged"))):
            raise ValueError("incomplete, failed or changed run cannot certify a deadline")
        if not automatic_ac_run(provenance):
            raise ValueError("Automatic stable AC power is required by this deadline-policy revision")
        job = report["job"]
        if job["width"] != 1 or job["reused"] or not job.get("servingPolicy"):
            raise ValueError("this collector only certifies isolated cold ordinary serving configuration")
        if job["partition"] not in ("calibration", "validation"):
            raise ValueError("screening baselines are not calibration observations")
        runtime = report.get("deadlineRuntimeConfiguration")
        if not isinstance(runtime, dict):
            raise ValueError("actual factory scheduler readback is required")
        current_identity = {"id": profile_id, "model_id": job["modelID"], "artifact_sha256": job["artifactSHA256"],
            "provider_version": report["providerVersion"], "runtime_revision": report["runtimeRevision"],
            "kv_backend": report["actualKVBackend"], "chip_name": report["chipName"], "gpu_cores": report["gpuCores"],
            "memory_gb": report["memoryBytes"] // 1024**3, **runtime}
        if report.get("mtp") is not None:
            current_identity["mtp"] = report["mtp"]
        actual_build = verified_build_identity(report, provenance)
        source = provenance["source"]
        current_build = {"configuration": provenance["build_configuration"], "dirty": source.get("dirty", True),
            "debug_condition": actual_build["debugCompilationCondition"],
            "debug_assertions_enabled": actual_build["debugAssertionsEnabled"],
            "build_identity_version": actual_build["version"], "source_commit": source["head"],
            "sdk_commit": source["dependency_head"], "source_tree_sha256": source["source_tree_sha256"],
            "test_binary_sha256": actual_build["binarySHA256"],
            "metallib_sha256": _only_digest(provenance["metallibs_sha256"], "metallib")}
        if identity is not None and (identity != current_identity or build != current_build or contract != report["promptContractID"]):
            raise ValueError("all calibration/heldout runs must use the same exact artifact/runtime/build/template")
        identity, build, contract = current_identity, current_build, report["promptContractID"]
        preparation = report.get("preparationCooldowns")
        if not isinstance(preparation, list) or len(preparation) != 1 or not valid_cooldown(preparation[0]):
            raise ValueError("warmup requires observed AC/nominal preparation before measured rates")
        cooldowns = report.get("cooldowns", [])
        if len(cooldowns) != len(report["trials"]) or not all(valid_cooldown(c) for c in cooldowns):
            raise ValueError("every measured trial requires the predeclared cooldown and stable nominal recovery")
        summary = summarize(report)
        for trial, measured in zip(report["trials"], summary["cells"]):
            if trial.get("lowPowerMode") is not False:
                raise ValueError("each measured trial must explicitly exclude Low Power mode")
            if measured["failures"]:
                raise ValueError(f"failed observation remains ineligible: {measured['failures']}")
            if not nominal_trial(trial):
                raise ValueError("any observed nonnominal or low-power transition invalidates the cohort")
            row = trial["rows"][0]
            profile, timing = row["profile"], row["profile"]["engine"]
            if profile.get("running_at_admit", 0) or profile.get("waiting_at_admit", 0) or row.get("cachedTokens", 0):
                raise ValueError("isolated cold receipt contains existing or reused work")
            duration = timing["prompt_computed_ns"] - timing["prefill_first_launch_ns"]
            rate = row["promptTokens"] * 1e9 / duration if duration > 0 else 0
            decode = measured["engine_decode_p10_tps"]
            if not positive(rate) or not positive(decode):
                raise ValueError("actual engine phase rates are required")
            if job["partition"] == "calibration":
                prefill_rates.append(rate)
                decode_rates.append(decode)
            samples.append({"partition": job["partition"],
                "run_id": f"{job['runID']}/{trial['iteration']}", "request_id": row["requestID"],
                "raw_receipt_sha256": hashlib.sha256(raw).hexdigest(), "workload_sha256": row["workloadSHA256"],
                "prompt_tokens": row["promptTokens"],
                "context_tokens": row["promptTokens"] + min(33, row["requestedOutputTokens"]),
                "requested_output_tokens": row["requestedOutputTokens"],
                "cache_state": "cold", "contention": "isolated", "prefill_work_tokens": row["promptTokens"],
                "decode_work_tokens": min(33, row["requestedOutputTokens"]), "active_requests": 1,
                "competitor_profile_ids": [], "other_model_requests": 0, "other_model_service_fraction": 0,
                "tool_history": job["toolHistory"], "observed_first_content_ms": row["firstContentMs"],
                "engine_decode_tps": decode, "thermal_state": "nominal" if trial["thermalState"] == 0 else "non_nominal",
                "power_mode": "automatic", "retired": trial["retired"], "mtp": report.get("mtp")})
    if not samples or not prefill_rates or not decode_rates:
        raise ValueError("both phases need independent training evidence")
    outputs = {sample["requested_output_tokens"] for sample in samples}
    if len(outputs) != 1:
        raise ValueError("declare one output allowance for this initial isolated calibration cohort")
    output = next(iter(outputs))
    cell = {"prompt_tokens_min": prompt_min, "prompt_tokens_max": prompt_max,
        "context_tokens_min": prompt_min + min(33, output), "context_tokens_max": prompt_max + min(33, output),
        "cache_state": "cold", "contention": "isolated", "prefill_tps": min(prefill_rates), "decode_tps": min(decode_rates),
        "max_prefill_work_tokens": prompt_max, "max_decode_work_tokens": min(33, output), "max_active_requests": 1,
        "competitor_profile_ids": [], "max_other_model_requests": 0, "max_other_model_service_fraction": 0,
        "samples": samples}
    return {"schema_version": 1, "kind": "deadline_only", "identity": identity, "build": build, "checks": checks,
        "applicability": dict(COOLED_DEADLINE_APPLICABILITY),
        "deadline_calibration": {"version": 1, "prompt_contract_id": contract, "cells": [cell]}}
