from __future__ import annotations

import os
import sys
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Mapping, Sequence

from . import POLICY_VERSION, SCHEMA_VERSION
from .environment import EnvironmentBindingError, validate_payload_binding
from .evaluators import Check, EvaluationError, evaluate_report
from .integrity import (
    IntegrityError,
    attach_external_signature,
    canonical_bytes,
    format_timestamp,
    load_json,
    parse_timestamp,
    private_key_id,
    seal_document,
    sha256_file,
    utc_now,
    verify_document,
    verify_keyless_evidence,
)
from .reports import new_report, validate_report


class GateError(ValueError):
    """Gate policy or evidence is incomplete."""


AUTOMATION_ENVIRONMENT_MARKERS = (
    "CI",
    "GITHUB_ACTIONS",
    "CURSOR_AGENT",
    "CURSOR_AGENT_ID",
    "CURSOR_CLOUD_AGENT",
    "CURSOR_TRACE_ID",
)
KEYLESS_EVIDENCE_WORKFLOWS = {
    "fault": ".github/workflows/cutover-readiness.yml",
    "rollback_drill": ".github/workflows/cutover-readiness.yml",
    "load": ".github/workflows/pilot-load.yml",
    "differential": ".github/workflows/pilot-load.yml",
}


def load_policy(path: Path) -> dict[str, Any]:
    policy = load_json(path)
    if policy.get("schema_version") != SCHEMA_VERSION:
        raise GateError(f"gate policy schema_version must be {SCHEMA_VERSION}")
    if policy.get("policy_version") != POLICY_VERSION:
        raise GateError(f"gate policy policy_version must be {POLICY_VERSION}")
    gates = policy.get("gates")
    if not isinstance(gates, dict) or not gates:
        raise GateError("gate policy must define gates")
    for name, gate in gates.items():
        if not isinstance(name, str) or not isinstance(gate, dict):
            raise GateError("gate policy entries are malformed")
        if gate.get("environment") not in {
            "isolated",
            "canary",
            "development",
            "production",
        }:
            raise GateError(f"gate {name} has an unsupported environment")
        if not isinstance(gate.get("requires"), list) or not isinstance(gate.get("reports"), dict):
            raise GateError(f"gate {name} must define requires and reports")
        _positive_int(gate, "authorization_max_age_seconds")
        if name in gate["requires"] or any(
            predecessor not in gates for predecessor in gate["requires"]
        ):
            raise GateError(f"gate {name} has an invalid predecessor")
    return policy


def assess_gate(
    gate_name: str,
    policy_path: Path,
    report_paths: Sequence[Path],
    prior_paths: Sequence[Path],
    *,
    signing_key: Path,
    trusted_gate_keys: Mapping[str, Path],
    trusted_evidence_keys: Mapping[str, Path] | None = None,
    deployment_target: Mapping[str, str] | None = None,
    now: datetime | None = None,
) -> dict[str, Any]:
    observed_now = now or utc_now()
    signer_id = private_key_id(signing_key)
    if signer_id not in trusted_gate_keys:
        raise GateError("assessment signing key is not in the trusted gate key set")
    policy = load_policy(policy_path)
    gates = policy["gates"]
    gate = gates.get(gate_name)
    if not isinstance(gate, dict):
        raise GateError(f"unknown gate {gate_name}")

    checks: list[Check] = []
    sources: list[dict[str, Any]] = []
    reports_by_type: dict[str, tuple[Path, dict[str, Any]]] = {}
    report_commits: dict[str, Any] = {}
    environment_bindings: list[dict[str, Any]] = []
    for path in report_paths:
        try:
            report = load_json(path)
            report_type = report.get("report_type")
            if not isinstance(report_type, str):
                raise IntegrityError("report_type is missing")
            if report_type in reports_by_type:
                raise IntegrityError(f"duplicate {report_type} report")
            reports_by_type[report_type] = (path, report)
        except IntegrityError as error:
            checks.append(Check(f"report:{path.name}:parse", False, str(error), "valid report"))

    expected_types = set(gate["reports"])
    unexpected = sorted(set(reports_by_type) - expected_types)
    checks.append(Check("reports:unexpected", not unexpected, unexpected, []))
    for report_type, rules in gate["reports"].items():
        item = reports_by_type.get(report_type)
        if item is None:
            checks.append(Check(f"report:{report_type}:present", False, "missing", "present"))
            continue
        path, report = item
        maximum_age = timedelta(seconds=_positive_int(rules, "maximum_age_seconds"))
        try:
            provenance = report.get("payload", {}).get("provenance", {})
            digest, authentication = _validate_evidence_authenticity(
                path,
                report,
                report_type=report_type,
                trusted_evidence_keys=trusted_evidence_keys,
                now=observed_now,
                maximum_age=maximum_age,
                future_skew=timedelta(seconds=policy["future_skew_seconds"]),
            )
            sources.append(
                {
                    "report_type": report_type,
                    "file_sha256": sha256_file(path),
                    "canonical_sha256": digest,
                    "generated_at": report["generated_at"],
                    "authentication": authentication,
                }
            )
            checks.append(Check(f"report:{report_type}:integrity", True, digest, "valid"))
            checks.append(
                Check(
                    f"report:{report_type}:environment",
                    report.get("environment")
                    == rules.get("source_environment", gate["environment"]),
                    report.get("environment"),
                    rules.get("source_environment", gate["environment"]),
                )
            )
            checks.append(
                Check(
                    f"report:{report_type}:verdict",
                    report.get("verdict") == "pass",
                    report.get("verdict"),
                    "pass",
                )
            )
            checks.extend(evaluate_report(report_type, report["payload"], rules))
            report_commits[report_type] = provenance.get("commit")
            environment_bindings.append(
                validate_payload_binding(report["payload"].get("environment_binding"))
            )
        except (
            IntegrityError,
            GateError,
            EvaluationError,
            EnvironmentBindingError,
        ) as error:
            checks.append(Check(f"report:{report_type}:valid", False, str(error), "fresh and valid"))
    distinct_report_commits = {
        value for value in report_commits.values() if isinstance(value, str)
    }
    checks.append(
        Check(
            "reports:commit_consistent",
            len(report_commits) == len(expected_types)
            and len(distinct_report_commits) == 1,
            report_commits,
            "every required report binds the same commit",
        )
    )

    prior_by_gate: dict[str, tuple[Path, dict[str, Any]]] = {}
    prior_generated_at: dict[str, datetime] = {}
    for path in prior_paths:
        try:
            authorization = load_json(path)
            gate_id = authorization.get("payload", {}).get("gate")
            if not isinstance(gate_id, str):
                raise IntegrityError("prior authorization has no gate")
            if gate_id in prior_by_gate:
                raise IntegrityError(f"duplicate prior authorization for {gate_id}")
            prior_by_gate[gate_id] = (path, authorization)
        except IntegrityError as error:
            checks.append(Check(f"prior:{path.name}:parse", False, str(error), "valid"))

    required_prior = set(gate["requires"])
    predecessor_validation_at = observed_now
    bake_item = reports_by_type.get("bake_observation")
    if bake_item is not None:
        try:
            predecessor_validation_at = parse_timestamp(
                bake_item[1].get("payload", {}).get("window_started_at"),
                "bake.window_started_at",
            )
        except IntegrityError as error:
            checks.append(
                Check(
                    "progression:predecessor_validation_time",
                    False,
                    str(error),
                    "valid bake window start",
                )
            )
    unexpected_prior = sorted(set(prior_by_gate) - required_prior)
    checks.append(Check("prior:unexpected", not unexpected_prior, unexpected_prior, []))
    for prior_gate in gate["requires"]:
        item = prior_by_gate.get(prior_gate)
        if item is None:
            checks.append(Check(f"prior:{prior_gate}:present", False, "missing", "approved"))
            continue
        path, authorization = item
        try:
            digest = validate_report(
                authorization,
                expected_type="gate_authorization",
                trusted_keys=trusted_gate_keys,
                require_signature=True,
                now=predecessor_validation_at,
                maximum_age=timedelta(
                    seconds=_positive_int(
                        gates[prior_gate],
                        "authorization_max_age_seconds",
                    )
                ),
            )
            _validate_authorization_policy(authorization, policy_path, policy)
            prior_environment_id = authorization.get("payload", {}).get(
                "environment_id"
            )
            if not isinstance(prior_environment_id, str):
                raise GateError("predecessor authorization has no environment_id")
            environment_bindings.append(
                validate_payload_binding(
                    {
                        "environment_id": prior_environment_id,
                        "descriptor": authorization.get("payload", {}).get(
                            "environment_descriptor"
                        ),
                    }
                )
            )
            checks.append(
                Check(
                    f"prior:{prior_gate}:approved",
                    authorization.get("verdict") == "pass"
                    and authorization.get("payload", {}).get("gate") == prior_gate,
                    authorization.get("verdict"),
                    "pass",
                )
            )
            prior_generated_at[prior_gate] = parse_timestamp(
                authorization.get("generated_at"),
                f"{prior_gate}.generated_at",
            )
            sources.append(
                {
                    "report_type": "gate_authorization",
                    "gate": prior_gate,
                    "file_sha256": sha256_file(path),
                    "canonical_sha256": digest,
                    "generated_at": authorization["generated_at"],
                }
            )
        except (IntegrityError, GateError, EnvironmentBindingError) as error:
            checks.append(Check(f"prior:{prior_gate}:valid", False, str(error), "valid and signed"))

    environment_ids = {
        binding.get("environment_id")
        for binding in environment_bindings
        if isinstance(binding.get("environment_id"), str)
    }
    descriptors = [
        binding.get("descriptor")
        for binding in environment_bindings
        if isinstance(binding.get("descriptor"), dict)
    ]
    checks.append(
        Check(
            "environment:cross_evidence",
            len(environment_bindings)
            == len(expected_types) + len(required_prior)
            and len(environment_ids) == 1
            and bool(descriptors)
            and all(descriptor == descriptors[0] for descriptor in descriptors),
            sorted(environment_ids),
            "one environment_id and canonical descriptor",
        )
    )
    if bake_item is not None and required_prior:
        try:
            window_started_at = parse_timestamp(
                bake_item[1].get("payload", {}).get("window_started_at"),
                "bake.window_started_at",
            )
            checks.append(
                Check(
                    "progression:window_after_predecessor",
                    len(prior_generated_at) == len(required_prior)
                    and all(
                        generated <= window_started_at
                        for generated in prior_generated_at.values()
                    ),
                    {
                        name: format_timestamp(value)
                        for name, value in prior_generated_at.items()
                    },
                    {"not_after": format_timestamp(window_started_at)},
                )
            )
        except IntegrityError as error:
            checks.append(
                Check(
                    "progression:window_after_predecessor",
                    False,
                    str(error),
                    "window starts after predecessor authorization",
                )
            )

    target = None
    if gate.get("deployment_target_required") is True:
        try:
            target = _validate_deployment_target(deployment_target)
            checks.append(Check("deployment_target:valid", True, target, "valid"))
            checks.append(
                Check(
                    "deployment_target:evidence_commit",
                    distinct_report_commits == {target["commit"]},
                    sorted(distinct_report_commits),
                    [target["commit"]],
                )
            )
            descriptor = descriptors[0] if descriptors else {}
            checks.append(
                Check(
                    "deployment_target:environment_images",
                    descriptor.get("candidate_image") == target["candidate_image"]
                    and descriptor.get("fallback_image") == target["fallback_image"],
                    {
                        "candidate_image": descriptor.get("candidate_image"),
                        "fallback_image": descriptor.get("fallback_image"),
                    },
                    {
                        "candidate_image": target["candidate_image"],
                        "fallback_image": target["fallback_image"],
                    },
                )
            )
        except GateError as error:
            checks.append(
                Check("deployment_target:valid", False, str(error), "immutable and distinct")
            )
    elif deployment_target is not None:
        checks.append(
            Check("deployment_target:unexpected", False, deployment_target, "not supplied")
        )
    passed = bool(checks) and all(check.passed for check in checks)
    validity = timedelta(seconds=policy["assessment_validity_seconds"])
    assessment = new_report(
        "gate_assessment",
        gate["environment"],
        {
            "gate": gate_name,
            "policy_version": policy["policy_version"],
            "policy_sha256": sha256_file(policy_path),
            "checks": [check.json() for check in checks],
            "sources": sources,
            "approval_required": True,
            "decision": "ready_for_human_approval" if passed else "blocked",
            "deployment_target": target,
            "environment_id": next(iter(environment_ids), None),
            "environment_descriptor": descriptors[0] if descriptors else None,
            "predecessor_validation_at": (
                format_timestamp(predecessor_validation_at)
                if required_prior
                else None
            ),
        },
        "pass" if passed else "fail",
        validity=validity,
        signing_key=signing_key,
        now=observed_now,
    )
    return assessment


def create_approval_request(
    assessment: Mapping[str, Any],
    *,
    trusted_gate_keys: Mapping[str, Path],
    trusted_approver_keys: Mapping[str, Path],
    approver_key_id: str,
    approver: str,
    confirmation: str,
    environment: Mapping[str, str] | None = None,
    interactive: bool | None = None,
    now: datetime | None = None,
    validity: timedelta = timedelta(minutes=15),
) -> dict[str, Any]:
    automation_environment = environment if environment is not None else os.environ
    automated = sorted(
        name
        for name in AUTOMATION_ENVIRONMENT_MARKERS
        if automation_environment.get(name)
    )
    if automated:
        raise GateError("human approval cannot be created in an automated agent or CI environment")
    terminal = (
        sys.stdin.isatty() and sys.stdout.isatty()
        if interactive is None
        else interactive
    )
    if not terminal:
        raise GateError("human approval requires an interactive input and output terminal")
    if approver_key_id not in trusted_approver_keys:
        raise GateError("approval key id is not in the trusted approver key set")
    if approver_key_id in trusted_gate_keys:
        raise GateError("gate and human approval keys must be distinct")
    observed_now = now or utc_now()
    digest = validate_report(
        assessment,
        expected_type="gate_assessment",
        trusted_keys=trusted_gate_keys,
        require_signature=True,
        now=observed_now,
    )
    payload = assessment["payload"]
    gate = payload.get("gate")
    if assessment.get("verdict") != "pass" or payload.get("decision") != "ready_for_human_approval":
        raise GateError("blocked or inconclusive assessment cannot be approved")
    if not isinstance(approver, str) or not approver.strip() or approver != approver.strip():
        raise GateError("approver identity must be non-empty and trimmed")
    expected = f"APPROVE {gate} {digest}"
    if confirmation != expected:
        raise GateError("typed approval confirmation does not match the assessment")
    assessment_expiry = parse_timestamp(assessment["valid_until"], "valid_until")
    approval_expiry = min(assessment_expiry, observed_now + validity)
    if approval_expiry <= observed_now:
        raise GateError("assessment expires before approval can be issued")
    document = {
        "schema_version": SCHEMA_VERSION,
        "report_type": "human_approval",
        "generated_at": format_timestamp(observed_now),
        "valid_until": format_timestamp(approval_expiry),
        "environment": assessment["environment"],
        "verdict": "pass",
        "payload": {
            "gate": gate,
            "assessment_sha256": digest,
            "approver": approver,
            "decision": "approve",
            "approval_key_id": approver_key_id,
            "signing_method": "offline_or_hardware",
        },
    }
    return seal_document(document)


def approval_signing_payload(request: Mapping[str, Any]) -> bytes:
    if request.get("report_type") != "human_approval":
        raise GateError("offline signing request is not a human approval")
    verify_document(request)
    return canonical_bytes(
        {key: value for key, value in request.items() if key != "integrity"}
    )


def finalize_approval(
    request: Mapping[str, Any],
    *,
    signature: bytes,
    trusted_approver_keys: Mapping[str, Path],
    environment: Mapping[str, str] | None = None,
    interactive: bool | None = None,
    now: datetime | None = None,
) -> dict[str, Any]:
    automation_environment = environment if environment is not None else os.environ
    if any(
        automation_environment.get(name)
        for name in AUTOMATION_ENVIRONMENT_MARKERS
    ):
        raise GateError("human approval cannot be finalized in an automated agent or CI environment")
    terminal = (
        sys.stdin.isatty() and sys.stdout.isatty()
        if interactive is None
        else interactive
    )
    if not terminal:
        raise GateError("human approval requires an interactive input and output terminal")
    validate_report(request, expected_type="human_approval", now=now or utc_now())
    key_id = request.get("payload", {}).get("approval_key_id")
    if not isinstance(key_id, str) or key_id not in trusted_approver_keys:
        raise GateError("approval request does not name a trusted offline signer")
    return attach_external_signature(
        request,
        signature=signature,
        key_id=key_id,
        trusted_key=trusted_approver_keys[key_id],
    )


def authorize_gate(
    assessment: Mapping[str, Any],
    approval: Mapping[str, Any],
    *,
    policy_path: Path,
    predecessor_authorizations: Sequence[Mapping[str, Any]],
    trusted_gate_keys: Mapping[str, Path],
    trusted_approver_keys: Mapping[str, Path],
    signing_key: Path,
    now: datetime | None = None,
) -> dict[str, Any]:
    observed_now = now or utc_now()
    if set(trusted_gate_keys).intersection(trusted_approver_keys):
        raise GateError("gate and human approval trust sets must be distinct")
    signer_id = private_key_id(signing_key)
    if signer_id not in trusted_gate_keys:
        raise GateError("authorization signing key is not in the trusted gate key set")
    assessment_digest = validate_report(
        assessment,
        expected_type="gate_assessment",
        trusted_keys=trusted_gate_keys,
        require_signature=True,
        now=observed_now,
    )
    approval_digest = validate_report(
        approval,
        expected_type="human_approval",
        trusted_keys=trusted_approver_keys,
        require_signature=True,
        now=observed_now,
    )
    assessment_payload = assessment["payload"]
    approval_payload = approval["payload"]
    gate = assessment_payload.get("gate")
    linked = (
        assessment.get("verdict") == "pass"
        and assessment_payload.get("decision") == "ready_for_human_approval"
        and approval.get("verdict") == "pass"
        and approval_payload.get("decision") == "approve"
        and approval_payload.get("gate") == gate
        and approval_payload.get("assessment_sha256") == assessment_digest
        and approval_payload.get("signing_method") == "offline_or_hardware"
        and approval.get("environment") == assessment.get("environment")
        and approval_payload.get("approval_key_id")
        == approval.get("integrity", {}).get("signature", {}).get("key_id")
    )
    if not linked:
        raise GateError("approval is not bound to this passing assessment")
    if approval_payload.get("approval_key_id") == signer_id:
        raise GateError("gate and human approval keys must be distinct")
    policy = load_policy(policy_path)
    gate_policy = policy["gates"].get(gate)
    if not isinstance(gate_policy, dict):
        raise GateError("assessment names an unknown current-policy gate")
    if assessment.get("environment") != gate_policy["environment"]:
        raise GateError("assessment environment does not match the current gate policy")
    if (
        assessment_payload.get("policy_version") != policy["policy_version"]
        or assessment_payload.get("policy_sha256") != sha256_file(policy_path)
    ):
        raise GateError("assessment does not bind the exact current policy")
    try:
        assessment_environment = validate_payload_binding(
            {
                "environment_id": assessment_payload.get("environment_id"),
                "descriptor": assessment_payload.get("environment_descriptor"),
            }
        )
    except EnvironmentBindingError as error:
        raise GateError(f"assessment environment binding is invalid: {error}") from error
    predecessor_by_gate: dict[str, Mapping[str, Any]] = {}
    for predecessor in predecessor_authorizations:
        predecessor_gate = predecessor.get("payload", {}).get("gate")
        if not isinstance(predecessor_gate, str) or predecessor_gate in predecessor_by_gate:
            raise GateError("predecessor authorization set is malformed or duplicated")
        predecessor_by_gate[predecessor_gate] = predecessor
    if set(predecessor_by_gate) != set(gate_policy["requires"]):
        raise GateError("authorization requires the exact direct predecessor set")
    predecessor_validation_at = None
    if predecessor_by_gate:
        predecessor_validation_at = parse_timestamp(
            assessment_payload.get("predecessor_validation_at"),
            "assessment.predecessor_validation_at",
        )
        if predecessor_validation_at > observed_now:
            raise GateError("predecessor validation time is after authorization")
    elif assessment_payload.get("predecessor_validation_at") is not None:
        raise GateError("root assessment unexpectedly sets predecessor validation time")
    assessment_predecessors = {
        source.get("gate"): source.get("canonical_sha256")
        for source in assessment_payload.get("sources", [])
        if isinstance(source, dict) and source.get("report_type") == "gate_authorization"
    }
    for predecessor_gate, predecessor in predecessor_by_gate.items():
        predecessor_generated = parse_timestamp(
            predecessor.get("generated_at"),
            f"{predecessor_gate}.generated_at",
        )
        if predecessor_generated > predecessor_validation_at:
            raise GateError(
                "authorization predecessor was generated after its validation point"
            )
        predecessor_digest = verify_authorization_bundle(
            predecessor,
            policy_path=policy_path,
            trusted_gate_keys=trusted_gate_keys,
            trusted_approver_keys=trusted_approver_keys,
            now=predecessor_validation_at,
        )
        if (
            predecessor.get("payload", {}).get("environment_id")
            != assessment_environment["environment_id"]
        ):
            raise GateError("predecessor authorization targets another environment")
        if assessment_predecessors.get(predecessor_gate) != predecessor_digest:
            raise GateError("assessment predecessor hash does not match authorization bundle")
    expires = min(
        parse_timestamp(assessment["valid_until"], "assessment.valid_until"),
        parse_timestamp(approval["valid_until"], "approval.valid_until"),
    )
    if expires <= observed_now:
        raise GateError("assessment or approval is stale")
    document = {
        "schema_version": SCHEMA_VERSION,
        "report_type": "gate_authorization",
        "generated_at": format_timestamp(observed_now),
        "valid_until": format_timestamp(
            observed_now
            + timedelta(
                seconds=_positive_int(gate_policy, "authorization_max_age_seconds")
            )
        ),
        "environment": assessment["environment"],
        "verdict": "pass",
        "payload": {
            "gate": gate,
            "policy_version": assessment_payload.get("policy_version"),
            "policy_sha256": assessment_payload.get("policy_sha256"),
            "assessment_sha256": assessment_digest,
            "approval_sha256": approval_digest,
            "approver": approval_payload.get("approver"),
            "approval_key_id": approval_payload.get("approval_key_id"),
            "deployment_target": assessment_payload.get("deployment_target"),
            "environment_id": assessment_environment["environment_id"],
            "environment_descriptor": assessment_environment["descriptor"],
            "predecessor_validation_at": (
                format_timestamp(predecessor_validation_at)
                if predecessor_validation_at is not None
                else None
            ),
            "authorization": "human_approved_preflight_only",
            "evidence_bundle": {
                "assessment": dict(assessment),
                "approval": dict(approval),
                "predecessors": [dict(value) for value in predecessor_authorizations],
            },
        },
    }
    return seal_document(document, signing_key=signing_key)


def verify_authorization_bundle(
    authorization: Mapping[str, Any],
    *,
    policy_path: Path,
    trusted_gate_keys: Mapping[str, Path],
    trusted_approver_keys: Mapping[str, Path],
    expected_gate: str | None = None,
    expected_environment: str | None = None,
    expected_target: Mapping[str, str] | None = None,
    now: datetime | None = None,
    _seen: set[str] | None = None,
) -> str:
    observed_now = now or utc_now()
    policy = load_policy(policy_path)
    if set(trusted_gate_keys).intersection(trusted_approver_keys):
        raise GateError("gate and human approval trust sets must be distinct")
    payload = authorization.get("payload")
    payload = payload if isinstance(payload, dict) else {}
    gate = payload.get("gate")
    if not isinstance(gate, str) or gate not in policy["gates"]:
        raise GateError("authorization names an unknown current-policy gate")
    gate_policy = policy["gates"][gate]
    digest = validate_report(
        authorization,
        expected_type="gate_authorization",
        trusted_keys=trusted_gate_keys,
        require_signature=True,
        now=observed_now,
        maximum_age=timedelta(
            seconds=_positive_int(gate_policy, "authorization_max_age_seconds")
        ),
    )
    seen = set() if _seen is None else set(_seen)
    if digest in seen:
        raise GateError("authorization predecessor chain contains a cycle")
    seen.add(digest)
    _validate_authorization_policy(authorization, policy_path, policy)
    if authorization.get("environment") != gate_policy["environment"]:
        raise GateError("authorization environment does not match the current gate policy")
    if authorization.get("verdict") != "pass":
        raise GateError("authorization verdict is not pass")
    if expected_gate is not None and gate != expected_gate:
        raise GateError("authorization is for the wrong gate")
    if expected_environment is not None and authorization.get("environment") != expected_environment:
        raise GateError("authorization is for the wrong environment")
    if payload.get("authorization") != "human_approved_preflight_only":
        raise GateError("authorization is not an explicit human-approved preflight")
    try:
        authorization_environment = validate_payload_binding(
            {
                "environment_id": payload.get("environment_id"),
                "descriptor": payload.get("environment_descriptor"),
            }
        )
    except EnvironmentBindingError as error:
        raise GateError(f"authorization environment binding is invalid: {error}") from error
    bundle = payload.get("evidence_bundle")
    if not isinstance(bundle, dict) or set(bundle) != {
        "assessment",
        "approval",
        "predecessors",
    }:
        raise GateError("authorization evidence bundle is missing or malformed")
    assessment = bundle.get("assessment")
    approval = bundle.get("approval")
    predecessors = bundle.get("predecessors")
    if (
        not isinstance(assessment, dict)
        or not isinstance(approval, dict)
        or not isinstance(predecessors, list)
        or not all(isinstance(value, dict) for value in predecessors)
    ):
        raise GateError("authorization evidence bundle has invalid document types")
    authorized_at = parse_timestamp(authorization.get("generated_at"), "authorization.generated_at")
    assessment_digest = validate_report(
        assessment,
        expected_type="gate_assessment",
        trusted_keys=trusted_gate_keys,
        require_signature=True,
        now=authorized_at,
    )
    approval_digest = validate_report(
        approval,
        expected_type="human_approval",
        trusted_keys=trusted_approver_keys,
        require_signature=True,
        now=authorized_at,
    )
    assessment_payload = assessment.get("payload", {})
    approval_payload = approval.get("payload", {})
    assessment_checks = assessment_payload.get("checks")
    assessment_checks_valid = (
        isinstance(assessment_checks, list)
        and bool(assessment_checks)
        and all(
            isinstance(check, dict)
            and isinstance(check.get("name"), str)
            and bool(check["name"])
            and check.get("passed") is True
            for check in assessment_checks
        )
    )
    assessment_at = parse_timestamp(
        assessment.get("generated_at"),
        "assessment.generated_at",
    )
    approval_at = parse_timestamp(approval.get("generated_at"), "approval.generated_at")
    if not assessment_at <= approval_at <= authorized_at:
        raise GateError("assessment, approval, and authorization timestamps are out of order")
    predecessor_validation_at = None
    if gate_policy["requires"]:
        predecessor_validation_at = parse_timestamp(
            payload.get("predecessor_validation_at"),
            "authorization.predecessor_validation_at",
        )
        if predecessor_validation_at > authorized_at:
            raise GateError("predecessor validation time is after authorization")
    elif (
        payload.get("predecessor_validation_at") is not None
        or assessment_payload.get("predecessor_validation_at") is not None
    ):
        raise GateError("root authorization unexpectedly sets predecessor validation time")
    current_policy_sha256 = sha256_file(policy_path)
    authorization_key_id = authorization.get("integrity", {}).get("signature", {}).get("key_id")
    if (
        assessment.get("verdict") != "pass"
        or assessment_payload.get("decision") != "ready_for_human_approval"
        or assessment_payload.get("approval_required") is not True
        or not assessment_checks_valid
        or assessment_payload.get("gate") != gate
        or assessment_payload.get("policy_version") != policy["policy_version"]
        or assessment_payload.get("policy_sha256") != current_policy_sha256
        or assessment.get("environment") != authorization.get("environment")
        or approval.get("verdict") != "pass"
        or approval_payload.get("decision") != "approve"
        or approval_payload.get("gate") != gate
        or approval.get("environment") != authorization.get("environment")
        or approval_payload.get("assessment_sha256") != assessment_digest
        or approval_payload.get("signing_method") != "offline_or_hardware"
        or approval_payload.get("approval_key_id")
        != approval.get("integrity", {}).get("signature", {}).get("key_id")
        or approval_payload.get("approval_key_id") == authorization_key_id
        or payload.get("policy_version") != assessment_payload.get("policy_version")
        or payload.get("policy_sha256") != assessment_payload.get("policy_sha256")
        or payload.get("assessment_sha256") != assessment_digest
        or payload.get("approval_sha256") != approval_digest
        or payload.get("approval_key_id") != approval_payload.get("approval_key_id")
        or payload.get("approver") != approval_payload.get("approver")
        or assessment_payload.get("environment_id")
        != authorization_environment["environment_id"]
        or assessment_payload.get("environment_descriptor")
        != authorization_environment["descriptor"]
        or payload.get("predecessor_validation_at")
        != assessment_payload.get("predecessor_validation_at")
    ):
        raise GateError("authorization human approval linkage is invalid")
    target = assessment_payload.get("deployment_target")
    if gate_policy.get("deployment_target_required") is True:
        target = _validate_deployment_target(target)
        if payload.get("deployment_target") != target:
            raise GateError("authorization deployment target differs from assessment")
    elif target is not None or payload.get("deployment_target") is not None:
        raise GateError("non-deployment authorization unexpectedly contains a target")
    if expected_target is not None and target != _validate_deployment_target(expected_target):
        raise GateError("authorization deployment target does not match requested deployment")
    predecessor_by_gate = {
        value.get("payload", {}).get("gate"): value for value in predecessors
    }
    if (
        len(predecessor_by_gate) != len(predecessors)
        or set(predecessor_by_gate) != set(gate_policy["requires"])
    ):
        raise GateError("authorization bundle does not contain the exact predecessor set")
    assessment_predecessors = {
        source.get("gate"): source.get("canonical_sha256")
        for source in assessment_payload.get("sources", [])
        if isinstance(source, dict) and source.get("report_type") == "gate_authorization"
    }
    for predecessor_gate, predecessor in predecessor_by_gate.items():
        predecessor_generated = parse_timestamp(
            predecessor.get("generated_at"),
            f"{predecessor_gate}.generated_at",
        )
        if predecessor_generated > predecessor_validation_at:
            raise GateError(
                "authorization predecessor was generated after its validation point"
            )
        predecessor_digest = verify_authorization_bundle(
            predecessor,
            policy_path=policy_path,
            trusted_gate_keys=trusted_gate_keys,
            trusted_approver_keys=trusted_approver_keys,
            expected_gate=predecessor_gate,
            now=predecessor_validation_at,
            _seen=seen,
        )
        if (
            predecessor.get("payload", {}).get("environment_id")
            != authorization_environment["environment_id"]
        ):
            raise GateError("authorization predecessor targets another environment")
        if assessment_predecessors.get(predecessor_gate) != predecessor_digest:
            raise GateError("authorization predecessor is not bound to its assessment")
    return digest


def _validate_authorization_policy(
    authorization: Mapping[str, Any],
    policy_path: Path,
    policy: Mapping[str, Any],
) -> None:
    payload = authorization.get("payload")
    payload = payload if isinstance(payload, dict) else {}
    if (
        payload.get("policy_version") != policy.get("policy_version")
        or payload.get("policy_sha256") != sha256_file(policy_path)
    ):
        raise GateError("authorization does not bind the exact current policy")


def _validate_deployment_target(
    target: Mapping[str, str] | None,
) -> dict[str, str]:
    if not isinstance(target, Mapping) or set(target) != {
        "commit",
        "candidate_image",
        "fallback_image",
    }:
        raise GateError("deployment target must bind commit, candidate image, and fallback image")
    commit = target.get("commit")
    candidate = target.get("candidate_image")
    fallback = target.get("fallback_image")
    if (
        not isinstance(commit, str)
        or len(commit) != 40
        or any(character not in "0123456789abcdef" for character in commit)
    ):
        raise GateError("deployment commit must be a full lowercase 40-character SHA")
    if not _repository_image_digest(candidate) or not _repository_image_digest(fallback):
        raise GateError("candidate and fallback images must be immutable repository digests")
    if candidate == fallback:
        raise GateError("candidate and fallback image digests must be distinct")
    return {
        "commit": commit,
        "candidate_image": candidate,
        "fallback_image": fallback,
    }


def _repository_image_digest(value: Any) -> bool:
    if not isinstance(value, str) or value.count("@sha256:") != 1:
        return False
    repository, digest = value.split("@sha256:", 1)
    return (
        bool(repository)
        and all(character.isalnum() or character in "._/:-" for character in repository)
        and len(digest) == 64
        and all(character in "0123456789abcdef" for character in digest)
    )


def _validate_evidence_authenticity(
    path: Path,
    report: Mapping[str, Any],
    *,
    report_type: str,
    trusted_evidence_keys: Mapping[str, Path] | None,
    now: datetime,
    maximum_age: timedelta,
    future_skew: timedelta,
) -> tuple[str, str]:
    integrity = report.get("integrity")
    signature = integrity.get("signature") if isinstance(integrity, dict) else None
    if signature is not None:
        return (
            validate_report(
                report,
                expected_type=report_type,
                trusted_keys=trusted_evidence_keys,
                require_signature=True,
                now=now,
                maximum_age=maximum_age,
                future_skew=future_skew,
            ),
            "configured_public_key",
        )
    digest = validate_report(
        report,
        expected_type=report_type,
        require_signature=False,
        now=now,
        maximum_age=maximum_age,
        future_skew=future_skew,
    )
    workflow = KEYLESS_EVIDENCE_WORKFLOWS.get(report_type)
    if workflow is None:
        raise GateError(
            f"unsigned {report_type} evidence has no protected keyless signer policy"
        )
    verified = verify_keyless_evidence(
        path,
        report,
        signer_workflow=workflow,
    )
    if verified != digest:
        raise GateError("keyless evidence digest changed during verification")
    return digest, "sigstore_and_github_attestation"


def _positive_int(value: Mapping[str, Any], name: str) -> int:
    item = value.get(name)
    if not isinstance(item, int) or isinstance(item, bool) or item <= 0:
        raise GateError(f"{name} must be a positive integer")
    return item

