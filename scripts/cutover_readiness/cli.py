from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Mapping, Sequence

from .clients import (
    DATADOG_API_BASES,
    ReadOnlyClientError,
    collect_coordinator,
    collect_datadog,
    load_secret,
)
from .environment import (
    EnvironmentBindingError,
    payload_binding,
    validate_descriptor,
    validate_manifest,
    validate_payload_binding,
)
from .evaluators import evaluate_live, evaluate_report
from .gates import (
    GateError,
    KEYLESS_EVIDENCE_WORKFLOWS,
    approval_signing_payload,
    assess_gate,
    authorize_gate,
    create_approval_request,
    finalize_approval,
    load_policy,
    verify_authorization_bundle,
)
from .integrity import (
    IntegrityError,
    load_json,
    parse_timestamp,
    public_key_id,
    sha256_file,
    utc_now,
    verify_keyless_evidence,
    write_json,
)
from .rds import collect_rds
from .reports import (
    CheckExecutionError,
    _evidence_provenance,
    import_fault_matrix_report,
    import_pilot_report,
    import_route_trace,
    new_report,
    run_check,
    validate_report,
)


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_POLICY = ROOT / "deploy/cutover/gates.json"
DEFAULT_DATADOG_QUERIES = ROOT / "deploy/cutover/datadog-queries.json"
CANARY_DATADOG_QUERIES = ROOT / "deploy/cutover/datadog-queries-canary.json"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Read-only, fail-closed Rust coordinator cutover evidence",
    )
    commands = parser.add_subparsers(dest="command", required=True)

    import_pilot = commands.add_parser(
        "import-pilot",
        help="Seal a component-load or paired-differential pilot report",
    )
    import_pilot.add_argument("--source", type=Path, required=True)
    _environment_arguments(import_pilot)
    _output_and_key(import_pilot)

    import_fault = commands.add_parser(
        "import-fault",
        help="Verify signed executable fault receipts and seal cutover evidence",
    )
    import_fault.add_argument("--source", type=Path, required=True)
    import_fault.add_argument("--trusted-receipt-key", type=Path, required=True)
    _environment_arguments(import_fault)
    _output_and_key(import_fault)

    route_trace = commands.add_parser(
        "import-route-trace",
        help="Compute and seal observed shadow or dedicated-canary routing evidence",
    )
    route_trace.add_argument("--source", type=Path, required=True)
    route_trace.add_argument("--environment", choices=("isolated", "canary"), required=True)
    _environment_arguments(route_trace)
    _output_and_key(route_trace)

    run = commands.add_parser("run-check", help="Run one isolated check and seal its result")
    run.add_argument("--name", required=True)
    run.add_argument("--coverage", action="append", default=[])
    run.add_argument("--timeout-seconds", type=int, default=3600)
    run.add_argument("--environment", choices=("isolated", "development"), default="isolated")
    _environment_arguments(run)
    _output_and_key(run)
    run.add_argument("check_command", nargs=argparse.REMAINDER)

    live = commands.add_parser("collect-live", help="Collect GET-only and RDS read-only evidence")
    live.add_argument(
        "--environment",
        choices=("canary", "development", "production"),
        required=True,
    )
    live.add_argument("--base-url", required=True)
    live.add_argument("--ops-read-key-file", type=Path, required=True)
    live.add_argument("--public-key-file", type=Path, required=True)
    live.add_argument("--datadog-site", choices=tuple(DATADOG_API_BASES), required=True)
    live.add_argument("--datadog-api-key-file", type=Path, required=True)
    live.add_argument("--datadog-application-key-file", type=Path, required=True)
    live.add_argument("--datadog-api-base")
    live.add_argument("--rds-dsn-file", type=Path, required=True)
    live.add_argument("--rds-writer-endpoint", required=True)
    live.add_argument("--minimum-provider-version", required=True)
    live.add_argument("--window-start", required=True)
    live.add_argument("--window-end", required=True)
    live.add_argument("--production-read-only-ack")
    live.add_argument("--fixture", action="store_true")
    _environment_arguments(live)
    _output_and_key(live)

    bake = commands.add_parser("build-bake", help="Build a continuous bake observation")
    bake.add_argument("--live-report", type=Path, action="append", default=[])
    bake.add_argument("--live-report-manifest", type=Path)
    bake.add_argument(
        "--gate",
        choices=("bake-24h", "bake-7d", "bake-30d", "bake-90d"),
        required=True,
    )
    bake.add_argument("--policy", type=Path, default=DEFAULT_POLICY)
    bake.add_argument("--trusted-collector-key", action="append", required=True)
    _output_and_key(bake)

    inventory = commands.add_parser(
        "import-retirement-inventory",
        help="Seal a reviewed Go-retirement inventory",
    )
    inventory.add_argument("--source", type=Path, required=True)
    inventory.add_argument("--environment", choices=("development", "production"), required=True)
    _environment_arguments(inventory)
    _output_and_key(inventory)

    manifest = commands.add_parser(
        "create-environment-manifest",
        help="Seal one reviewed canonical target shared by every evidence source",
    )
    manifest.add_argument("--source", type=Path, required=True)
    manifest.add_argument("--signing-key", type=Path, required=True)
    manifest.add_argument("--output", type=Path, required=True)

    verify_manifest = commands.add_parser(
        "verify-environment-manifest",
        help="Verify a signed canonical environment target",
    )
    verify_manifest.add_argument("--manifest", type=Path, required=True)
    verify_manifest.add_argument("--trusted-key", action="append", required=True)

    assess = commands.add_parser("assess", help="Evaluate a gate without mutating production")
    assess.add_argument("--gate", required=True)
    assess.add_argument("--policy", type=Path, default=DEFAULT_POLICY)
    assess.add_argument("--report", type=Path, action="append", default=[])
    assess.add_argument("--prior", type=Path, action="append", default=[])
    assess.add_argument("--signing-key", type=Path, required=True)
    assess.add_argument("--trusted-gate-key", action="append", default=[])
    assess.add_argument("--trusted-evidence-key", action="append", default=[])
    assess.add_argument("--commit")
    assess.add_argument("--candidate-image")
    assess.add_argument("--fallback-image")
    assess.add_argument("--output", type=Path, required=True)

    prepare = commands.add_parser(
        "prepare-approval",
        help="Interactively prepare bytes for an offline or hardware signer",
    )
    prepare.add_argument("--assessment", type=Path, required=True)
    prepare.add_argument("--approver", required=True)
    prepare.add_argument("--approver-key-id", required=True)
    prepare.add_argument("--trusted-gate-key", action="append", required=True)
    prepare.add_argument("--trusted-approver-key", action="append", required=True)
    prepare.add_argument("--output", type=Path, required=True)
    prepare.add_argument("--payload-output", type=Path, required=True)

    finalize = commands.add_parser(
        "finalize-approval",
        help="Verify and attach an offline or hardware signature",
    )
    finalize.add_argument("--request", type=Path, required=True)
    finalize.add_argument("--signature", type=Path, required=True)
    finalize.add_argument("--trusted-approver-key", action="append", required=True)
    finalize.add_argument("--output", type=Path, required=True)

    authorize = commands.add_parser(
        "authorize",
        help="Bind a passing assessment to a trusted human approval",
    )
    authorize.add_argument("--assessment", type=Path, required=True)
    authorize.add_argument("--approval", type=Path, required=True)
    authorize.add_argument("--policy", type=Path, default=DEFAULT_POLICY)
    authorize.add_argument("--prior", type=Path, action="append", default=[])
    authorize.add_argument("--signing-key", type=Path, required=True)
    authorize.add_argument("--trusted-gate-key", action="append", required=True)
    authorize.add_argument("--trusted-approver-key", action="append", required=True)
    authorize.add_argument("--output", type=Path, required=True)

    verify = commands.add_parser("verify", help="Verify a signed evidence document")
    verify.add_argument("--report", type=Path, required=True)
    verify.add_argument("--trusted-key", action="append", required=True)
    verify.add_argument("--expected-type")
    verify_unsigned = commands.add_parser(
        "verify-unsigned-hash",
        help="Verify only the canonical hash of a pre-signer CI report",
    )
    verify_unsigned.add_argument("--report", type=Path, required=True)
    verify_unsigned.add_argument("--expected-type", required=True)
    verify_keyless = commands.add_parser(
        "verify-keyless-evidence",
        help="Verify Sigstore and GitHub attestations for an unsigned report",
    )
    verify_keyless.add_argument("--report", type=Path, required=True)
    verify_deploy = commands.add_parser(
        "verify-deploy-authorization",
        help="Verify one self-contained full-cutover authorization",
    )
    verify_deploy.add_argument("--authorization", type=Path, required=True)
    verify_deploy.add_argument("--policy", type=Path, default=DEFAULT_POLICY)
    verify_deploy.add_argument("--trusted-gate-key", action="append", required=True)
    verify_deploy.add_argument("--trusted-approver-key", action="append", required=True)
    verify_deploy.add_argument("--commit", required=True)
    verify_deploy.add_argument("--candidate-image", required=True)
    verify_deploy.add_argument("--fallback-image", required=True)
    return parser


def main(arguments: Sequence[str] | None = None) -> int:
    parser = build_parser()
    options = parser.parse_args(arguments)
    try:
        return _dispatch(options)
    except (
        IntegrityError,
        GateError,
        ReadOnlyClientError,
        EnvironmentBindingError,
        ValueError,
    ) as error:
        print(f"cutover-readiness: {error}", file=sys.stderr)
        return 2


def _dispatch(options: argparse.Namespace) -> int:
    if options.command == "create-environment-manifest":
        descriptor = validate_descriptor(load_json(options.source))
        report = new_report(
            "environment_manifest",
            "production",
            {"environment_binding": payload_binding(descriptor)},
            "pass",
            validity=timedelta(days=1),
            signing_key=options.signing_key,
        )
        write_json(options.output, report)
        return 0

    if options.command == "verify-environment-manifest":
        binding = validate_manifest(
            load_json(options.manifest),
            trusted_keys=_trusted_keys(options.trusted_key),
        )
        print(
            json.dumps(
                {"valid": True, "environment_id": binding["environment_id"]},
                sort_keys=True,
            )
        )
        return 0

    if options.command == "import-pilot":
        report = import_pilot_report(
            options.source,
            environment_binding=_environment_binding(options),
            signing_key=options.signing_key,
        )
        write_json(options.output, report)
        return 0 if report["verdict"] == "pass" else 2

    if options.command == "import-fault":
        report = import_fault_matrix_report(
            options.source,
            trusted_receipt_key=options.trusted_receipt_key,
            environment_binding=_environment_binding(options),
            signing_key=options.signing_key,
        )
        write_json(options.output, report)
        return 0

    if options.command == "import-route-trace":
        report = import_route_trace(
            options.source,
            environment=options.environment,
            environment_binding=_environment_binding(options),
            signing_key=options.signing_key,
        )
        write_json(options.output, report)
        return 0

    if options.command == "run-check":
        command = list(options.check_command)
        if command and command[0] == "--":
            command = command[1:]
        try:
            report, completed = run_check(
                options.name,
                command,
                coverage=options.coverage,
                environment_binding=_environment_binding(options),
                environment=options.environment,
                signing_key=options.signing_key,
                timeout_seconds=options.timeout_seconds,
            )
        except CheckExecutionError as error:
            write_json(options.output, error.report)
            return 2
        write_json(options.output, report)
        options.output.with_suffix(options.output.suffix + ".stdout.log").write_bytes(
            completed.stdout
        )
        options.output.with_suffix(options.output.suffix + ".stderr.log").write_bytes(
            completed.stderr
        )
        return 0 if completed.returncode == 0 else completed.returncode or 2

    if options.command == "collect-live":
        environment_binding = _environment_binding(options)
        window_started_at = parse_timestamp(options.window_start, "window_start")
        window_ended_at = parse_timestamp(options.window_end, "window_end")
        if window_ended_at <= window_started_at:
            raise ValueError("collection window end must be after start")
        fixture = options.fixture
        if fixture and options.environment != "development":
            raise ValueError("fixture collection must use the development environment")
        if (
            options.environment == "production"
            and options.base_url.rstrip("/") != "https://api.darkbloom.dev"
        ):
            raise ValueError(
                "production evidence must use the canonical https://api.darkbloom.dev origin"
            )
        if options.environment in {"canary", "production"} and options.signing_key is None:
            raise ValueError("canary and production live evidence must be signed")
        coordinator = collect_coordinator(
            options.base_url,
            ops_read_key=load_secret(
                options.ops_read_key_file,
                allow_fixture_permissions=fixture,
            ),
            public_key=load_secret(
                options.public_key_file,
                allow_fixture_permissions=fixture,
            ),
            minimum_provider_version=options.minimum_provider_version,
            environment_binding=environment_binding,
            environment=options.environment,
            fixture=fixture,
            production_acknowledgement=options.production_read_only_ack,
        )
        query_path = (
            CANARY_DATADOG_QUERIES
            if options.environment == "canary"
            else DEFAULT_DATADOG_QUERIES
        )
        query_document = load_json(query_path)
        if query_document.get("schema_version") != 1 or not isinstance(
            query_document.get("queries"), list
        ):
            raise ValueError("Datadog query policy must be schema_version 1")
        datadog = collect_datadog(
            options.datadog_site,
            query_document["queries"],
            api_key=load_secret(
                options.datadog_api_key_file,
                allow_fixture_permissions=fixture,
            ),
            application_key=load_secret(
                options.datadog_application_key_file,
                allow_fixture_permissions=fixture,
            ),
            api_base_override=options.datadog_api_base,
            environment_binding=environment_binding,
            environment=options.environment,
            window_start=window_started_at,
            window_end=window_ended_at,
            fixture=fixture,
        )
        datadog["query_definition_sha256"] = sha256_file(query_path)
        rds = collect_rds(
            options.rds_dsn_file,
            environment_binding=environment_binding,
            environment=options.environment,
            window_start=window_started_at,
            window_end=window_ended_at,
            writer_endpoint=options.rds_writer_endpoint,
            fixture=fixture,
            require_replica=options.environment == "production",
        )
        payload = {
            "traffic_mode": {
                "canary": "dedicated_self_route",
                "development": "development",
                "production": "atomic_single_owner",
            }[options.environment],
            "minimum_provider_version": options.minimum_provider_version,
            "coordinator": coordinator,
            "datadog": datadog,
            "rds": rds,
            "environment_binding": environment_binding,
            "window_started_at": options.window_start,
            "window_ended_at": options.window_end,
        }
        report = new_report(
            "live_snapshot",
            options.environment,
            payload,
            "pass",
            validity=timedelta(minutes=15),
            signing_key=options.signing_key,
        )
        write_json(options.output, report)
        return 0

    if options.command == "build-bake":
        policy = load_policy(options.policy)
        gate_policy = policy["gates"][options.gate]
        environment = gate_policy["environment"]
        if environment in {"canary", "production"} and options.signing_key is None:
            raise ValueError("canary and production bake evidence must be signed")
        live_reports = list(options.live_report)
        if options.live_report_manifest is not None:
            manifest = load_json(options.live_report_manifest)
            if manifest.get("schema_version") != 1 or not isinstance(
                manifest.get("reports"), list
            ):
                raise ValueError("bake manifest must contain schema_version 1 and reports")
            for value in manifest["reports"]:
                if not isinstance(value, str) or not value:
                    raise ValueError("bake manifest report paths must be non-empty strings")
                path = Path(value)
                live_reports.append(
                    path
                    if path.is_absolute()
                    else options.live_report_manifest.parent / path
                )
        if not live_reports:
            raise ValueError("build-bake requires live reports or a report manifest")
        report = _build_bake(
            live_reports,
            options.gate,
            environment,
            gate_policy["reports"]["bake_observation"],
            gate_policy["reports"]["live_snapshot"],
            options.signing_key,
            _trusted_keys(options.trusted_collector_key),
        )
        write_json(options.output, report)
        return 0 if report["verdict"] == "pass" else 2

    if options.command == "import-retirement-inventory":
        if options.environment == "production" and options.signing_key is None:
            raise ValueError("production retirement inventory must be signed")
        source = load_json(options.source)
        if source.get("schema_version") != 1 or not isinstance(source.get("checks"), dict):
            raise ValueError("retirement inventory must contain schema_version 1 and checks")
        report = new_report(
            "retirement_inventory",
            options.environment,
            {
                **source["checks"],
                "environment_binding": _environment_binding(options),
            },
            "pass" if all(value is True for value in source["checks"].values()) else "fail",
            validity=timedelta(days=1),
            signing_key=options.signing_key,
        )
        write_json(options.output, report)
        return 0 if report["verdict"] == "pass" else 2

    if options.command == "assess":
        trusted = _trusted_keys(options.trusted_gate_key)
        assessment = assess_gate(
            options.gate,
            options.policy,
            options.report,
            options.prior,
            signing_key=options.signing_key,
            trusted_gate_keys=trusted,
            trusted_evidence_keys=_trusted_keys(options.trusted_evidence_key),
            deployment_target=_deployment_target_options(options),
        )
        write_json(options.output, assessment)
        return 0 if assessment["verdict"] == "pass" else 2

    if options.command == "prepare-approval":
        assessment = load_json(options.assessment)
        digest = validate_report(
            assessment,
            expected_type="gate_assessment",
            trusted_keys=_trusted_keys(options.trusted_gate_key),
            require_signature=True,
        )
        gate = assessment.get("payload", {}).get("gate")
        expected = f"APPROVE {gate} {digest}"
        print(f"Type exactly: {expected}")
        confirmation = input("approval> ")
        request = create_approval_request(
            assessment,
            trusted_gate_keys=_trusted_keys(options.trusted_gate_key),
            trusted_approver_keys=_trusted_keys(options.trusted_approver_key),
            approver_key_id=options.approver_key_id,
            approver=options.approver,
            confirmation=confirmation,
        )
        write_json(options.output, request)
        options.payload_output.write_bytes(approval_signing_payload(request))
        return 0

    if options.command == "finalize-approval":
        approval = finalize_approval(
            load_json(options.request),
            signature=options.signature.read_bytes(),
            trusted_approver_keys=_trusted_keys(options.trusted_approver_key),
        )
        write_json(options.output, approval)
        return 0

    if options.command == "authorize":
        authorization = authorize_gate(
            load_json(options.assessment),
            load_json(options.approval),
            policy_path=options.policy,
            predecessor_authorizations=[load_json(path) for path in options.prior],
            trusted_gate_keys=_trusted_keys(options.trusted_gate_key),
            trusted_approver_keys=_trusted_keys(options.trusted_approver_key),
            signing_key=options.signing_key,
        )
        write_json(options.output, authorization)
        return 0

    if options.command == "verify-deploy-authorization":
        digest = verify_authorization_bundle(
            load_json(options.authorization),
            policy_path=options.policy,
            trusted_gate_keys=_trusted_keys(options.trusted_gate_key),
            trusted_approver_keys=_trusted_keys(options.trusted_approver_key),
            expected_gate="full-cutover",
            expected_environment="production",
            expected_target={
                "commit": options.commit,
                "candidate_image": options.candidate_image,
                "fallback_image": options.fallback_image,
            },
        )
        print(json.dumps({"valid": True, "canonical_sha256": digest}, sort_keys=True))
        return 0

    if options.command == "verify":
        report = load_json(options.report)
        digest = validate_report(
            report,
            expected_type=options.expected_type,
            trusted_keys=_trusted_keys(options.trusted_key),
            require_signature=True,
        )
        print(
            json.dumps(
                {
                    "schema_version": report["schema_version"],
                    "report_type": report["report_type"],
                    "canonical_sha256": digest,
                    "valid": True,
                },
                sort_keys=True,
            )
        )
        return 0
    if options.command == "verify-unsigned-hash":
        report = load_json(options.report)
        if report.get("integrity", {}).get("signature") is not None:
            raise IntegrityError("pre-signer report must remain unsigned")
        digest = validate_report(
            report,
            expected_type=options.expected_type,
            require_signature=False,
        )
        print(json.dumps({"valid": True, "canonical_sha256": digest}, sort_keys=True))
        return 0
    if options.command == "verify-keyless-evidence":
        report = load_json(options.report)
        workflow = KEYLESS_EVIDENCE_WORKFLOWS.get(report.get("report_type"))
        if workflow is None:
            raise IntegrityError("report type has no protected keyless signer workflow")
        digest = verify_keyless_evidence(
            options.report,
            report,
            signer_workflow=workflow,
        )
        print(json.dumps({"valid": True, "canonical_sha256": digest}, sort_keys=True))
        return 0
    raise AssertionError(f"unhandled command {options.command}")


def _output_and_key(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--signing-key", type=Path)


def _environment_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--environment-manifest", type=Path, required=True)
    parser.add_argument("--trusted-environment-key", action="append", required=True)


def _environment_binding(options: argparse.Namespace) -> dict[str, Any]:
    return validate_manifest(
        load_json(options.environment_manifest),
        trusted_keys=_trusted_keys(options.trusted_environment_key),
    )


def _trusted_keys(values: Sequence[str]) -> dict[str, Path]:
    trusted: dict[str, Path] = {}
    for value in values:
        if "=" in value:
            supplied_id, raw_path = value.split("=", 1)
            path = Path(raw_path)
            actual_id = public_key_id(path)
            if supplied_id != actual_id:
                raise IntegrityError(f"trusted key id does not match {path}")
        else:
            path = Path(value)
            actual_id = public_key_id(path)
        if actual_id in trusted:
            raise IntegrityError(f"duplicate trusted key {actual_id}")
        trusted[actual_id] = path
    return trusted


def _deployment_target_options(options: argparse.Namespace) -> dict[str, str] | None:
    values = (options.commit, options.candidate_image, options.fallback_image)
    if all(value is None for value in values):
        return None
    if not all(isinstance(value, str) and value for value in values):
        raise ValueError(
            "commit, candidate-image, and fallback-image must be supplied together"
        )
    return {
        "commit": options.commit,
        "candidate_image": options.candidate_image,
        "fallback_image": options.fallback_image,
    }


def _build_bake(
    paths: Sequence[Path],
    gate: str,
    environment: str,
    bake_rules: Mapping[str, Any],
    live_rules: Mapping[str, Any],
    signing_key: Path | None,
    trusted_collector_keys: Mapping[str, Path],
    now: datetime | None = None,
) -> dict[str, Any]:
    if len(paths) < 2:
        raise ValueError("bake evidence requires at least two live reports")
    report_timestamps: list[datetime] = []
    observation_windows: list[tuple[datetime, datetime]] = []
    source_hashes = []
    passed = True
    failed_snapshots = 0
    rollback_snapshots = 0
    requests = 0.0
    unique_requests = 0
    maximum_error_ratio = 0.0
    maximum_latency_p95_ms = 0.0
    maximum_durable_pending = 0
    maximum_go_mutations_90d = 0.0
    go_background_writes = 0
    go_financial_writes = 0
    go_ownership_epochs = 0
    go_sessions = 0
    unknown_ownership_epochs = 0
    canonical_sources: set[str] = set()
    generated_timestamps: set[datetime] = set()
    source_commits: set[str] = set()
    environment_bindings: list[dict[str, Any]] = []
    for path in paths:
        report = load_json(path)
        generated_at = parse_timestamp(report.get("generated_at"), "generated_at")
        canonical_source = validate_report(
            report,
            expected_type="live_snapshot",
            trusted_keys=trusted_collector_keys,
            require_signature=True,
            now=generated_at,
        )
        if canonical_source in canonical_sources:
            raise ValueError("bake input repeats the same signed live report")
        if generated_at in generated_timestamps:
            raise ValueError("bake inputs must have unique generated_at timestamps")
        canonical_sources.add(canonical_source)
        generated_timestamps.add(generated_at)
        payload = report.get("payload")
        if not isinstance(payload, dict):
            raise ValueError("bake input payload must be an object")
        provenance = payload.get("provenance")
        if not isinstance(provenance, dict) or not isinstance(
            provenance.get("commit"), str
        ):
            raise ValueError("bake input has no signed source commit")
        source_commits.add(provenance["commit"])
        environment_bindings.append(
            validate_payload_binding(payload.get("environment_binding"))
        )
        if report.get("environment") != environment:
            raise ValueError("all bake reports must match the requested environment")
        if payload.get("traffic_mode") != bake_rules["traffic_mode"]:
            raise ValueError("all bake reports must match traffic-mode")
        window_started_at = parse_timestamp(
            payload.get("window_started_at"),
            "live.window_started_at",
        )
        window_ended_at = parse_timestamp(
            payload.get("window_ended_at"),
            "live.window_ended_at",
        )
        if window_ended_at <= window_started_at or generated_at < window_ended_at:
            raise ValueError("live report does not follow its positive observation window")
        snapshot_checks = evaluate_live(payload, live_rules)
        snapshot_passed = report.get("verdict") == "pass" and all(
            check.passed for check in snapshot_checks
        )
        if not snapshot_passed:
            failed_snapshots += 1
        expected_binary = live_rules.get("expected_binary")
        coordinator = payload.get("coordinator")
        coordinator = coordinator if isinstance(coordinator, dict) else {}
        health = coordinator.get("health")
        health = health if isinstance(health, dict) else {}
        actual_binary = health.get("binary")
        if expected_binary is not None and actual_binary != expected_binary:
            rollback_snapshots += 1
        passed = passed and snapshot_passed
        datadog = payload.get("datadog")
        datadog = datadog if isinstance(datadog, dict) else {}
        queries = datadog.get("queries")
        queries = queries if isinstance(queries, dict) else {}
        expected_window = (
            payload.get("window_started_at"),
            payload.get("window_ended_at"),
        )
        if not queries or any(
            not isinstance(result, dict)
            or (
                result.get("window_started_at"),
                result.get("window_ended_at"),
            )
            != expected_window
            for result in queries.values()
        ):
            raise ValueError("Datadog query buckets do not match the live window")
        request_count = _query_number(queries, "request_count")
        error_ratio = _query_number(queries, "availability_5xx_ratio")
        latency_p95_ms = _query_number(queries, "latency_p95_ms")
        requests += request_count
        maximum_error_ratio = max(maximum_error_ratio, error_ratio)
        maximum_latency_p95_ms = max(maximum_latency_p95_ms, latency_p95_ms)
        maximum_durable_pending = max(
            maximum_durable_pending,
            _maximum_durable_count(payload),
        )
        rds = payload.get("rds")
        rds = rds if isinstance(rds, dict) else {}
        if (
            rds.get("window_started_at"),
            rds.get("window_ended_at"),
        ) != expected_window:
            raise ValueError("RDS counters do not match the live window")
        unique = rds.get("unique_requests")
        if not isinstance(unique, int) or isinstance(unique, bool) or unique < 0:
            raise ValueError("RDS unique request count is missing or invalid")
        unique_requests += unique
        for field in (
            "go_db_mutation_writes",
            "go_background_writes",
            "go_financial_writes",
            "go_ownership_epochs",
            "go_sessions",
            "unknown_ownership_epochs",
        ):
            value = rds.get(field)
            if not isinstance(value, int) or isinstance(value, bool) or value < 0:
                raise ValueError(f"RDS {field} is missing or invalid")
        maximum_go_mutations_90d += rds["go_db_mutation_writes"]
        go_background_writes += rds["go_background_writes"]
        go_financial_writes += rds["go_financial_writes"]
        go_ownership_epochs += rds["go_ownership_epochs"]
        go_sessions += rds["go_sessions"]
        unknown_ownership_epochs += rds["unknown_ownership_epochs"]
        if rds.get("go_audit_coverage_complete") is not True:
            raise ValueError("Go database write audit coverage is incomplete")
        for field in (
            "go_audit_trigger_states_valid",
            "go_audit_definition_hashes_valid",
            "go_audit_owner_coverage_complete",
        ):
            if rds.get(field) is not True:
                raise ValueError(f"RDS {field} is false or missing")
        report_timestamps.append(generated_at)
        observation_windows.append((window_started_at, window_ended_at))
        source_hashes.append(sha256_file(path))
    report_timestamps.sort()
    observation_windows.sort()
    if len(source_commits) != 1:
        raise ValueError("bake inputs must bind one unchanged coordinator commit")
    environment_ids = {
        binding["environment_id"] for binding in environment_bindings
    }
    if len(environment_ids) != 1 or any(
        binding["descriptor"] != environment_bindings[0]["descriptor"]
        for binding in environment_bindings
    ):
        raise ValueError("bake inputs do not share one canonical environment")

    durations = {
        int((ended - started).total_seconds())
        for started, ended in observation_windows
    }
    if len(durations) != 1:
        raise ValueError("bake inputs must use one fixed interval")
    for (_, previous_end), (next_start, _) in zip(
        observation_windows,
        observation_windows[1:],
    ):
        if previous_end != next_start:
            raise ValueError("bake windows overlap or contain a gap")

    observed_now = now or utc_now()
    if report_timestamps[-1] > observed_now + timedelta(minutes=5):
        raise ValueError("bake source timestamp is implausibly in the future")
    if observed_now - report_timestamps[-1] > timedelta(minutes=15):
        raise ValueError("latest bake source is stale")
    payload = {
        "gate": gate,
        "window_started_at": observation_windows[0][0]
        .isoformat()
        .replace("+00:00", "Z"),
        "window_ended_at": observation_windows[-1][1]
        .isoformat()
        .replace("+00:00", "Z"),
        "interval_seconds": next(iter(durations)),
        "traffic_mode": bake_rules["traffic_mode"],
        "maximum_gap_seconds": 0,
        "samples": len(observation_windows),
        "requests": requests,
        "unique_requests": unique_requests,
        "maximum_error_ratio": maximum_error_ratio,
        "maximum_latency_p95_ms": maximum_latency_p95_ms,
        "maximum_durable_pending": maximum_durable_pending,
        "maximum_go_mutations_90d": maximum_go_mutations_90d,
        "go_background_writes": go_background_writes,
        "go_financial_writes": go_financial_writes,
        "go_ownership_epochs": go_ownership_epochs,
        "go_sessions": go_sessions,
        "unknown_ownership_epochs": unknown_ownership_epochs,
        "go_audit_coverage_complete": True,
        "go_audit_trigger_states_valid": True,
        "go_audit_definition_hashes_valid": True,
        "go_audit_owner_coverage_complete": True,
        "gate_incidents": failed_snapshots,
        "rollbacks": rollback_snapshots,
        "continuous_pass": passed,
        "source_sha256": sorted(source_hashes),
        "source_commit": next(iter(source_commits)),
        "environment_binding": environment_bindings[0],
        "provenance": _evidence_provenance(),
    }
    passed = passed and all(
        check.passed
        for check in evaluate_report("bake_observation", payload, bake_rules)
        if not check.name.startswith("provenance:")
    )
    payload["continuous_pass"] = passed
    return new_report(
        "bake_observation",
        environment,
        payload,
        "pass" if passed else "fail",
        validity=timedelta(minutes=15),
        signing_key=signing_key,
        now=observed_now,
    )


def _query_number(queries: Mapping[str, Any], name: str) -> float:
    result = queries.get(name)
    result = result if isinstance(result, dict) else {}
    value = result.get("value")
    if not isinstance(value, (int, float)) or isinstance(value, bool) or value < 0:
        raise ValueError(f"Datadog query {name} has no non-negative numeric value")
    return float(value)


def _maximum_durable_count(payload: Mapping[str, Any]) -> int:
    values: list[int] = []
    coordinator = payload.get("coordinator")
    coordinator = coordinator if isinstance(coordinator, dict) else {}
    durable = coordinator.get("durable_counts")
    durable = durable if isinstance(durable, dict) else {}
    rds = payload.get("rds")
    rds = rds if isinstance(rds, dict) else {}
    for source in (durable, rds):
        for name in (
            "review_pending",
            "sent_unknown",
            "pending_terminals",
            "pending_external",
            "pending_outbox",
            "pending_fees",
            "fee_projection",
            "rollback_unresolved",
        ):
            value = source.get(name)
            if not isinstance(value, int) or isinstance(value, bool) or value < 0:
                raise ValueError(f"durable count {name} is missing or invalid")
            values.append(value)
    return max(values)

