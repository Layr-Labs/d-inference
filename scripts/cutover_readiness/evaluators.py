from __future__ import annotations

from dataclasses import dataclass
from datetime import timedelta
from pathlib import Path
from typing import Any, Mapping

from . import SCHEMA_VERSION, TOOL_VERSION
from .environment import (
    EnvironmentBindingError,
    active_environment,
    validate_payload_binding,
)
from .integrity import canonical_bytes, parse_timestamp, sha256_bytes, sha256_file

ROOT = Path(__file__).resolve().parents[2]
EVIDENCE_SCHEMA = ROOT / "deploy/cutover/evidence-schema.json"
DATADOG_SITES = frozenset({"us1", "us3", "us5", "eu", "ap1", "ap2"})
COORDINATOR_EVIDENCE_SOURCES = frozenset(
    {"health", "ready", "quiescence", "attestation", "utilization", "metrics"}
)


class EvaluationError(ValueError):
    """A policy has no safe evaluator for an evidence report."""


@dataclass(frozen=True)
class Check:
    name: str
    passed: bool
    observed: Any
    required: Any

    def json(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "passed": self.passed,
            "observed": self.observed,
            "required": self.required,
        }


def evaluate_report(
    report_type: str,
    payload: Mapping[str, Any],
    rules: Mapping[str, Any],
) -> list[Check]:
    checks = _provenance_checks(payload) + _environment_binding_checks(payload)
    if report_type in {"fault", "rollback_drill"}:
        return checks + _evaluate_executable(report_type, payload, rules)
    if report_type == "load":
        return checks + _evaluate_load(payload)
    if report_type == "differential":
        return checks + _evaluate_differential(payload)
    if report_type == "route_trace":
        return checks + _evaluate_route_trace(payload, rules)
    if report_type == "live_snapshot":
        return checks + evaluate_live(payload, rules)
    if report_type == "bake_observation":
        return checks + _evaluate_bake(payload, rules)
    if report_type == "retirement_inventory":
        return checks + [
            Check(
                f"retirement:{name}",
                payload.get(name) is True,
                payload.get(name),
                True,
            )
            for name in rules.get("required_true", [])
        ]
    raise EvaluationError(f"no evaluator exists for report type {report_type}")


def evaluate_live(payload: Mapping[str, Any], rules: Mapping[str, Any]) -> list[Check]:
    coordinator = _mapping(payload, "coordinator")
    health = _mapping(coordinator, "health")
    ready = _mapping(coordinator, "ready")
    quiescence = _mapping(coordinator, "quiescence")
    coverage = _mapping(coordinator, "provider_coverage")
    durable = _mapping(coordinator, "durable_counts")
    datadog = _mapping(payload, "datadog")
    queries = _mapping(datadog, "queries")
    rds = _mapping(payload, "rds")
    checks = _environment_source_checks(
        payload,
        coordinator,
        datadog,
        rds,
        rules,
    )
    checks.extend(_fixed_window_checks(payload, queries, rds))
    checks.extend(_live_base_checks(payload, rules, health, ready, quiescence, rds))
    checks.extend(_source_checks(coordinator, datadog, queries))
    checks.extend(_durable_checks(durable, rds, rules))
    checks.extend(_provider_checks(coverage, rules))
    checks.extend(_definition_checks(datadog, rds, rules))
    checks.extend(_datadog_checks(queries, rules))
    return checks


def _fixed_window_checks(
    payload: Mapping[str, Any],
    queries: Mapping[str, Any],
    rds: Mapping[str, Any],
) -> list[Check]:
    started = parse_timestamp(payload.get("window_started_at"), "window_started_at")
    ended = parse_timestamp(payload.get("window_ended_at"), "window_ended_at")
    duration = int((ended - started).total_seconds())
    expected = (payload.get("window_started_at"), payload.get("window_ended_at"))
    query_windows = {
        name: (
            result.get("window_started_at"),
            result.get("window_ended_at"),
            result.get("window_seconds"),
            result.get("bucket_seconds"),
        )
        for name, result in queries.items()
        if isinstance(result, dict)
    }
    query_valid = bool(queries) and len(query_windows) == len(queries) and all(
        (window[0], window[1]) == expected
        and window[2] == duration
        and isinstance(window[3], int)
        and window[3] > 0
        and duration % window[3] == 0
        and result.get("bucket_started_at")
        == [
            (started + timedelta(seconds=offset))
            .isoformat()
            .replace("+00:00", "Z")
            for offset in range(0, duration, window[3])
        ]
        and result.get("rollup_aggregator") in {"min", "max", "sum"}
        for result, window in (
            (queries[name], query_windows[name]) for name in query_windows
        )
    )
    return [
        Check(
            "live:fixed_window",
            duration > 0
            and int(started.timestamp()) % duration == 0
            and int(ended.timestamp()) % duration == 0,
            duration,
            "positive aligned interval",
        ),
        Check(
            "live:datadog_windows",
            query_valid,
            query_windows,
            expected,
        ),
        Check(
            "live:rds_window",
            (
                rds.get("window_started_at"),
                rds.get("window_ended_at"),
            )
            == expected,
            (
                rds.get("window_started_at"),
                rds.get("window_ended_at"),
            ),
            expected,
        ),
    ]


def _environment_binding_checks(payload: Mapping[str, Any]) -> list[Check]:
    try:
        binding = validate_payload_binding(payload.get("environment_binding"))
    except EnvironmentBindingError as error:
        return [Check("environment:binding", False, str(error), "valid canonical binding")]
    return [
        Check(
            "environment:binding",
            True,
            binding["environment_id"],
            binding["environment_id"],
        )
    ]


def _environment_source_checks(
    payload: Mapping[str, Any],
    coordinator: Mapping[str, Any],
    datadog: Mapping[str, Any],
    rds: Mapping[str, Any],
    rules: Mapping[str, Any],
) -> list[Check]:
    try:
        binding = validate_payload_binding(payload.get("environment_binding"))
        source_environment = rules.get("source_environment")
        traffic_mode = payload.get("traffic_mode")
        environment = (
            source_environment
            if source_environment in {"canary", "production"}
            else "canary"
            if traffic_mode == "dedicated_self_route"
            else "production"
        )
        active = active_environment(binding, environment)
    except EnvironmentBindingError as error:
        return [
            Check(
                "live:environment_binding",
                False,
                str(error),
                "valid active environment",
            )
        ]
    observed_ids = {
        "coordinator": coordinator.get("environment_id"),
        "datadog": datadog.get("environment_id"),
        "rds": rds.get("environment_id"),
    }
    health = _mapping(coordinator, "health")
    return [
        Check(
            "live:environment_id_equality",
            set(observed_ids.values()) == {active["environment_id"]},
            observed_ids,
            active["environment_id"],
        ),
        Check(
            "live:listener_identity",
            health.get("listener_identity") == active["listener_identity"],
            health.get("listener_identity"),
            active["listener_identity"],
        ),
        Check(
            "live:ownership_identity",
            health.get("coordinator_ownership_id")
            == active["coordinator_ownership_id"],
            health.get("coordinator_ownership_id"),
            active["coordinator_ownership_id"],
        ),
        Check(
            "live:app_identity",
            health.get("coordinator_app_id") == active["coordinator_app_id"],
            health.get("coordinator_app_id"),
            active["coordinator_app_id"],
        ),
        Check(
            "live:database_identity",
            rds.get("database_instance_id") == active["database_instance_id"],
            rds.get("database_instance_id"),
            active["database_instance_id"],
        ),
        Check(
            "live:database_system_identifier",
            rds.get("database_system_identifier")
            == active["database_system_identifier"],
            rds.get("database_system_identifier"),
            active["database_system_identifier"],
        ),
        Check(
            "live:read_only_dsn",
            rds.get("read_only_dsn_sha256") == active["read_only_dsn_sha256"],
            rds.get("read_only_dsn_sha256"),
            active["read_only_dsn_sha256"],
        ),
        Check(
            "live:writer_endpoint",
            rds.get("writer_endpoint_sha256")
            == active["writer_endpoint_sha256"],
            rds.get("writer_endpoint_sha256"),
            active["writer_endpoint_sha256"],
        ),
        Check(
            "live:datadog_site_binding",
            datadog.get("site") == active["datadog_site"],
            datadog.get("site"),
            active["datadog_site"],
        ),
        Check(
            "live:datadog_organization",
            datadog.get("organization_id")
            == active["datadog_organization_id"],
            datadog.get("organization_id"),
            active["datadog_organization_id"],
        ),
    ]


def _evaluate_executable(
    report_type: str,
    payload: Mapping[str, Any],
    rules: Mapping[str, Any],
) -> list[Check]:
    coverage = payload.get("coverage")
    coverage = set(coverage) if isinstance(coverage, list) else set()
    required = set(rules.get("required_coverage", []))
    coverage_source = payload.get("coverage_source")
    coverage_source = coverage_source if isinstance(coverage_source, dict) else {}
    source_path = rules.get(
        "coverage_manifest_path" if report_type == "fault" else "coverage_script_path"
    )
    expected_source = ROOT / str(source_path) if isinstance(source_path, str) else None
    source_valid = (
        expected_source is not None
        and expected_source.is_file()
        and coverage_source.get("path") == source_path
        and coverage_source.get("sha256") == sha256_file(expected_source)
    )
    command = payload.get("command")
    command = command if isinstance(command, list) else []
    if report_type == "fault":
        provenance = payload.get("provenance")
        provenance = provenance if isinstance(provenance, dict) else {}
        identity_valid = (
            payload.get("check") == "fault-matrix-receipts"
            and payload.get("receipt_schema_version") == 1
            and payload.get("objective") == 9
            and payload.get("boundary_count") == rules.get("required_boundary_count")
            and payload.get("uncovered_boundary_count") == 0
            and isinstance(payload.get("commit"), str)
            and len(payload["commit"]) == 40
            and isinstance(payload.get("signer_key_id"), str)
            and len(payload["signer_key_id"]) == 64
            and payload.get("commit") == provenance.get("commit")
        )
        source_valid = _source_check("fault", payload).passed
        coverage_source = payload.get("source")
        source_path = "signed executable receipt bundle"
        identity_required = {
            "check": "fault-matrix-receipts",
            "receipt_schema_version": 1,
            "objective": 9,
            "boundary_count": rules.get("required_boundary_count"),
            "uncovered_boundary_count": 0,
        }
        execution_passed = payload.get("uncovered_boundary_count") == 0
        execution_observed = payload.get("uncovered_boundary_count")
        execution_required = 0
    else:
        candidate = command[2] if len(command) == 6 else None
        fallback = command[3] if len(command) == 6 else None
        try:
            descriptor = validate_payload_binding(
                payload.get("environment_binding")
            )["descriptor"]
        except EnvironmentBindingError:
            descriptor = {}
        identity_valid = (
            payload.get("check") == "rollback-rehearsal"
            and len(command) == 6
            and command[0] == str(ROOT / "scripts/rehearse-coordinator-rollback.sh")
            and command[1] == "__execute"
            and all(isinstance(value, str) and value for value in command[2:])
            and command[4] == rules.get("required_postgres_image")
            and command[5]
            == payload.get("environment_binding", {}).get("environment_id")
            and _immutable_digest(candidate)
            and _immutable_digest(fallback)
            and candidate != fallback
            and candidate == descriptor.get("candidate_image")
            and fallback == descriptor.get("fallback_image")
        )
        identity_required = (
            "rollback script __execute with candidate, fallback, and pinned PostgreSQL images"
        )
        execution_passed = payload.get("exit_code") == 0
        execution_observed = payload.get("exit_code")
        execution_required = 0
    return [
        Check(
            f"{report_type}:coverage_source",
            source_valid,
            coverage_source,
            source_path,
        ),
        Check(
            f"{report_type}:identity",
            identity_valid,
            {"check": payload.get("check"), "command": command},
            identity_required,
        ),
        Check(
            f"{report_type}:coverage",
            coverage.issuperset(required),
            sorted(coverage),
            sorted(required),
        ),
        Check(
            f"{report_type}:exit_code",
            execution_passed,
            execution_observed,
            execution_required,
        ),
    ]


def _evaluate_route_trace(payload: Mapping[str, Any], rules: Mapping[str, Any]) -> list[Check]:
    source_requests = payload.get("source_requests")
    routed_requests = payload.get("routed_requests")
    ratio = (
        routed_requests / source_requests
        if isinstance(source_requests, int)
        and source_requests > 0
        and isinstance(routed_requests, int)
        else None
    )
    mode = rules.get("mode")
    try:
        binding = validate_payload_binding(payload.get("environment_binding"))
        production_environment = active_environment(binding, "production")
        canary_environment = active_environment(binding, "canary")
    except EnvironmentBindingError:
        production_environment = {}
        canary_environment = {}
    checks = [
        _source_check("route_trace", payload),
        Check("route_trace:mode", payload.get("mode") == mode, payload.get("mode"), mode),
        Check(
            "route_trace:measured_ratio",
            ratio is not None
            and payload.get("observed_route_ratio") == ratio
            and ratio >= rules["minimum_observed_route_ratio"],
            payload.get("observed_route_ratio"),
            rules["minimum_observed_route_ratio"],
        ),
        Check(
            "route_trace:requests",
            isinstance(routed_requests, int)
            and routed_requests >= rules["minimum_routed_requests"],
            routed_requests,
            rules["minimum_routed_requests"],
        ),
        Check(
            "route_trace:errors",
            isinstance(payload.get("error_ratio"), (int, float))
            and payload["error_ratio"] <= rules["maximum_error_ratio"],
            payload.get("error_ratio"),
            rules["maximum_error_ratio"],
        ),
        Check(
            "route_trace:latency",
            isinstance(payload.get("latency_p95_ms"), (int, float))
            and payload["latency_p95_ms"] <= rules["maximum_latency_p95_ms"],
            payload.get("latency_p95_ms"),
            rules["maximum_latency_p95_ms"],
        ),
        Check(
            "route_trace:ownership",
            payload.get("ownership_mode") == rules["ownership_mode"],
            payload.get("ownership_mode"),
            rules["ownership_mode"],
        ),
    ]
    if mode == "sampled_shadow":
        checks.extend(
            [
                Check(
                    "route_trace:no_mutations",
                    payload.get("mutation_count") == 0,
                    payload.get("mutation_count"),
                    0,
                ),
                Check(
                    "route_trace:shadow_money",
                    payload.get("money_mode") == "none",
                    payload.get("money_mode"),
                    "none",
                ),
                Check(
                    "route_trace:shadow_database",
                    payload.get("database_identity") == "none",
                    payload.get("database_identity"),
                    "none",
                ),
                Check(
                    "route_trace:shadow_listener",
                    payload.get("listener") == "offline-replay",
                    payload.get("listener"),
                    "offline-replay",
                ),
                Check(
                    "route_trace:production_listener_binding",
                    payload.get("production_listener")
                    == production_environment.get("listener_identity"),
                    payload.get("production_listener"),
                    production_environment.get("listener_identity"),
                ),
                Check(
                    "route_trace:production_database_binding",
                    payload.get("production_database_identity")
                    == production_environment.get("database_instance_id"),
                    payload.get("production_database_identity"),
                    production_environment.get("database_instance_id"),
                ),
            ]
        )
    if mode == "dedicated_self_route":
        database = payload.get("database_identity")
        production = payload.get("production_database_identity")
        listener = payload.get("listener")
        production_listener = payload.get("production_listener")
        checks.extend(
            [
                Check(
                    "route_trace:all_dedicated_requests",
                    ratio == 1.0,
                    ratio,
                    1.0,
                ),
                Check(
                    "route_trace:separate_database",
                    isinstance(database, str)
                    and bool(database)
                    and isinstance(production, str)
                    and bool(production)
                    and database != production,
                    {"canary": database, "production": production},
                    "distinct non-empty identities",
                ),
                Check(
                    "route_trace:isolated_money",
                    payload.get("money_mode") == "synthetic_isolated",
                    payload.get("money_mode"),
                    "synthetic_isolated",
                ),
                Check(
                    "route_trace:listener",
                    isinstance(listener, str)
                    and bool(listener)
                    and isinstance(production_listener, str)
                    and bool(production_listener)
                    and listener != production_listener,
                    {"canary": listener, "production": production_listener},
                    "distinct non-empty listeners",
                ),
                Check(
                    "route_trace:canary_listener_binding",
                    listener == canary_environment.get("listener_identity")
                    and production_listener
                    == production_environment.get("listener_identity"),
                    {"canary": listener, "production": production_listener},
                    {
                        "canary": canary_environment.get("listener_identity"),
                        "production": production_environment.get(
                            "listener_identity"
                        ),
                    },
                ),
                Check(
                    "route_trace:database_binding",
                    database == canary_environment.get("database_instance_id")
                    and production
                    == production_environment.get("database_instance_id"),
                    {"canary": database, "production": production},
                    {
                        "canary": canary_environment.get("database_instance_id"),
                        "production": production_environment.get(
                            "database_instance_id"
                        ),
                    },
                ),
            ]
        )
    return checks


def _evaluate_load(payload: Mapping[str, Any]) -> list[Check]:
    coverage = payload.get("coverage")
    coverage = coverage if isinstance(coverage, dict) else {}
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
    return [
        _source_check("load", payload),
        Check(
            "load:scheduled_soak",
            payload.get("profile") == "scheduled"
            and isinstance(payload.get("elapsed_seconds"), (int, float))
            and not isinstance(payload.get("elapsed_seconds"), bool)
            and payload["elapsed_seconds"] >= 1_800,
            {
                "profile": payload.get("profile"),
                "elapsed_seconds": payload.get("elapsed_seconds"),
            },
            {"profile": "scheduled", "elapsed_seconds": "at least 1800"},
        ),
        Check(
            "load:commands",
            isinstance(payload.get("command_count"), int)
            and payload["command_count"] > 0
            and payload.get("failed_command_count") == 0,
            {
                "commands": payload.get("command_count"),
                "failed": payload.get("failed_command_count"),
            },
            {"commands": "greater than zero", "failed": 0},
        ),
        Check(
            "load:iterations",
            isinstance(payload.get("iterations"), int) and payload["iterations"] > 0,
            payload.get("iterations"),
            "greater than zero",
        ),
        Check(
            "load:coverage",
            all(coverage.get(name) is True for name in required_coverage),
            {name: coverage.get(name) for name in required_coverage},
            "all true",
        ),
    ]


def _evaluate_differential(payload: Mapping[str, Any]) -> list[Check]:
    targets = payload.get("targets")
    targets = set(targets) if isinstance(targets, list) else set()
    load_elapsed = payload.get("target_load_elapsed_seconds")
    load_elapsed = load_elapsed if isinstance(load_elapsed, dict) else {}
    return [
        _source_check("differential", payload),
        Check(
            "differential:scheduled_soak",
            payload.get("profile") == "scheduled"
            and all(
                isinstance(load_elapsed.get(name), (int, float))
                and not isinstance(load_elapsed.get(name), bool)
                and load_elapsed[name] >= 1_800
                for name in ("go", "rust")
            ),
            {
                "profile": payload.get("profile"),
                "target_load_elapsed_seconds": load_elapsed,
            },
            {
                "profile": "scheduled",
                "target_load_elapsed_seconds": {"go": "at least 1800", "rust": "at least 1800"},
            },
        ),
        Check(
            "differential:targets",
            targets.issuperset({"go", "rust"}),
            sorted(targets),
            ["go", "rust"],
        ),
        Check(
            "differential:comparison",
            payload.get("comparison_passed") is True
            and payload.get("unapproved_differences") == 0,
            {
                "passed": payload.get("comparison_passed"),
                "differences": payload.get("unapproved_differences"),
            },
            {"passed": True, "differences": 0},
        ),
        Check(
            "differential:gates",
            payload.get("gate_failure_count") == 0
            and payload.get("skipped_scenario_count") == 0,
            {
                "failures": payload.get("gate_failure_count"),
                "skipped": payload.get("skipped_scenario_count"),
            },
            {"failures": 0, "skipped": 0},
        ),
    ]


def _live_base_checks(
    payload: Mapping[str, Any],
    rules: Mapping[str, Any],
    health: Mapping[str, Any],
    ready: Mapping[str, Any],
    quiescence: Mapping[str, Any],
    rds: Mapping[str, Any],
) -> list[Check]:
    provenance = _mapping(payload, "provenance")
    evidence_commit = provenance.get("commit")
    runtime_commit = health.get("commit")
    checks = [
        Check(
            "live:traffic_mode",
            payload.get("traffic_mode") == rules["traffic_mode"],
            payload.get("traffic_mode"),
            rules["traffic_mode"],
        ),
        Check(
            "live:minimum_provider_version",
            payload.get("minimum_provider_version") == rules["minimum_provider_version"],
            payload.get("minimum_provider_version"),
            rules["minimum_provider_version"],
        ),
        Check(
            "live:runtime_commit",
            isinstance(evidence_commit, str)
            and len(evidence_commit) == 40
            and all(character in "0123456789abcdef" for character in evidence_commit)
            and runtime_commit == evidence_commit,
            {"runtime": runtime_commit, "evidence": evidence_commit},
            "runtime health commit equals the signed evidence commit",
        ),
        Check(
            "live:runtime_image_digest",
            health.get("image_digest")
            == payload.get("environment_binding", {})
            .get("descriptor", {})
            .get("candidate_image"),
            health.get("image_digest"),
            payload.get("environment_binding", {})
            .get("descriptor", {})
            .get("candidate_image"),
        ),
        Check("live:health", health.get("healthy") is True, health.get("healthy"), True),
        Check("live:ready", ready.get("ready") is True, ready.get("ready"), True),
        Check(
            "live:ownership_health",
            health.get("ownership_healthy") is True
            and ready.get("ownership_healthy") is not False
            and quiescence.get("ownership_healthy") is True,
            {
                "health": health.get("ownership_healthy"),
                "ready": ready.get("ownership_healthy"),
                "quiescence": quiescence.get("ownership_healthy"),
            },
            "health/quiescence true; readiness not false",
        ),
        Check(
            "live:migration_checksum",
            health.get("migration_checksum_valid") is True,
            health.get("migration_checksum_valid"),
            True,
        ),
        Check(
            "live:schema",
            health.get("public_schema_version") == 7
            and health.get("rust_schema_version") == 5,
            {
                "public": health.get("public_schema_version"),
                "rust": health.get("rust_schema_version"),
            },
            {"public": 7, "rust": 5},
        ),
        Check(
            "live:quiescence_observed",
            quiescence.get("observed") is True
            and quiescence.get("supervisor_ready") is True
            and quiescence.get("supervisor_failed") is False,
            quiescence,
            "observed, supervisor ready",
        ),
        Check(
            "live:quiescent",
            not rules.get("require_quiescent", False)
            or quiescence.get("quiescent") is True,
            quiescence.get("quiescent"),
            rules.get("require_quiescent", False),
        ),
        Check(
            "live:rds_read_only",
            rds.get("transaction_read_only") is True
            and rds.get("read_only_role") is True
            and rds.get("role_has_write_privileges") is False
            and rds.get("role_elevated") is False,
            {
                "transaction": rds.get("transaction_read_only"),
                "role": rds.get("read_only_role"),
                "write": rds.get("role_has_write_privileges"),
                "elevated": rds.get("role_elevated"),
            },
            "read-only non-elevated role",
        ),
        Check(
            "live:rds_replica",
            not rules.get("require_read_replica", True)
            or rds.get("is_read_replica") is True,
            rds.get("is_read_replica"),
            rules.get("require_read_replica", True),
        ),
    ]
    if "expected_binary" in rules:
        checks.append(
            Check(
                "live:binary",
                health.get("binary") == rules["expected_binary"],
                health.get("binary"),
                rules["expected_binary"],
            )
        )
    return checks


def _source_checks(
    coordinator: Mapping[str, Any],
    datadog: Mapping[str, Any],
    queries: Mapping[str, Any],
) -> list[Check]:
    coordinator_dates = coordinator.get("response_dates")
    coordinator_dates = coordinator_dates if isinstance(coordinator_dates, dict) else {}
    coordinator_sources = {
        name
        for name, value in coordinator_dates.items()
        if name in COORDINATOR_EVIDENCE_SOURCES and isinstance(value, str) and value
    }
    datadog_dates = datadog.get("response_dates")
    datadog_dates = datadog_dates if isinstance(datadog_dates, list) else []
    valid_datadog_dates = all(isinstance(value, str) and value for value in datadog_dates)
    return [
        Check(
            "live:coordinator_response_dates",
            coordinator_sources == COORDINATOR_EVIDENCE_SOURCES
            and len(coordinator_dates) == len(COORDINATOR_EVIDENCE_SOURCES),
            sorted(coordinator_sources),
            sorted(COORDINATOR_EVIDENCE_SOURCES),
        ),
        Check(
            "live:datadog_site",
            datadog.get("site") in DATADOG_SITES,
            datadog.get("site"),
            sorted(DATADOG_SITES),
        ),
        Check(
            "live:datadog_response_dates",
            valid_datadog_dates and len(datadog_dates) == len(queries) and bool(queries),
            len(datadog_dates),
            len(queries),
        ),
        Check(
            "live:datadog_organization_response_date",
            isinstance(datadog.get("organization_response_date"), str)
            and bool(datadog.get("organization_response_date")),
            datadog.get("organization_response_date"),
            "authenticated current-user response Date",
        ),
    ]


def _durable_checks(
    durable: Mapping[str, Any],
    rds: Mapping[str, Any],
    rules: Mapping[str, Any],
) -> list[Check]:
    checks: list[Check] = []
    for name in (
        "review_pending",
        "sent_unknown",
        "pending_terminals",
        "pending_external",
        "pending_outbox",
        "pending_fees",
        "fee_projection",
    ):
        checks.append(
            Check(f"live:coordinator:{name}", durable.get(name) == 0, durable.get(name), 0)
        )
        checks.append(Check(f"live:rds:{name}", rds.get(name) == 0, rds.get(name), 0))
    checks.extend(
        [
            Check(
                "live:rds:external_unknown",
                rds.get("external_unknown") == 0,
                rds.get("external_unknown"),
                0,
            ),
            Check(
                "live:rds:rollback_guard",
                rds.get("rollback_unresolved") == 0,
                rds.get("rollback_unresolved"),
                0,
            ),
            Check(
                "live:coordinator:rollback_guard",
                durable.get("rollback_unresolved") == 0
                and durable.get("go_fallback_safe") is True,
                {
                    "unresolved": durable.get("rollback_unresolved"),
                    "go_fallback_safe": durable.get("go_fallback_safe"),
                },
                {"unresolved": 0, "go_fallback_safe": True},
            ),
        ]
    )
    if rules.get("require_historical_terminal_ack", False):
        historical_acks = rds.get("historical_terminal_acks")
        checks.append(
            Check(
                "live:rds:historical_terminal_acks",
                isinstance(historical_acks, int) and historical_acks > 0,
                historical_acks,
                "greater than zero",
            )
        )
    if rules.get("require_zero_go_mutations_90d", False):
        checks.extend(
            [
                Check(
                    "live:rds:go_mutation_writes",
                    rds.get("go_db_mutation_writes") == 0,
                    rds.get("go_db_mutation_writes"),
                    0,
                ),
                Check(
                    "live:rds:go_background_writes",
                    rds.get("go_background_writes") == 0,
                    rds.get("go_background_writes"),
                    0,
                ),
                Check(
                    "live:rds:go_financial_writes",
                    rds.get("go_financial_writes") == 0,
                    rds.get("go_financial_writes"),
                    0,
                ),
                Check(
                    "live:rds:go_ownership_epochs",
                    rds.get("go_ownership_epochs") == 0,
                    rds.get("go_ownership_epochs"),
                    0,
                ),
                Check(
                    "live:rds:go_sessions",
                    rds.get("go_sessions") == 0,
                    rds.get("go_sessions"),
                    0,
                ),
                Check(
                    "live:rds:unknown_ownership_epochs",
                    rds.get("unknown_ownership_epochs") == 0,
                    rds.get("unknown_ownership_epochs"),
                    0,
                ),
                Check(
                    "live:rds:go_audit_coverage",
                    rds.get("go_audit_coverage_complete") is True,
                    rds.get("go_audit_coverage_complete"),
                    True,
                ),
                Check(
                    "live:rds:go_audit_trigger_states",
                    rds.get("go_audit_trigger_states_valid") is True,
                    rds.get("go_audit_trigger_states_valid"),
                    True,
                ),
                Check(
                    "live:rds:go_audit_definition_hashes",
                    rds.get("go_audit_definition_hashes_valid") is True,
                    rds.get("go_audit_definition_hashes_valid"),
                    True,
                ),
                Check(
                    "live:rds:go_audit_owner_coverage",
                    rds.get("go_audit_owner_coverage_complete") is True,
                    rds.get("go_audit_owner_coverage_complete"),
                    True,
                ),
            ]
        )
    return checks


def _provider_checks(
    coverage: Mapping[str, Any],
    rules: Mapping[str, Any],
) -> list[Check]:
    total = coverage.get("total")
    v1 = coverage.get("protocol_v1")
    v2 = coverage.get("protocol_v2")
    v2_inference_eligible = coverage.get("protocol_v2_inference_eligible")
    counts_conclusive = (
        isinstance(total, int)
        and total > 0
        and isinstance(v1, int)
        and isinstance(v2, int)
        and v1 + v2 == total
    )
    fraction = v2 / total if counts_conclusive else None
    return [
        Check(
            "live:provider_count",
            isinstance(total, int) and total > 0,
            total,
            "greater than zero",
        ),
        Check(
            "live:provider_protocol_coverage",
            counts_conclusive,
            {"total": total, "v1": v1, "v2": v2},
            "v1 + v2 = total",
        ),
        Check(
            "live:provider_v2_fraction",
            fraction is not None and fraction >= rules["minimum_v2_fraction"],
            fraction,
            rules["minimum_v2_fraction"],
        ),
        Check(
            "live:provider_v2_inference_eligible",
            isinstance(v2, int)
            and isinstance(v2_inference_eligible, int)
            and v2_inference_eligible == v2,
            v2_inference_eligible,
            v2,
        ),
        Check(
            "live:provider_v1_policy",
            rules.get("allow_v1", True) or v1 == 0,
            v1,
            0 if not rules.get("allow_v1", True) else "allowed",
        ),
        Check(
            "live:provider_hardware_trust",
            coverage.get("hardware") == total
            and isinstance(total, int)
            and total > 0,
            coverage.get("hardware"),
            total,
        ),
        Check(
            "live:provider_version_known",
            coverage.get("versions_known") == total
            and isinstance(total, int)
            and total > 0,
            coverage.get("versions_known"),
            total,
        ),
        Check(
            "live:provider_version_floor",
            coverage.get("at_or_above_floor") == total
            and isinstance(total, int)
            and total > 0,
            coverage.get("at_or_above_floor"),
            total,
        ),
    ]


def _datadog_checks(
    queries: Mapping[str, Any],
    policy: Mapping[str, Any],
) -> list[Check]:
    checks: list[Check] = []
    rules = {
        "availability_5xx_ratio": (
            "maximum",
            policy.get("maximum_error_ratio", 0.02),
        ),
        "ownership_healthy": ("minimum", 1),
        "migration_checksum_valid": ("minimum", 1),
        "external_unknown": ("maximum", 0),
        "review_pending": ("maximum", 0),
        "pending_outbox": ("maximum", 0),
        "pending_fees": ("maximum", 0),
        "request_count": ("minimum", policy.get("minimum_requests", 1)),
        "latency_p95_ms": (
            "maximum",
            policy.get("maximum_latency_p95_ms", 30_000),
        ),
    }
    for name, (comparison, limit) in rules.items():
        result = queries.get(name)
        value = result.get("value") if isinstance(result, dict) else None
        passed = (
            isinstance(value, (int, float))
            and not isinstance(value, bool)
            and (value <= limit if comparison == "maximum" else value >= limit)
        )
        checks.append(Check(f"live:datadog:{name}", passed, value, {comparison: limit}))
    return checks


def _definition_checks(
    datadog: Mapping[str, Any],
    rds: Mapping[str, Any],
    rules: Mapping[str, Any],
) -> list[Check]:
    datadog_path = rules.get("datadog_query_path")
    sql_path = rules.get("rds_query_path")
    datadog_file = ROOT / str(datadog_path) if isinstance(datadog_path, str) else None
    sql_file = ROOT / str(sql_path) if isinstance(sql_path, str) else None
    expected_datadog = (
        sha256_file(datadog_file)
        if datadog_file is not None and datadog_file.is_file()
        else None
    )
    expected_sql = (
        sha256_file(sql_file) if sql_file is not None and sql_file.is_file() else None
    )
    return [
        Check(
            "live:datadog_query_definition",
            expected_datadog is not None
            and datadog.get("query_definition_sha256") == expected_datadog,
            datadog.get("query_definition_sha256"),
            expected_datadog,
        ),
        Check(
            "live:rds_query_definition",
            expected_sql is not None
            and rds.get("query_definition_sha256") == expected_sql,
            rds.get("query_definition_sha256"),
            expected_sql,
        ),
    ]


def _evaluate_bake(payload: Mapping[str, Any], rules: Mapping[str, Any]) -> list[Check]:
    started = parse_timestamp(payload.get("window_started_at"), "window_started_at")
    ended = parse_timestamp(payload.get("window_ended_at"), "window_ended_at")
    duration = (ended - started).total_seconds()
    provenance = _mapping(payload, "provenance")
    checks = [
        Check("bake:gate", payload.get("gate") == rules["gate"], payload.get("gate"), rules["gate"]),
        Check(
            "bake:source_commit",
            payload.get("source_commit") == provenance.get("commit"),
            payload.get("source_commit"),
            provenance.get("commit"),
        ),
        Check("bake:window_order", ended > started, duration, "positive"),
        Check(
            "bake:fixed_interval",
            isinstance(payload.get("interval_seconds"), int)
            and payload["interval_seconds"] > 0
            and duration
            == payload["interval_seconds"] * payload.get("samples", 0),
            payload.get("interval_seconds"),
            "positive and exactly tiles the observation window",
        ),
        Check(
            "bake:duration",
            duration >= rules["minimum_duration_seconds"],
            duration,
            rules["minimum_duration_seconds"],
        ),
        Check(
            "bake:traffic_mode",
            payload.get("traffic_mode") == rules["traffic_mode"],
            payload.get("traffic_mode"),
            rules["traffic_mode"],
        ),
        Check(
            "bake:maximum_gap",
            isinstance(payload.get("maximum_gap_seconds"), (int, float))
            and payload["maximum_gap_seconds"] <= rules["maximum_gap_seconds"],
            payload.get("maximum_gap_seconds"),
            rules["maximum_gap_seconds"],
        ),
        Check(
            "bake:samples",
            isinstance(payload.get("samples"), int)
            and payload["samples"] >= rules["minimum_samples"],
            payload.get("samples"),
            rules["minimum_samples"],
        ),
        Check(
            "bake:requests",
            isinstance(payload.get("requests"), (int, float))
            and payload["requests"] >= rules["minimum_requests"],
            payload.get("requests"),
            rules["minimum_requests"],
        ),
        Check(
            "bake:unique_requests",
            isinstance(payload.get("unique_requests"), int)
            and not isinstance(payload.get("unique_requests"), bool)
            and payload["unique_requests"]
            >= rules.get("minimum_unique_requests", rules["minimum_requests"]),
            payload.get("unique_requests"),
            rules.get("minimum_unique_requests", rules["minimum_requests"]),
        ),
        Check(
            "bake:error_ratio",
            isinstance(payload.get("maximum_error_ratio"), (int, float))
            and payload["maximum_error_ratio"] <= rules["maximum_error_ratio"],
            payload.get("maximum_error_ratio"),
            rules["maximum_error_ratio"],
        ),
        Check(
            "bake:latency_p95",
            isinstance(payload.get("maximum_latency_p95_ms"), (int, float))
            and payload["maximum_latency_p95_ms"] <= rules["maximum_latency_p95_ms"],
            payload.get("maximum_latency_p95_ms"),
            rules["maximum_latency_p95_ms"],
        ),
        Check(
            "bake:durable_states",
            payload.get("maximum_durable_pending") == 0,
            payload.get("maximum_durable_pending"),
            0,
        ),
        Check(
            "bake:incidents",
            payload.get("gate_incidents") == 0,
            payload.get("gate_incidents"),
            0,
        ),
        Check(
            "bake:rollbacks",
            payload.get("rollbacks") == 0,
            payload.get("rollbacks"),
            0,
        ),
        Check(
            "bake:continuous_pass",
            payload.get("continuous_pass") is True,
            payload.get("continuous_pass"),
            True,
        ),
    ]
    if rules.get("require_zero_go_mutations_90d", False):
        checks.extend(
            [
                Check(
                    "bake:go_mutations_90d",
                    payload.get("maximum_go_mutations_90d") == 0,
                    payload.get("maximum_go_mutations_90d"),
                    0,
                ),
                Check(
                    "bake:go_background_writes",
                    payload.get("go_background_writes") == 0,
                    payload.get("go_background_writes"),
                    0,
                ),
                Check(
                    "bake:go_financial_writes",
                    payload.get("go_financial_writes") == 0,
                    payload.get("go_financial_writes"),
                    0,
                ),
                Check(
                    "bake:go_ownership_epochs",
                    payload.get("go_ownership_epochs") == 0,
                    payload.get("go_ownership_epochs"),
                    0,
                ),
                Check(
                    "bake:go_sessions",
                    payload.get("go_sessions") == 0,
                    payload.get("go_sessions"),
                    0,
                ),
                Check(
                    "bake:unknown_ownership_epochs",
                    payload.get("unknown_ownership_epochs") == 0,
                    payload.get("unknown_ownership_epochs"),
                    0,
                ),
                Check(
                    "bake:go_audit_coverage",
                    payload.get("go_audit_coverage_complete") is True,
                    payload.get("go_audit_coverage_complete"),
                    True,
                ),
                Check(
                    "bake:go_audit_trigger_states",
                    payload.get("go_audit_trigger_states_valid") is True,
                    payload.get("go_audit_trigger_states_valid"),
                    True,
                ),
                Check(
                    "bake:go_audit_definition_hashes",
                    payload.get("go_audit_definition_hashes_valid") is True,
                    payload.get("go_audit_definition_hashes_valid"),
                    True,
                ),
                Check(
                    "bake:go_audit_owner_coverage",
                    payload.get("go_audit_owner_coverage_complete") is True,
                    payload.get("go_audit_owner_coverage_complete"),
                    True,
                ),
            ]
        )
    return checks


def _provenance_checks(payload: Mapping[str, Any]) -> list[Check]:
    provenance = payload.get("provenance")
    provenance = provenance if isinstance(provenance, dict) else {}
    commit = provenance.get("commit")
    tool_manifest = [
        {"path": str(path.relative_to(ROOT)), "sha256": sha256_file(path)}
        for path in sorted((ROOT / "scripts/cutover_readiness").glob("*.py"))
    ]
    expected_tool_manifest = sha256_bytes(canonical_bytes(tool_manifest))
    expected_report_schema = sha256_file(EVIDENCE_SCHEMA)
    base_valid = (
        provenance.get("repository") == "Layr-Labs/d-inference"
        and provenance.get("kind") in {"github_actions", "local_operator"}
        and provenance.get("tool_version") == TOOL_VERSION
        and provenance.get("report_schema_version") == SCHEMA_VERSION
        and isinstance(commit, str)
        and len(commit) == 40
        and all(character in "0123456789abcdef" for character in commit)
        and provenance.get("tool_manifest_sha256") == expected_tool_manifest
        and provenance.get("report_schema_sha256") == expected_report_schema
    )
    github_valid = provenance.get("kind") != "github_actions" or all(
        isinstance(provenance.get(name), str) and bool(provenance.get(name))
        for name in (
            "run_id",
            "run_attempt",
            "workflow",
            "workflow_ref",
            "workflow_sha",
            "ref",
            "ref_protected",
            "event_name",
        )
    )
    if provenance.get("kind") == "github_actions":
        github_valid = (
            github_valid
            and provenance.get("workflow_sha") == commit
            and provenance.get("ref") == "refs/heads/master"
            and provenance.get("ref_protected") == "true"
            and provenance.get("event_name") in {"schedule", "workflow_dispatch"}
            and provenance.get("workflow_ref", "").endswith(
                f"@{provenance.get('ref')}"
            )
        )
    return [
        Check(
            "provenance:repository_tool_schema",
            base_valid,
            provenance,
            {
                "repository": "Layr-Labs/d-inference",
                "tool_version": TOOL_VERSION,
                "tool_manifest_sha256": expected_tool_manifest,
                "report_schema_version": SCHEMA_VERSION,
                "report_schema_sha256": expected_report_schema,
            },
        ),
        Check(
            "provenance:github_run",
            github_valid,
            provenance.get("kind"),
            "complete when generated in GitHub Actions",
        ),
    ]


def _immutable_digest(value: Any) -> bool:
    if not isinstance(value, str):
        return False
    digest = value.rsplit("@sha256:", 1)[-1] if "@sha256:" in value else value.removeprefix("sha256:")
    return len(digest) == 64 and all(character in "0123456789abcdef" for character in digest)


def _source_check(prefix: str, payload: Mapping[str, Any]) -> Check:
    source = payload.get("source")
    digest = source.get("sha256") if isinstance(source, dict) else None
    valid = (
        isinstance(digest, str)
        and len(digest) == 64
        and all(character in "0123456789abcdef" for character in digest)
    )
    return Check(f"{prefix}:source", valid, digest, "64-character SHA-256")


def _mapping(value: Mapping[str, Any], name: str) -> Mapping[str, Any]:
    item = value.get(name)
    return item if isinstance(item, dict) else {}

