from __future__ import annotations

import os
import re
import subprocess
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence

try:
    from scripts.fault_matrix import (
        FaultMatrixError,
        validate_report as validate_fault_matrix,
    )
    from scripts.pilot_load.component import (
        component_coverage,
        expected_component_tests,
        measured_component_tests,
    )
except ModuleNotFoundError:  # Direct `scripts/cutover-readiness.py` execution.
    from fault_matrix import FaultMatrixError, validate_report as validate_fault_matrix
    from pilot_load.component import (
        component_coverage,
        expected_component_tests,
        measured_component_tests,
    )

from . import SCHEMA_VERSION, TOOL_VERSION
from .environment import validate_payload_binding
from .integrity import (
    IntegrityError,
    canonical_bytes,
    format_timestamp,
    load_json,
    parse_timestamp,
    seal_document,
    sha256_bytes,
    sha256_file,
    utc_now,
    verify_document,
)

ROOT = Path(__file__).resolve().parents[2]
EVIDENCE_SCHEMA = ROOT / "deploy/cutover/evidence-schema.json"
GATE_POLICY = ROOT / "deploy/cutover/gates.json"

REPORT_TYPES = frozenset(
    {
        "fault",
        "load",
        "differential",
        "route_trace",
        "rollback_drill",
        "live_snapshot",
        "bake_observation",
        "retirement_inventory",
        "gate_assessment",
        "human_approval",
        "gate_authorization",
        "environment_manifest",
    }
)
VERDICTS = frozenset({"pass", "fail", "inconclusive"})
Clock = Callable[[], datetime]


def new_report(
    report_type: str,
    environment: str,
    payload: Mapping[str, Any],
    verdict: str,
    *,
    validity: timedelta,
    signing_key: Path | None = None,
    now: datetime | None = None,
) -> dict[str, Any]:
    if report_type not in REPORT_TYPES:
        raise IntegrityError(f"unsupported report type {report_type}")
    if verdict not in VERDICTS:
        raise IntegrityError(f"unsupported report verdict {verdict}")
    if environment not in {"isolated", "canary", "development", "production"}:
        raise IntegrityError("environment must be isolated, canary, development, or production")
    if validity <= timedelta(0):
        raise IntegrityError("report validity must be positive")
    generated = now or utc_now()
    if generated.tzinfo is None:
        raise IntegrityError("report clock must be timezone-aware")
    generated = generated.astimezone(timezone.utc)
    document = {
        "schema_version": SCHEMA_VERSION,
        "report_type": report_type,
        "generated_at": format_timestamp(generated),
        "valid_until": format_timestamp(generated + validity),
        "environment": environment,
        "verdict": verdict,
        "payload": {**dict(payload), "provenance": _evidence_provenance()},
    }
    return seal_document(document, signing_key=signing_key)


def validate_report(
    report: Mapping[str, Any],
    *,
    expected_type: str | None = None,
    trusted_keys: Mapping[str, Path] | None = None,
    require_signature: bool = False,
    now: datetime | None = None,
    maximum_age: timedelta | None = None,
    future_skew: timedelta = timedelta(minutes=5),
) -> str:
    expected_fields = {
        "schema_version",
        "report_type",
        "generated_at",
        "valid_until",
        "environment",
        "verdict",
        "payload",
        "integrity",
    }
    if set(report) != expected_fields:
        raise IntegrityError(
            f"report fields do not match evidence schema version {SCHEMA_VERSION}"
        )
    if report.get("schema_version") != SCHEMA_VERSION:
        raise IntegrityError(f"report schema_version must be {SCHEMA_VERSION}")
    report_type = report.get("report_type")
    if report_type not in REPORT_TYPES:
        raise IntegrityError("report_type is missing or unsupported")
    if expected_type is not None and report_type != expected_type:
        raise IntegrityError(f"expected {expected_type} report, received {report_type}")
    if report.get("environment") not in {"isolated", "canary", "development", "production"}:
        raise IntegrityError("report environment is missing or unsupported")
    if report.get("verdict") not in VERDICTS:
        raise IntegrityError("report verdict is missing or unsupported")
    if not isinstance(report.get("payload"), dict):
        raise IntegrityError("report payload must be an object")
    digest = verify_document(
        report,
        trusted_keys=trusted_keys,
        require_signature=require_signature,
    )
    observed_now = now or utc_now()
    if observed_now.tzinfo is None:
        raise IntegrityError("validation clock must be timezone-aware")
    observed_now = observed_now.astimezone(timezone.utc)
    generated = parse_timestamp(report.get("generated_at"), "generated_at")
    valid_until = parse_timestamp(report.get("valid_until"), "valid_until")
    if valid_until <= generated:
        raise IntegrityError("valid_until must be after generated_at")
    if generated > observed_now + future_skew:
        raise IntegrityError("report generated_at is implausibly in the future")
    if valid_until < observed_now:
        raise IntegrityError("report is stale")
    if maximum_age is not None and observed_now - generated > maximum_age:
        raise IntegrityError("report exceeds the gate's maximum evidence age")
    return digest


def import_pilot_report(
    source: Path,
    *,
    environment_binding: Mapping[str, Any] | None = None,
    signing_key: Path | None = None,
    now: datetime | None = None,
) -> dict[str, Any]:
    pilot = load_json(source)
    if pilot.get("schema_version") != 1:
        raise IntegrityError("pilot report schema_version must be 1")
    profile = pilot.get("profile")
    comparison = pilot.get("comparison")
    if (
        pilot.get("verdict") == "baseline_review_required"
        or pilot.get("authorization_eligible") is False
    ):
        raise IntegrityError(
            "capture-only pilot report is non-authorizing and requires baseline review"
        )
    source_generated = parse_timestamp(pilot.get("generated_at"), "pilot.generated_at")
    observed_now = now or utc_now()
    if observed_now.tzinfo is None:
        raise IntegrityError("pilot import clock must be timezone-aware")
    if source_generated > observed_now.astimezone(timezone.utc) + timedelta(minutes=5):
        raise IntegrityError("pilot generated_at is implausibly in the future")
    source_fact = {
        "path": source.name,
        "sha256": sha256_file(source),
        "schema_version": pilot["schema_version"],
        "generated_at": pilot.get("generated_at"),
    }
    if isinstance(profile, dict) and isinstance(comparison, dict):
        _validate_pilot_baseline_authorization(pilot, profile)
        failures = pilot.get("gate_failures")
        skipped = pilot.get("skipped_scenarios")
        if not isinstance(failures, list) or not isinstance(skipped, list):
            raise IntegrityError(
                "differential report must contain gate_failures and skipped_scenarios lists"
            )
        passed = (
            pilot.get("verdict") == "pass"
            and comparison.get("passed") is True
            and not comparison.get("differences")
            and not failures
            and not skipped
        )
        report_type = "differential"
        targets = pilot.get("targets")
        targets = targets if isinstance(targets, dict) else {}
        payload = {
            "source": source_fact,
            "profile": profile.get("name"),
            "comparison_passed": comparison.get("passed") is True,
            "unapproved_differences": len(comparison.get("differences", [])),
            "gate_failure_count": len(failures),
            "skipped_scenario_count": len(skipped),
            "targets": sorted(targets),
            "target_load_elapsed_seconds": {
                name: target.get("load_elapsed_seconds")
                for name, target in targets.items()
                if isinstance(target, dict)
            },
        }
    elif isinstance(profile, str):
        coverage = pilot.get("coverage")
        commands = pilot.get("commands")
        if not isinstance(coverage, dict) or not isinstance(commands, list):
            raise IntegrityError("component load report must contain coverage and commands")
        _verify_component_measurements(source, commands)
        derived_coverage = component_coverage(commands)
        if coverage != derived_coverage:
            raise IntegrityError(
                "component load coverage does not match passing executable commands"
            )
        failed_commands = [
            command
            for command in commands
            if not isinstance(command, dict) or command.get("exit_code") != 0
        ]
        required_coverage = (
            "go_in_process_coordinator",
            "rust_in_process_coordinator",
            "synthetic_go_peer",
            "synthetic_rust_v2_peer",
            "slow_consumers",
            "session_replacement",
            "hedge",
            "sent_unknown",
        )
        minimum_elapsed = 1_800 if profile == "scheduled" else 0
        elapsed = pilot.get("elapsed_seconds")
        passed = (
            pilot.get("verdict") == "pass"
            and isinstance(pilot.get("iterations"), int)
            and pilot["iterations"] > 0
            and isinstance(elapsed, (int, float))
            and not isinstance(elapsed, bool)
            and elapsed >= minimum_elapsed
            and bool(commands)
            and not failed_commands
            and all(derived_coverage.get(name) is True for name in required_coverage)
        )
        report_type = "load"
        payload = {
            "source": source_fact,
            "profile": profile,
            "iterations": pilot.get("iterations"),
            "elapsed_seconds": elapsed,
            "coverage": derived_coverage,
            "command_count": len(commands),
            "failed_command_count": len(failed_commands),
        }
    else:
        raise IntegrityError("pilot report is neither a differential nor component load report")
    return new_report(
        report_type,
        "isolated",
        _attach_environment(payload, environment_binding),
        "pass" if passed else "fail",
        validity=timedelta(days=7),
        signing_key=signing_key,
        now=source_generated,
    )


def _validate_pilot_baseline_authorization(
    pilot: Mapping[str, Any],
    profile: Mapping[str, Any],
) -> None:
    metadata = pilot.get("metadata")
    baseline_mode = (
        metadata.get("regression_baseline_mode")
        if isinstance(metadata, dict)
        else None
    )
    if baseline_mode == "capture":
        raise IntegrityError(
            "capture-only pilot report is non-authorizing and requires baseline review"
        )
    if profile.get("name") != "scheduled":
        return
    if not isinstance(metadata, dict) or baseline_mode != "measured":
        raise IntegrityError(
            "scheduled pilot evidence requires a reviewed measured baseline"
        )
    baseline = metadata.get("baseline_provenance")
    source = metadata.get("source")
    ci = metadata.get("ci")
    if (
        not isinstance(baseline, dict)
        or baseline.get("review_status") != "reviewed"
        or not isinstance(baseline.get("source_commit"), str)
        or re.fullmatch(r"[0-9a-f]{40,64}", baseline["source_commit"]) is None
        or not baseline.get("source_run_id")
        or not isinstance(baseline.get("source_report_sha256"), str)
        or re.fullmatch(r"[0-9a-f]{64}", baseline["source_report_sha256"]) is None
        or not isinstance(source, dict)
        or baseline["source_commit"] == source.get("commit")
        or not isinstance(ci, dict)
        or ci.get("provider") != "github-actions"
        or not ci.get("run_id")
        or baseline["source_run_id"] == ci.get("run_id")
    ):
        raise IntegrityError(
            "scheduled pilot baseline must come from a distinct prior run and commit"
        )


def _verify_component_measurements(source: Path, commands: Sequence[Any]) -> None:
    report_directory = source.resolve().parent
    for command in commands:
        if (
            not isinstance(command, dict)
            or not isinstance(command.get("name"), str)
            or not command["name"]
            or not isinstance(command.get("exit_code"), int)
            or isinstance(command.get("exit_code"), bool)
            or not isinstance(command.get("log"), str)
            or not command["log"]
            or not isinstance(command.get("log_sha256"), str)
            or not isinstance(command.get("expected_tests"), list)
            or not isinstance(command.get("passed_tests"), list)
            or not isinstance(command.get("measurement_complete"), bool)
        ):
            raise IntegrityError("component load commands are malformed")
        relative_log = Path(command["log"])
        if relative_log.is_absolute() or ".." in relative_log.parts:
            raise IntegrityError("component load log path must stay inside the report directory")
        log_path = (report_directory / relative_log).resolve()
        if not log_path.is_relative_to(report_directory) or not log_path.is_file():
            raise IntegrityError("component load log artifact is unavailable")
        if sha256_file(log_path) != command["log_sha256"]:
            raise IntegrityError("component load log hash does not match the report")
        output = log_path.read_text(encoding="utf-8", errors="replace")
        expected = sorted(expected_component_tests(command["name"]))
        measured = sorted(measured_component_tests(command["name"], output))
        complete = set(expected).issubset(measured)
        if (
            command["expected_tests"] != expected
            or command["passed_tests"] != measured
            or command["measurement_complete"] is not complete
        ):
            raise IntegrityError(
                "component load measurements do not match executable test output"
            )


def import_route_trace(
    source: Path,
    *,
    environment: str,
    environment_binding: Mapping[str, Any] | None = None,
    signing_key: Path | None = None,
    now: datetime | None = None,
) -> dict[str, Any]:
    trace = load_json(source)
    expected_fields = {
        "schema_version",
        "generated_at",
        "mode",
        "source_requests",
        "routed_requests",
        "failed_requests",
        "latency_p95_ms",
        "mutation_count",
        "ownership_mode",
        "listener",
        "production_listener",
        "database_identity",
        "production_database_identity",
        "money_mode",
    }
    if set(trace) != expected_fields or trace.get("schema_version") != 2:
        raise IntegrityError("route trace does not match schema version 2")
    generated = parse_timestamp(trace.get("generated_at"), "route_trace.generated_at")
    observed_now = now or utc_now()
    if generated > observed_now + timedelta(minutes=5):
        raise IntegrityError("route trace generated_at is implausibly in the future")
    source_requests = _positive_count(trace.get("source_requests"), "source_requests")
    routed_requests = _positive_count(trace.get("routed_requests"), "routed_requests")
    failed_requests = _nonnegative_count(trace.get("failed_requests"), "failed_requests")
    if routed_requests > source_requests or failed_requests > routed_requests:
        raise IntegrityError("route trace request counts are inconsistent")
    latency = trace.get("latency_p95_ms")
    if not isinstance(latency, (int, float)) or isinstance(latency, bool) or latency < 0:
        raise IntegrityError("route trace latency_p95_ms must be non-negative")
    mutation_count = _nonnegative_count(trace.get("mutation_count"), "mutation_count")
    ratio = routed_requests / source_requests
    payload = {
        "source": {
            "path": source.name,
            "sha256": sha256_file(source),
            "schema_version": trace["schema_version"],
            "generated_at": trace["generated_at"],
        },
        "mode": trace.get("mode"),
        "source_requests": source_requests,
        "routed_requests": routed_requests,
        "observed_route_ratio": ratio,
        "failed_requests": failed_requests,
        "error_ratio": failed_requests / routed_requests,
        "latency_p95_ms": latency,
        "mutation_count": mutation_count,
        "ownership_mode": trace.get("ownership_mode"),
        "listener": trace.get("listener"),
        "production_listener": trace.get("production_listener"),
        "database_identity": trace.get("database_identity"),
        "production_database_identity": trace.get("production_database_identity"),
        "money_mode": trace.get("money_mode"),
    }
    return new_report(
        "route_trace",
        environment,
        _attach_environment(payload, environment_binding),
        "pass",
        validity=timedelta(days=2),
        signing_key=signing_key,
        now=generated,
    )


def import_fault_matrix_report(
    source: Path,
    *,
    trusted_receipt_key: Path,
    environment_binding: Mapping[str, Any] | None = None,
    signing_key: Path | None = None,
    now: datetime | None = None,
) -> dict[str, Any]:
    matrix = load_json(source)
    try:
        verified = validate_fault_matrix(matrix, trusted_receipt_key)
    except FaultMatrixError as error:
        raise IntegrityError(f"invalid signed fault matrix receipts: {error}") from error
    policy = load_json(GATE_POLICY)
    try:
        fault_rules = policy["gates"]["isolated-pilot"]["reports"]["fault"]
        required_boundary_count = fault_rules["required_boundary_count"]
        required_coverage = set(fault_rules["required_coverage"])
    except (KeyError, TypeError) as error:
        raise IntegrityError("fault evidence policy is incomplete") from error
    if (
        not isinstance(required_boundary_count, int)
        or isinstance(required_boundary_count, bool)
        or required_boundary_count <= 0
    ):
        raise IntegrityError("fault evidence policy boundary count is invalid")
    if any(not isinstance(value, str) or not value for value in required_coverage):
        raise IntegrityError("fault evidence policy coverage is invalid")
    if verified["boundary_count"] != required_boundary_count:
        raise IntegrityError(
            "signed fault matrix boundary count does not match cutover policy"
        )
    if not set(verified["coverage"]).issuperset(required_coverage):
        raise IntegrityError("signed fault matrix coverage does not match cutover policy")
    payload = {
        "check": "fault-matrix-receipts",
        "receipt_schema_version": verified["schema_version"],
        "objective": verified["objective"],
        "commit": verified["commit"],
        "signer_key_id": verified["signer_key_id"],
        "boundary_count": verified["boundary_count"],
        "uncovered_boundary_count": 0,
        "coverage": verified["coverage"],
        "source": {
            "path": source.name,
            "sha256": sha256_file(source),
        },
    }
    return new_report(
        "fault",
        "isolated",
        _attach_environment(payload, environment_binding),
        "pass",
        validity=timedelta(days=7),
        signing_key=signing_key,
        now=now,
    )


def run_check(
    check_name: str,
    command: Sequence[str],
    *,
    coverage: Sequence[str],
    environment_binding: Mapping[str, Any] | None = None,
    environment: str = "isolated",
    validity: timedelta = timedelta(days=7),
    signing_key: Path | None = None,
    timeout_seconds: int = 3600,
    now: datetime | None = None,
) -> tuple[dict[str, Any], subprocess.CompletedProcess[bytes]]:
    if not check_name or any(character.isspace() for character in check_name):
        raise IntegrityError("check name must be a non-empty token")
    if not command:
        raise IntegrityError("check command is required")
    if timeout_seconds <= 0 or timeout_seconds > 6 * 60 * 60:
        raise IntegrityError("check timeout must be between 1 second and 6 hours")
    if check_name == "fault-matrix":
        raise IntegrityError("fault evidence must be imported from signed executable receipts")
    started = now or utc_now()
    derived_coverage, coverage_source = _derived_check_coverage(check_name, coverage)
    try:
        completed = subprocess.run(
            list(command),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=timeout_seconds,
            env=_check_environment(),
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        payload = {
            "check": check_name,
            "command": list(command),
            "coverage": derived_coverage,
            "coverage_source": coverage_source,
            "execution_error": str(error),
        }
        report = new_report(
            "fault" if check_name == "fault-matrix" else "rollback_drill",
            environment,
            _attach_environment(payload, environment_binding),
            "inconclusive",
            validity=validity,
            signing_key=signing_key,
            now=started,
        )
        raise CheckExecutionError(report, str(error)) from error
    payload = {
        "check": check_name,
        "command": list(command),
        "coverage": derived_coverage,
        "coverage_source": coverage_source,
        "exit_code": completed.returncode,
        "stdout_sha256": _sha256_output(completed.stdout),
        "stderr_sha256": _sha256_output(completed.stderr),
    }
    report_type = "fault" if check_name == "fault-matrix" else "rollback_drill"
    report = new_report(
        report_type,
        environment,
        _attach_environment(payload, environment_binding),
        "pass" if completed.returncode == 0 else "fail",
        validity=validity,
        signing_key=signing_key,
        now=started,
    )
    return report, completed


def _sha256_output(value: bytes) -> str:
    import hashlib

    return hashlib.sha256(value).hexdigest()


def _derived_check_coverage(
    check_name: str,
    requested: Sequence[str],
) -> tuple[list[str], dict[str, Any]]:
    if check_name == "rollback-rehearsal":
        if requested:
            raise IntegrityError("rollback coverage is emitted by the rehearsal, not the caller")
        coverage = [
            "additive_schema_go_compatibility",
            "candidate_failure_injection",
            "distinct_immutable_images",
            "durable_historical_terminal_ack",
            "fallback_serving_before_and_after",
            "local_container_handoff",
            "provider_v1_fallback",
            "single_database_owner",
        ]
        script = ROOT / "scripts/rehearse-coordinator-rollback.sh"
        return coverage, {
            "path": str(script.relative_to(ROOT)),
            "sha256": sha256_file(script),
        }
    raise IntegrityError("unsupported executable evidence check")


def _evidence_provenance() -> dict[str, Any]:
    github_actions = os.environ.get("GITHUB_ACTIONS") == "true"
    if github_actions:
        required = {
            "repository": os.environ.get("GITHUB_REPOSITORY"),
            "commit": os.environ.get("GITHUB_SHA"),
            "run_id": os.environ.get("GITHUB_RUN_ID"),
            "run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT"),
            "workflow": os.environ.get("GITHUB_WORKFLOW"),
            "workflow_ref": os.environ.get("GITHUB_WORKFLOW_REF"),
            "workflow_sha": os.environ.get("GITHUB_WORKFLOW_SHA"),
            "ref": os.environ.get("GITHUB_REF"),
            "ref_protected": os.environ.get("GITHUB_REF_PROTECTED"),
            "event_name": os.environ.get("GITHUB_EVENT_NAME"),
        }
        if (
            required["repository"] != "Layr-Labs/d-inference"
            or not isinstance(required["commit"], str)
            or len(required["commit"]) != 40
            or any(not value for value in required.values())
            or required["workflow_sha"] != required["commit"]
            or required["ref"] != "refs/heads/master"
            or required["ref_protected"] != "true"
            or required["event_name"] not in {"schedule", "workflow_dispatch"}
            or not str(required["workflow_ref"]).startswith(
                f"{required['repository']}/.github/workflows/"
            )
            or not str(required["workflow_ref"]).endswith(f"@{required['ref']}")
        ):
            raise IntegrityError("GitHub evidence provenance is missing or invalid")
        kind = "github_actions"
    else:
        required = {
            "repository": "Layr-Labs/d-inference",
            "commit": _repository_commit(),
        }
        kind = "local_operator"
    tool_files = sorted((ROOT / "scripts/cutover_readiness").glob("*.py"))
    tool_manifest = [
        {"path": str(path.relative_to(ROOT)), "sha256": sha256_file(path)}
        for path in tool_files
    ]
    return {
        "kind": kind,
        **required,
        "tool_version": TOOL_VERSION,
        "tool_manifest_sha256": sha256_bytes(canonical_bytes(tool_manifest)),
        "report_schema_version": SCHEMA_VERSION,
        "report_schema_sha256": sha256_file(EVIDENCE_SCHEMA),
    }


def _repository_commit() -> str:
    try:
        completed = subprocess.run(
            ["/usr/bin/git", "-C", str(ROOT), "rev-parse", "HEAD"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise IntegrityError(f"cannot bind evidence to repository commit: {error}") from error
    commit = completed.stdout.decode("ascii", errors="ignore").strip()
    if completed.returncode != 0 or len(commit) != 40:
        raise IntegrityError("cannot bind evidence to repository commit")
    return commit


def _positive_count(value: Any, name: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
        raise IntegrityError(f"{name} must be a positive integer")
    return value


def _nonnegative_count(value: Any, name: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        raise IntegrityError(f"{name} must be a non-negative integer")
    return value


def _check_environment() -> dict[str, str]:
    import os
    import urllib.parse

    sensitive_markers = (
        "DATABASE_URL",
        "PASSWORD",
        "TOKEN",
        "SECRET",
        "API_KEY",
        "APPLICATION_KEY",
        "PRIVATE_KEY",
        "MNEMONIC",
        "CREDENTIAL",
    )
    environment = {
        key: value
        for key, value in os.environ.items()
        if not any(marker in key.upper() for marker in sensitive_markers)
    }
    test_database = os.environ.get("DARKBLOOM_TEST_DATABASE_URL")
    if test_database:
        hostname = urllib.parse.urlsplit(test_database).hostname
        if hostname not in {"localhost", "127.0.0.1", "::1"}:
            raise IntegrityError("DARKBLOOM_TEST_DATABASE_URL must use loopback")
        environment["DARKBLOOM_TEST_DATABASE_URL"] = test_database
    return environment


class CheckExecutionError(RuntimeError):
    def __init__(self, report: Mapping[str, Any], message: str) -> None:
        super().__init__(message)
        self.report = dict(report)


def _attach_environment(
    payload: Mapping[str, Any],
    environment_binding: Mapping[str, Any] | None,
) -> dict[str, Any]:
    result = dict(payload)
    if environment_binding is not None:
        result["environment_binding"] = validate_payload_binding(
            dict(environment_binding)
        )
    return result

