"""Validate fresh launch-bound reports, opaque parity, coverage and MTP work."""
from __future__ import annotations

from datetime import datetime, timezone
import json
import math
from typing import Any

from .constants import REPORT_NAME, MAX_REPORT_BYTES, REPORT_SCHEMA_VERSION, PERFORMANCE_KEYS, HEX_DIGITS
from .run_directory import SecureRunDirectory
from .metrics import expected_mtp_expectation, validate_case_metrics

def parse_timestamp(value: Any, field: str) -> datetime:
    if not isinstance(value, str):
        raise ValueError(f"{field} must be an ISO-8601 string")
    normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
    parsed = datetime.fromisoformat(normalized)
    if parsed.tzinfo is None:
        raise ValueError(f"{field} must include a timezone")
    return parsed.astimezone(timezone.utc)


def recursively_present_keys(value: Any, wanted: set[str]) -> set[str]:
    found: set[str] = set()
    if isinstance(value, dict):
        for key, child in value.items():
            if key in wanted:
                found.add(key)
            found.update(recursively_present_keys(child, wanted))
    elif isinstance(value, list):
        for child in value:
            found.update(recursively_present_keys(child, wanted))
    return found


def effective_quantization_bits(artifact: dict[str, Any]) -> int | None:
    quantization = artifact.get("quantization")
    if not isinstance(quantization, dict):
        return None
    bits = quantization.get("bits")
    if isinstance(bits, int) and not isinstance(bits, bool):
        return bits
    overrides = quantization.get("perLayerOverridesByBits", {})
    if not isinstance(overrides, dict):
        return None
    values = {
        int(key)
        for key, count in overrides.items()
        if isinstance(key, str)
        and key.isdigit()
        and isinstance(count, int)
        and count > 0
    }
    return next(iter(values)) if len(values) == 1 else None


def expected_coverage(report: dict[str, Any]) -> dict[str, str]:
    target = report.get("target", {})
    assistant = report.get("assistant", {})
    target_name = str(target.get("modelID", "")).lower()
    assistant_name = str(assistant.get("modelID", "")).lower()
    qat4 = (
        "qat" in target_name
        and "qat" in assistant_name
        and effective_quantization_bits(target) == 4
        and effective_quantization_bits(assistant) == 4
    )
    # Both official Gemma 4 target config types count: multimodal checkpoints
    # report "gemma4" and text-only checkpoints report "gemma4_text" (mirrors
    # MTPBenchmarkCoverage.shortContextMatrix).
    eight_bit_target = (
        target.get("modelType") in ("gemma4", "gemma4_text")
        and effective_quantization_bits(target) == 8
    )
    assistant_dtype = str(assistant.get("dtype", "")).lower().replace("_", "").replace("-", "")
    bf16_assistant = (
        assistant.get("modelType") == "gemma4_assistant"
        and assistant_dtype in {"bfloat16", "bf16"}
        and assistant.get("quantization") is None
    )
    return {
        "qat4BitShortContextSmoke": "covered" if qat4 else "not_run",
        "eightBitTargetPairing": "covered" if eight_bit_target else "not_run",
        "bf16AssistantPairing": "covered" if bf16_assistant else "not_run",
        "officialTensorFixtures": "not_implemented",
        # The short cached-model matrix never exercises tool templates or
        # image prefill; a report claiming either as covered must fail.
        "toolTemplateDecodeParity": "not_in_this_report",
        "structuredOutput": "not_implemented",
        "imagePrefill": "not_in_this_report",
        "videoPrefill": "not_implemented",
        "longSlidingAndPrefixContexts": "not_implemented",
        "opaqueTokenEvidence": "covered",
        "productionServingStopPolicy": (
            "not_in_this_report"
            if report.get("purpose") == "raw_parity_stress"
            else "covered"
        ),
        "artifactProvenanceAndDrift": "covered",
        "conservativeAssistantSizing": "covered",
    }


def validate_report_artifact(
    report_artifact: Any,
    expected: dict[str, Any],
    label: str,
) -> None:
    if not isinstance(report_artifact, dict):
        raise ValueError(f"report {label} artifact is not an object")
    for key in (
        "modelID",
        "resolvedPath",
        "revision",
        "configSizeBytes",
        "configSHA256",
        "weightFiles",
        "artifactFingerprint",
    ):
        if report_artifact.get(key) != expected[key]:
            raise ValueError(f"report {label} {key} does not match launch provenance")
    # Anchor the coverage-relevant metadata to the launch-side parse of the
    # SAME hashed config bytes: a regressed Swift inspector must not be able
    # to claim false QAT/8-bit/BF16 coverage while fingerprints still match.
    metadata = expected.get("configMetadata") or {}
    if report_artifact.get("modelType") != metadata.get("model_type"):
        raise ValueError(f"report {label} modelType does not match launch config.json")
    # Strict TWO-WAY equality: a report may neither invent a dtype the hashed
    # config lacks nor drop/alter one it has — BF16 coverage keys on this.
    if report_artifact.get("dtype") != metadata.get("dtype"):
        raise ValueError(f"report {label} dtype does not match launch config.json")
    if bool(metadata.get("has_quantization")) != (report_artifact.get("quantization") is not None):
        raise ValueError(f"report {label} quantization presence does not match launch config.json")
    # Compare the EFFECTIVE bits the coverage gate consumes (top-level or
    # unique per-layer override), so override-only configs are anchored too.
    if effective_quantization_bits(report_artifact) != metadata.get("effective_quantization_bits"):
        raise ValueError(f"report {label} quantization bits do not match launch config.json")


def nonnegative_finite_number(value: Any) -> bool:
    # Zero is valid for one-token/zero-interval samples. Booleans are JSON
    # control values, even though Python treats them as integers.
    return (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and value >= 0
        and (not isinstance(value, float) or math.isfinite(value))
    )


def validate_report(
    run: SecureRunDirectory,
    *,
    fingerprint: str,
    launch_time: float,
    mode: str,
    build_configuration: str,
    target: dict[str, Any],
    assistant: dict[str, Any],
    max_tokens: int,
    warmup: int,
    repetitions: int,
    seed: int,
    expect_mtp_inactive: bool,
) -> None:
    encoded, metadata = run.read_regular(REPORT_NAME, MAX_REPORT_BYTES)
    if metadata.st_mtime < launch_time - 1:
        raise ValueError("report mtime predates this launch")
    report = json.loads(encoded.decode("utf-8"))
    if not isinstance(report, dict):
        raise ValueError("report root is not an object")
    if report.get("schemaVersion") != REPORT_SCHEMA_VERSION:
        raise ValueError(
            f"schemaVersion is {report.get('schemaVersion')}, expected {REPORT_SCHEMA_VERSION}"
        )
    expectation = expected_mtp_expectation(expect_mtp_inactive)
    expected_fingerprint = (
        f"{build_configuration}:{expectation['kind']}:{fingerprint}"
    )
    if report.get("runFingerprint") != expected_fingerprint:
        raise ValueError("run fingerprint does not match this launch")
    if report.get("buildConfiguration") != build_configuration:
        raise ValueError("report build configuration does not match this launch")
    if report.get("mtpExpectation") != expectation:
        raise ValueError("report MTP expectation does not match this launch")
    if mode == "production-performance" and expect_mtp_inactive:
        raise ValueError("production performance cannot be expected-inactive")
    if report.get("complete") is not True:
        raise ValueError("report is only a partial checkpoint")
    if report.get("expectedCaseCount") != 40:
        raise ValueError("expectedCaseCount is not 40")
    if report.get("maxTokensPerRow") != max_tokens:
        raise ValueError("maxTokensPerRow does not match the request")
    if report.get("warmupIterations") != warmup:
        raise ValueError("warmupIterations does not match the request")
    if report.get("measurementRepetitions") != repetitions:
        raise ValueError("measurementRepetitions does not match the request")
    if report.get("modeOrderSeed") != seed:
        raise ValueError("modeOrderSeed does not match the request")
    validate_report_artifact(report.get("target"), target, "target")
    validate_report_artifact(report.get("assistant"), assistant, "assistant")

    expected_purpose = (
        "raw_parity_stress" if mode == "raw-parity" else "production_performance"
    )
    expected_stop = (
        "raw_fixed_length_no_stop"
        if mode == "raw-parity"
        else "production_target_eos"
    )
    if report.get("purpose") != expected_purpose:
        raise ValueError("report purpose does not match this launch")
    stop_policy = report.get("stopPolicy", {})
    if stop_policy.get("kind") != expected_stop:
        raise ValueError("report stop policy does not match this launch")
    configured_stop_count = stop_policy.get("configuredTokenCount")
    if mode == "raw-parity" and configured_stop_count != 0:
        raise ValueError("raw parity report claims configured stop tokens")
    if mode == "production-performance" and (
        not isinstance(configured_stop_count, int) or configured_stop_count <= 0
    ):
        raise ValueError("production performance report has no target EOS evidence")
    exposed_token_arrays = recursively_present_keys(report, {"tokenIDs"})
    if exposed_token_arrays:
        raise ValueError("report recursively exposes raw token IDs")
    if mode != "production-performance":
        exposed = recursively_present_keys(report, PERFORMANCE_KEYS)
        if exposed:
            raise ValueError(
                f"non-performance report recursively exposes performance keys: {sorted(exposed)}"
            )
    else:
        elapsed = report.get("elapsedMs")
        if elapsed is None:
            raise ValueError("production performance report omitted elapsedMs")
        if not nonnegative_finite_number(elapsed):
            raise ValueError("production performance elapsedMs must be a finite nonnegative number")

    started_at = parse_timestamp(report.get("startedAt"), "startedAt")
    generated_at = parse_timestamp(report.get("generatedAt"), "generatedAt")
    completed_at = parse_timestamp(report.get("completedAt"), "completedAt")
    launch_datetime = datetime.fromtimestamp(launch_time, timezone.utc)
    now = datetime.now(timezone.utc)
    if started_at < launch_datetime.replace(microsecond=0):
        raise ValueError("report startedAt predates this launch")
    if not (started_at <= generated_at <= now) or not (started_at <= completed_at <= now):
        raise ValueError("report timestamps are not fresh and ordered")

    cases = report.get("cases")
    if not isinstance(cases, list) or len(cases) != 40:
        count = len(cases) if isinstance(cases, list) else "invalid"
        raise ValueError(f"report has {count} cases")
    expected_keys = {
        (kind, width, batch)
        for kind, widths in (
            ("target_only", [None]),
            ("fixed", list(range(1, 9))),
            ("adaptive", [None]),
        )
        for width in widths
        for batch in (1, 2, 4, 8)
    }
    actual_keys: set[tuple[str, int | None, int]] = set()
    baseline_rows: dict[int, list[tuple[str, int, str, str]]] = {}
    for case in cases:
        if not isinstance(case, dict):
            raise ValueError("case is not an object")
        mode_value = case.get("mode", {})
        kind = mode_value.get("kind")
        width = mode_value.get("verificationWidth")
        batch = case.get("batchSize")
        actual_keys.add((kind, width, batch))
        label = f"case {kind}/{width}/B{batch}"
        if case.get("measurementRepetitions") != repetitions:
            raise ValueError(f"{label} repetition count is wrong")
        if case.get("tokenParity") is not True or case.get("parityMismatchRows") != []:
            raise ValueError(f"{label} failed token parity")
        rows = case.get("rows", [])
        if not isinstance(rows, list) or len(rows) != batch:
            raise ValueError(f"{label} has the wrong row count")
        row_evidence: list[tuple[str, int, str, str]] = []
        for row_index, row in enumerate(rows):
            if not isinstance(row, dict):
                raise ValueError(f"{label} row {row_index} is invalid")
            token_count = row.get("tokenCount")
            digest = row.get("opaqueTokenDigest")
            if not isinstance(token_count, int) or token_count <= 0:
                raise ValueError(f"{label} row {row_index} has no token count")
            if (
                not isinstance(digest, str)
                or len(digest) != 64
                or set(digest.lower()) - HEX_DIGITS
            ):
                raise ValueError(f"{label} row {row_index} has invalid opaque evidence")
            if mode == "raw-parity" and (
                row.get("finishReason") != "length" or token_count != max_tokens
            ):
                raise ValueError(f"{label} row {row_index} is not fixed length")
            if mode != "raw-parity" and row.get("finishReason") not in {"stop", "length"}:
                raise ValueError(f"{label} row {row_index} has invalid terminal reason")
            if (
                mode != "raw-parity"
                and row.get("finishReason") == "length"
                and token_count != max_tokens
            ):
                raise ValueError(f"{label} row {row_index} length terminal is premature")
            if (
                mode != "raw-parity"
                and row.get("finishReason") == "stop"
                and token_count > max_tokens
            ):
                raise ValueError(f"{label} row {row_index} stop terminal exceeds maxTokens")
            # finishReason is part of the cross-mode evidence: identical
            # tokens with a different terminal reason (EOS at the budget as
            # "stop" vs "length") is an OpenAI-visible divergence.
            row_evidence.append(
                (str(row.get("promptName", "")), token_count, digest,
                 str(row.get("finishReason", ""))))
        if kind == "target_only":
            baseline_rows[batch] = row_evidence
        elif baseline_rows.get(batch) != row_evidence:
            raise ValueError(f"{label} opaque evidence differs from baseline")
        if mode != "raw-parity":
            throughput = case.get("medianAggregateDecodeTokensPerSecond")
            if throughput is None:
                raise ValueError("production performance case omitted aggregate throughput")
            if not nonnegative_finite_number(throughput):
                raise ValueError(f"{label} aggregate throughput must be a finite nonnegative number")

        validate_case_metrics(
            case.get("metrics", {}), kind=kind, width=width, batch=batch,
            mode=mode, expect_inactive=expect_mtp_inactive, expectation=expectation)
    if actual_keys != expected_keys:
        missing = sorted(expected_keys - actual_keys, key=str)
        extra = sorted(actual_keys - expected_keys, key=str)
        raise ValueError(f"case set mismatch; missing={missing}, extra={extra}")

    coverage = report.get("coverage", {})
    for field, expected in expected_coverage(report).items():
        if coverage.get(field) != expected:
            raise ValueError(f"coverage.{field} is not dynamically labeled {expected}")


