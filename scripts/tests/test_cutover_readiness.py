from __future__ import annotations

import contextlib
import io
import json
import subprocess
import tempfile
import threading
import unittest
import unittest.mock as mock
import urllib.parse
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from scripts.cutover_readiness.clients import (
    DATADOG_API_BASES,
    ReadOnlyClientError,
    collect_coordinator,
    collect_datadog,
    load_secret,
    validate_read_url,
)
from scripts.cutover_readiness.cli import _build_bake, build_parser
from scripts.cutover_readiness.evaluators import evaluate_live, evaluate_report
from scripts.cutover_readiness.environment import (
    EnvironmentBindingError,
    payload_binding,
    read_only_dsn_fingerprint,
    validate_descriptor,
    writer_endpoint_fingerprint,
)
from scripts.cutover_readiness.gates import (
    GateError,
    approval_signing_payload,
    assess_gate,
    authorize_gate,
    create_approval_request,
    finalize_approval,
    load_policy,
    verify_authorization_bundle,
)
from scripts.cutover_readiness.integrity import (
    IntegrityError,
    private_key_id,
    public_key_id,
    seal_document,
    sha256_file,
    verify_document,
    verify_keyless_evidence,
)
from scripts.cutover_readiness.rds import (
    READ_ONLY_SQL,
    READ_ONLY_SQL_PATH,
    collect_rds,
    reject_runtime_write_credentials,
    validate_read_only_dsn,
)
from scripts.cutover_readiness.reports import (
    _check_environment,
    _evidence_provenance,
    import_pilot_report,
    import_route_trace,
    new_report,
    validate_report,
)
from scripts.pilot_load.component import (
    component_coverage,
    expected_component_tests,
)


ROOT = Path(__file__).resolve().parents[2]
POLICY = ROOT / "deploy/cutover/gates.json"
NOW = datetime(2026, 7, 12, 10, 0, tzinfo=timezone.utc)
COMMIT = subprocess.run(
    ["/usr/bin/git", "-C", str(ROOT), "rev-parse", "HEAD"],
    check=True,
    capture_output=True,
    text=True,
).stdout.strip()
CANDIDATE_IMAGE = "registry.example/coordinator@sha256:" + "b" * 64
FALLBACK_IMAGE = "registry.example/coordinator@sha256:" + "c" * 64
TEST_BINDING = payload_binding(
    {
        "schema_version": 2,
        "canonical_environment": "production",
        "https_origin": "https://api.darkbloom.dev",
        "listener_identity": "api.darkbloom.dev:443",
        "database_instance_id": "prod-fingerprint",
        "database_system_identifier": "72623859790382856",
        "read_only_dsn_sha256": "d" * 64,
        "writer_endpoint_sha256": "1" * 64,
        "coordinator_ownership_id": "production-owner",
        "coordinator_app_id": "production-app",
        "datadog_site": "us1",
        "datadog_organization_id": "production-datadog-org",
        "canary_https_origin": "https://canary.darkbloom.dev",
        "canary_listener_identity": "canary.internal:8080",
        "canary_database_instance_id": "canary",
        "canary_database_system_identifier": "82623859790382856",
        "canary_read_only_dsn_sha256": "e" * 64,
        "canary_writer_endpoint_sha256": "2" * 64,
        "canary_coordinator_ownership_id": "canary-owner",
        "canary_coordinator_app_id": "canary-app",
        "canary_datadog_site": "us3",
        "canary_datadog_organization_id": "canary-datadog-org",
        "candidate_image": CANDIDATE_IMAGE,
        "fallback_image": FALLBACK_IMAGE,
    }
)
FAULT_COVERAGE = [
    "bounded_backpressure",
    "exactly_one_disposition",
    "historical_ack",
    "no_double_money_mutation",
    "no_failover_after_auth",
    "preauthorization_failover_only",
    "quiescence_ownership_fencing",
    "same_lease_recovery",
]


class CutoverReadinessTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.keys = tempfile.TemporaryDirectory()
        root = Path(cls.keys.name)
        cls.gate_private, cls.gate_public = _key_pair(root, "gate")
        cls.human_private, cls.human_public = _key_pair(root, "human")
        cls.gate_key_id = public_key_id(cls.gate_public)
        cls.human_key_id = public_key_id(cls.human_public)
        assert cls.gate_key_id == private_key_id(cls.gate_private)
        assert cls.human_key_id == private_key_id(cls.human_private)

    @classmethod
    def tearDownClass(cls) -> None:
        cls.keys.cleanup()

    def test_policy_defines_every_stage_and_explicit_sites(self) -> None:
        policy = load_policy(POLICY)
        schema = json.loads(
            (ROOT / "deploy/cutover/evidence-schema.json").read_text(encoding="utf-8")
        )
        self.assertEqual(schema["properties"]["schema_version"]["const"], 2)
        self.assertIn("integrity", schema["required"])
        self.assertEqual(
            schema["properties"]["integrity"]["properties"]["canonical_sha256"]["pattern"],
            "^[0-9a-f]{64}$",
        )
        self.assertEqual(
            set(policy["gates"]),
            {
                "isolated-pilot",
                "sampled-shadow-replay",
                "rollback-drill",
                "dedicated-canary",
                "bake-24h",
                "bake-7d",
                "full-cutover",
                "bake-30d",
                "bake-90d",
                "go-retirement",
            },
        )
        live_rules = [
            gate["reports"]["live_snapshot"]
            for gate in policy["gates"].values()
            if "live_snapshot" in gate["reports"]
        ]
        self.assertTrue(live_rules)
        self.assertTrue(
            all(rule["minimum_provider_version"] == "0.7.5" for rule in live_rules)
        )
        self.assertEqual(set(DATADOG_API_BASES), {"us1", "us3", "us5", "eu", "ap1", "ap2"})
        production_queries = json.loads(
            (ROOT / "deploy/cutover/datadog-queries.json").read_text(encoding="utf-8")
        )["queries"]
        reducers = {query["name"]: query["reducer"] for query in production_queries}
        self.assertEqual(reducers["request_count"], "sum")
        self.assertNotIn("go_mutation_traffic_90d", reducers)
        self.assertEqual(
            policy["gates"]["full-cutover"]["authorization_max_age_seconds"],
            900,
        )
        self.assertTrue(
            all(
                query["bucket_seconds"] == 900
                and query["window_seconds"] == 900
                and ".rollup(" in query["query"]
                for query in production_queries
            )
        )

    def test_checksum_and_signature_bind_timestamps_and_schema(self) -> None:
        report = new_report(
            "fault",
            "isolated",
            _fault_payload(),
            "pass",
            validity=timedelta(days=1),
            signing_key=self.gate_private,
            now=NOW,
        )
        digest = validate_report(
            report,
            expected_type="fault",
            trusted_keys={self.gate_key_id: self.gate_public},
            require_signature=True,
            now=NOW,
        )
        self.assertEqual(report["schema_version"], 2)
        self.assertEqual(len(digest), 64)
        self.assertEqual(report["integrity"]["canonical_sha256"], digest)

        forged = json.loads(json.dumps(report))
        forged["generated_at"] = "2026-07-13T10:00:00Z"
        with self.assertRaisesRegex(IntegrityError, "checksum"):
            verify_document(
                forged,
                trusted_keys={self.gate_key_id: self.gate_public},
                require_signature=True,
            )
        wrong_schema = json.loads(json.dumps(report))
        wrong_schema["schema_version"] = 99
        with self.assertRaisesRegex(IntegrityError, "schema_version"):
            validate_report(wrong_schema, now=NOW)
        extra_field = json.loads(json.dumps(report))
        extra_field["unreviewed"] = True
        with self.assertRaisesRegex(IntegrityError, "schema"):
            validate_report(extra_field, now=NOW)
        with tempfile.TemporaryDirectory() as directory:
            key_link = Path(directory) / "signing-key.pem"
            key_link.symlink_to(self.gate_private)
            with self.assertRaisesRegex(IntegrityError, "non-symlink"):
                new_report(
                    "fault",
                    "isolated",
                    _fault_payload(),
                    "pass",
                    validity=timedelta(days=1),
                    signing_key=key_link,
                    now=NOW,
                )

    def test_keyless_evidence_requires_both_pinned_attestation_verifiers(self) -> None:
        report = new_report(
            "load",
            "isolated",
            _load_payload(),
            "pass",
            validity=timedelta(days=1),
            now=NOW,
        )
        with tempfile.TemporaryDirectory() as directory:
            report_path = Path(directory) / "load.json"
            report_path.write_text(json.dumps(report), encoding="utf-8")
            report_path.with_suffix(".json.sigstore.json").write_text(
                "{}",
                encoding="utf-8",
            )
            report_path.with_suffix(".json.github-attestation.jsonl").write_text(
                "{}\n",
                encoding="utf-8",
            )
            completed = subprocess.CompletedProcess([], 0, b"verified", b"")
            with mock.patch(
                "scripts.cutover_readiness.integrity.subprocess.run",
                return_value=completed,
            ) as run:
                digest = verify_keyless_evidence(
                    report_path,
                    report,
                    signer_workflow=".github/workflows/pilot-load.yml",
                )
            self.assertEqual(digest, report["integrity"]["canonical_sha256"])
            self.assertEqual(run.call_count, 2)
            self.assertEqual(run.call_args_list[0].args[0][0], "/usr/local/bin/cosign")
            self.assertEqual(run.call_args_list[1].args[0][0], "/usr/bin/gh")
            report_path.with_suffix(".json.github-attestation.jsonl").unlink()
            with self.assertRaisesRegex(IntegrityError, "missing or unsafe"):
                verify_keyless_evidence(
                    report_path,
                    report,
                    signer_workflow=".github/workflows/pilot-load.yml",
                )

    def test_pilot_import_distinguishes_load_from_differential(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            logs = root / "logs"
            logs.mkdir()
            commands = []
            for name in (
                "go-load",
                "rust-1000-ws",
                "rust-10x-requests",
                "rust-concurrency-slow-consumers",
                "rust-session-replacement",
                "rust-hedge",
                "rust-sent-unknown",
            ):
                expected = sorted(expected_component_tests(name))
                if name == "go-load":
                    output = "".join(
                        json.dumps({"Action": "pass", "Test": test}) + "\n"
                        for test in expected
                    )
                else:
                    output = "".join(f"test {test} ... ok\n" for test in expected)
                log_path = logs / f"{name}.log"
                log_path.write_text(output, encoding="utf-8")
                commands.append(
                    {
                        "name": name,
                        "exit_code": 0,
                        "log": f"logs/{name}.log",
                        "log_sha256": sha256_file(log_path),
                        "expected_tests": expected,
                        "passed_tests": expected,
                        "measurement_complete": True,
                    }
                )
            component = {
                "schema_version": 1,
                "generated_at": "2026-07-12T09:59:00Z",
                "profile": "scheduled",
                "verdict": "pass",
                "iterations": 1,
                "elapsed_seconds": 1_800,
                "coverage": component_coverage(commands),
                "commands": commands,
            }
            component_path = root / "component.json"
            component_path.write_text(json.dumps(component), encoding="utf-8")
            imported_load = import_pilot_report(component_path, now=NOW)
            self.assertEqual(
                imported_load["report_type"],
                "load",
            )
            with self.assertRaisesRegex(IntegrityError, "stale"):
                validate_report(imported_load, now=NOW + timedelta(days=8))
            component["coverage"]["sent_unknown"] = False
            component_path.write_text(json.dumps(component), encoding="utf-8")
            with self.assertRaisesRegex(IntegrityError, "executable commands"):
                import_pilot_report(component_path, now=NOW)
            component["coverage"]["sent_unknown"] = True
            component_path.write_text(json.dumps(component), encoding="utf-8")
            (logs / "rust-sent-unknown.log").write_text(
                "test forged::coverage ... ok\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(IntegrityError, "log hash"):
                import_pilot_report(component_path, now=NOW)

            differential = {
                "schema_version": 1,
                "generated_at": "2026-07-12T09:59:00Z",
                "profile": {"name": "scheduled"},
                "verdict": "pass",
                "metadata": {
                    "regression_baseline_mode": "measured",
                    "source": {"commit": "2" * 40},
                    "ci": {"provider": "github-actions", "run_id": "200"},
                    "baseline_provenance": {
                        "review_status": "reviewed",
                        "source_commit": "1" * 40,
                        "source_run_id": "100",
                        "source_report_sha256": "a" * 64,
                    },
                },
                "comparison": {"passed": True, "differences": []},
                "gate_failures": [],
                "skipped_scenarios": [],
                "targets": {"go": {}, "rust": {}},
            }
            differential_path = root / "differential.json"
            differential_path.write_text(json.dumps(differential), encoding="utf-8")
            self.assertEqual(
                import_pilot_report(differential_path, now=NOW)["report_type"],
                "differential",
            )
            differential["verdict"] = "baseline_review_required"
            differential["metadata"]["regression_baseline_mode"] = "capture"
            differential["metadata"]["baseline_provenance"] = None
            differential_path.write_text(json.dumps(differential), encoding="utf-8")
            with self.assertRaisesRegex(IntegrityError, "non-authorizing"):
                import_pilot_report(differential_path, now=NOW)
            differential["verdict"] = "pass"
            differential["metadata"]["regression_baseline_mode"] = "measured"
            differential_path.write_text(json.dumps(differential), encoding="utf-8")
            with self.assertRaisesRegex(IntegrityError, "distinct prior"):
                import_pilot_report(differential_path, now=NOW)

    def test_future_stale_and_missing_evidence_fail_closed(self) -> None:
        future = new_report(
            "fault",
            "isolated",
            _fault_payload(),
            "pass",
            validity=timedelta(days=1),
            now=NOW + timedelta(hours=1),
        )
        with self.assertRaisesRegex(IntegrityError, "future"):
            validate_report(future, now=NOW)
        stale = new_report(
            "fault",
            "isolated",
            _fault_payload(),
            "pass",
            validity=timedelta(minutes=1),
            now=NOW - timedelta(hours=1),
        )
        with self.assertRaisesRegex(IntegrityError, "stale"):
            validate_report(stale, now=NOW)

        with tempfile.TemporaryDirectory() as directory:
            assessment = assess_gate(
                "isolated-pilot",
                POLICY,
                [],
                [],
                signing_key=self.gate_private,
                trusted_gate_keys={self.gate_key_id: self.gate_public},
                now=NOW,
            )
            self.assertEqual(assessment["verdict"], "fail")
            self.assertEqual(assessment["payload"]["decision"], "blocked")
            self.assertTrue(
                any(
                    check["name"] == "report:fault:present" and not check["passed"]
                    for check in assessment["payload"]["checks"]
                )
            )
            unsigned_load = new_report(
                "load",
                "isolated",
                _load_payload(),
                "pass",
                validity=timedelta(days=7),
                now=NOW,
            )
            unsigned_path = Path(directory) / "unsigned-load.json"
            unsigned_path.write_text(json.dumps(unsigned_load), encoding="utf-8")
            unsigned_assessment = assess_gate(
                "isolated-pilot",
                POLICY,
                [unsigned_path],
                [],
                signing_key=self.gate_private,
                trusted_gate_keys={self.gate_key_id: self.gate_public},
                trusted_evidence_keys={self.gate_key_id: self.gate_public},
                now=NOW,
            )
            self.assertTrue(
                any(
                    check["name"] == "report:load:valid"
                    and "missing or unsafe" in check["observed"]
                    for check in unsigned_assessment["payload"]["checks"]
                )
            )
            bypass_payload = _fault_payload()
            bypass_payload["boundary_count"] = 20
            bypass_fault = new_report(
                "fault",
                "isolated",
                bypass_payload,
                "pass",
                validity=timedelta(days=7),
                signing_key=self.gate_private,
                now=NOW,
            )
            differential = new_report(
                "differential",
                "isolated",
                _differential_payload(),
                "pass",
                validity=timedelta(days=7),
                signing_key=self.gate_private,
                now=NOW,
            )
            load = new_report(
                "load",
                "isolated",
                _load_payload(),
                "pass",
                validity=timedelta(days=7),
                signing_key=self.gate_private,
                now=NOW,
            )
            fault_path = Path(directory) / "fault.json"
            differential_path = Path(directory) / "differential.json"
            load_path = Path(directory) / "load.json"
            fault_path.write_text(json.dumps(bypass_fault), encoding="utf-8")
            differential_path.write_text(json.dumps(differential), encoding="utf-8")
            load_path.write_text(json.dumps(load), encoding="utf-8")
            bypass = assess_gate(
                "isolated-pilot",
                POLICY,
                [fault_path, load_path, differential_path],
                [],
                signing_key=self.gate_private,
                trusted_gate_keys={self.gate_key_id: self.gate_public},
                trusted_evidence_keys={self.gate_key_id: self.gate_public},
                now=NOW,
            )
            self.assertEqual(bypass["verdict"], "fail")
            self.assertTrue(
                any(
                    check["name"] == "fault:identity" and not check["passed"]
                    for check in bypass["payload"]["checks"]
                )
            )

    def test_human_approval_is_required_signed_and_assessment_bound(self) -> None:
        fault = new_report(
            "fault",
            "isolated",
            _fault_payload(),
            "pass",
            validity=timedelta(days=7),
            signing_key=self.gate_private,
            now=NOW,
        )
        differential = new_report(
            "differential",
            "isolated",
            _differential_payload(),
            "pass",
            validity=timedelta(days=7),
            signing_key=self.gate_private,
            now=NOW,
        )
        load = new_report(
            "load",
            "isolated",
            _load_payload(),
            "pass",
            validity=timedelta(days=7),
            signing_key=self.gate_private,
            now=NOW,
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fault_path = root / "fault.json"
            differential_path = root / "differential.json"
            load_path = root / "load.json"
            fault_path.write_text(json.dumps(fault), encoding="utf-8")
            differential_path.write_text(json.dumps(differential), encoding="utf-8")
            load_path.write_text(json.dumps(load), encoding="utf-8")
            assessment = assess_gate(
                "isolated-pilot",
                POLICY,
                [fault_path, load_path, differential_path],
                [],
                signing_key=self.gate_private,
                trusted_gate_keys={self.gate_key_id: self.gate_public},
                trusted_evidence_keys={self.gate_key_id: self.gate_public},
                now=NOW,
            )
        self.assertEqual(assessment["verdict"], "pass")
        assessment_digest = verify_document(
            assessment,
            trusted_keys={self.gate_key_id: self.gate_public},
            require_signature=True,
        )
        with self.assertRaisesRegex(GateError, "automated"):
            create_approval_request(
                assessment,
                trusted_gate_keys={self.gate_key_id: self.gate_public},
                trusted_approver_keys={self.human_key_id: self.human_public},
                approver_key_id=self.human_key_id,
                approver="release@example.test",
                confirmation=f"APPROVE isolated-pilot {assessment_digest}",
                environment={"CI": "true"},
                interactive=True,
                now=NOW,
            )
        with self.assertRaisesRegex(GateError, "confirmation"):
            create_approval_request(
                assessment,
                trusted_gate_keys={self.gate_key_id: self.gate_public},
                trusted_approver_keys={self.human_key_id: self.human_public},
                approver_key_id=self.human_key_id,
                approver="release@example.test",
                confirmation="APPROVE isolated-pilot forged",
                environment={},
                interactive=True,
                now=NOW,
            )
        with self.assertRaisesRegex(GateError, "distinct"):
            create_approval_request(
                assessment,
                trusted_gate_keys={self.gate_key_id: self.gate_public},
                trusted_approver_keys={self.gate_key_id: self.gate_public},
                approver_key_id=self.gate_key_id,
                approver="release@example.test",
                confirmation=f"APPROVE isolated-pilot {assessment_digest}",
                environment={},
                interactive=True,
                now=NOW,
            )
        with self.assertRaisesRegex(GateError, "interactive"):
            create_approval_request(
                assessment,
                trusted_gate_keys={self.gate_key_id: self.gate_public},
                trusted_approver_keys={self.human_key_id: self.human_public},
                approver_key_id=self.human_key_id,
                approver="release@example.test",
                confirmation=f"APPROVE isolated-pilot {assessment_digest}",
                environment={},
                interactive=False,
                now=NOW,
            )
        request = create_approval_request(
            assessment,
            trusted_gate_keys={self.gate_key_id: self.gate_public},
            trusted_approver_keys={self.human_key_id: self.human_public},
            approver_key_id=self.human_key_id,
            approver="release@example.test",
            confirmation=f"APPROVE isolated-pilot {assessment_digest}",
            environment={},
            interactive=True,
            now=NOW,
        )
        with self.assertRaisesRegex(IntegrityError, "signature"):
            finalize_approval(
                request,
                signature=b"",
                trusted_approver_keys={self.human_key_id: self.human_public},
                environment={},
                interactive=True,
                now=NOW,
            )
        approval = finalize_approval(
            request,
            signature=_sign_bytes(approval_signing_payload(request), self.human_private),
            trusted_approver_keys={self.human_key_id: self.human_public},
            environment={},
            interactive=True,
            now=NOW,
        )
        authorization = authorize_gate(
            assessment,
            approval,
            policy_path=POLICY,
            predecessor_authorizations=[],
            trusted_gate_keys={self.gate_key_id: self.gate_public},
            trusted_approver_keys={self.human_key_id: self.human_public},
            signing_key=self.gate_private,
            now=NOW,
        )
        self.assertEqual(authorization["verdict"], "pass")
        self.assertEqual(
            authorization["payload"]["authorization"],
            "human_approved_preflight_only",
        )
        verify_authorization_bundle(
            authorization,
            policy_path=POLICY,
            trusted_gate_keys={self.gate_key_id: self.gate_public},
            trusted_approver_keys={self.human_key_id: self.human_public},
            now=NOW,
        )
        verify_authorization_bundle(
            authorization,
            policy_path=POLICY,
            trusted_gate_keys={self.gate_key_id: self.gate_public},
            trusted_approver_keys={self.human_key_id: self.human_public},
            now=NOW + timedelta(minutes=14),
        )
        with self.assertRaisesRegex(IntegrityError, "stale|maximum"):
            verify_authorization_bundle(
                authorization,
                policy_path=POLICY,
                trusted_gate_keys={self.gate_key_id: self.gate_public},
                trusted_approver_keys={self.human_key_id: self.human_public},
                now=NOW + timedelta(days=8),
            )
        with tempfile.TemporaryDirectory() as directory:
            stale_policy = json.loads(POLICY.read_text(encoding="utf-8"))
            stale_policy["assessment_validity_seconds"] = 901
            stale_policy_path = Path(directory) / "stale-policy.json"
            stale_policy_path.write_text(json.dumps(stale_policy), encoding="utf-8")
            with self.assertRaisesRegex(GateError, "exact current policy"):
                verify_authorization_bundle(
                    authorization,
                    policy_path=stale_policy_path,
                    trusted_gate_keys={self.gate_key_id: self.gate_public},
                    trusted_approver_keys={self.human_key_id: self.human_public},
                    now=NOW,
                )

    def test_read_only_clients_use_get_local_fixture_and_all_sites(self) -> None:
        with _fixture_server() as base_url:
            coordinator = collect_coordinator(
                base_url,
                ops_read_key="read-only",
                public_key="public",
                minimum_provider_version="0.7.5",
                fixture=True,
            )
            self.assertTrue(coordinator["health"]["migration_checksum_valid"])
            self.assertEqual(
                coordinator["provider_coverage"],
                {
                    "total": 2,
                    "hardware": 2,
                    "versions_known": 2,
                    "at_or_above_floor": 2,
                    "protocol_v1": 1,
                    "protocol_v2": 1,
                    "protocol_v2_inference_eligible": 1,
                },
            )
            self.assertEqual(
                {
                    name: coordinator["durable_counts"][name]
                    for name in ("rollback_unresolved", "go_fallback_safe")
                },
                {"rollback_unresolved": 0, "go_fallback_safe": True},
            )
            query = [
                {
                    "name": "ownership_healthy",
                    "query": "min:test.metric{*}.rollup(min,60)",
                    "window_seconds": 60,
                    "bucket_seconds": 60,
                    "rollup_aggregator": "min",
                    "reducer": "min",
                }
            ]
            for site in DATADOG_API_BASES:
                result = collect_datadog(
                    site,
                    query,
                    api_key="api",
                    application_key="app",
                    api_base_override=base_url,
                    fixture=True,
                    now=NOW,
                )
                self.assertEqual(result["site"], site)
                self.assertEqual(result["queries"]["ownership_healthy"]["value"], 1.0)

        with self.assertRaisesRegex(ReadOnlyClientError, "explicit"):
            collect_datadog(
                "",
                [],
                api_key="api",
                application_key="app",
                fixture=True,
            )
        with self.assertRaisesRegex(ReadOnlyClientError, "acknowledgement"):
            validate_read_url("https://api.darkbloom.dev", fixture=False)
        with tempfile.TemporaryDirectory() as directory:
            secret = Path(directory) / "secret"
            secret.write_text("value\n", encoding="utf-8")
            secret.chmod(0o600)
            secret_link = Path(directory) / "secret-link"
            secret_link.symlink_to(secret)
            with self.assertRaisesRegex(ReadOnlyClientError, "non-symlink"):
                load_secret(secret_link)

    def test_datadog_binding_requires_exact_org_site_rollup_and_buckets(self) -> None:
        query = json.loads(
            (ROOT / "deploy/cutover/datadog-queries.json").read_text(encoding="utf-8")
        )["queries"][1:2]
        with _fixture_server() as base_url:
            result = collect_datadog(
                "us1",
                query,
                api_key="api",
                application_key="app",
                environment_binding=TEST_BINDING,
                environment="development",
                window_start=NOW - timedelta(minutes=15),
                window_end=NOW,
                api_base_override=base_url,
                fixture=True,
                now=NOW,
            )
            self.assertEqual(result["organization_id"], "production-datadog-org")
            self.assertEqual(
                result["queries"]["ownership_healthy"]["bucket_started_at"],
                ["2026-07-12T09:45:00Z"],
            )
            with self.assertRaisesRegex(ReadOnlyClientError, "site"):
                collect_datadog(
                    "us3",
                    query,
                    api_key="api",
                    application_key="app",
                    environment_binding=TEST_BINDING,
                    environment="development",
                    window_start=NOW - timedelta(minutes=15),
                    window_end=NOW,
                    api_base_override=base_url,
                    fixture=True,
                    now=NOW,
                )
            other_tenant = dict(TEST_BINDING["descriptor"])
            other_tenant["datadog_organization_id"] = "another-tenant"
            with self.assertRaisesRegex(ReadOnlyClientError, "organization"):
                collect_datadog(
                    "us1",
                    query,
                    api_key="api",
                    application_key="app",
                    environment_binding=payload_binding(other_tenant),
                    environment="development",
                    window_start=NOW - timedelta(minutes=15),
                    window_end=NOW,
                    api_base_override=base_url,
                    fixture=True,
                    now=NOW,
                )

        response_date = "Sun, 12 Jul 2026 10:00:00 GMT"
        with mock.patch(
            "scripts.cutover_readiness.clients._get_json",
            side_effect=[
                (
                    {
                        "data": {
                            "relationships": {
                                "org": {
                                    "data": {"id": "production-datadog-org"}
                                }
                            }
                        }
                    },
                    response_date,
                ),
                (
                    {
                        "series": [
                            {"pointlist": [[int(NOW.timestamp()) * 1000, 1.0]]}
                        ]
                    },
                    response_date,
                ),
            ],
        ):
            with self.assertRaisesRegex(ReadOnlyClientError, "exact fixed buckets"):
                collect_datadog(
                    "us1",
                    query,
                    api_key="api",
                    application_key="app",
                    environment_binding=TEST_BINDING,
                    environment="production",
                    window_start=NOW - timedelta(minutes=15),
                    window_end=NOW,
                    now=NOW,
                )

    def test_rds_rejects_runtime_or_write_capable_credentials(self) -> None:
        with self.assertRaisesRegex(ReadOnlyClientError, "role must be exactly"):
            validate_read_only_dsn(
                "postgresql://writer@localhost/db?sslmode=disable",
                fixture=True,
            )
        accepted = validate_read_only_dsn(
            "postgresql://darkbloom_cutover_readonly@localhost/db?sslmode=disable",
            fixture=True,
        )
        self.assertEqual(accepted["user"], "darkbloom_cutover_readonly")
        with self.assertRaisesRegex(ReadOnlyClientError, "runtime database"):
            reject_runtime_write_credentials({"EIGENINFERENCE_DATABASE_URL": "postgres://prod"})
        with self.assertRaisesRegex(ReadOnlyClientError, "verify-full"):
            validate_read_only_dsn(
                "postgresql://darkbloom_cutover_readonly@replica.example/db"
                "?target_session_attrs=read-only"
                "&options=-c%20default_transaction_read_only=on",
            )
        with mock.patch.dict(
            "os.environ",
            {
                "ADMIN_API_KEY": "production-write-key",
                "STRIPE_SECRET_KEY": "production-write-key",
                "DARKBLOOM_TEST_DATABASE_URL": "postgresql://test@127.0.0.1/test",
                "PATH": "/usr/bin",
            },
            clear=True,
        ):
            child = _check_environment()
        self.assertNotIn("ADMIN_API_KEY", child)
        self.assertNotIn("STRIPE_SECRET_KEY", child)
        self.assertIn("DARKBLOOM_TEST_DATABASE_URL", child)
        with mock.patch.dict(
            "os.environ",
            {"DARKBLOOM_TEST_DATABASE_URL": "postgresql://writer@prod.example/prod"},
            clear=True,
        ):
            with self.assertRaisesRegex(IntegrityError, "loopback"):
                _check_environment()
        rollback_guard_sql = READ_ONLY_SQL.split("'rollback_unresolved'", 1)[1]
        for relation in (
            "financial_operations",
            "external_events",
            "mdm_command_expectations",
            "telemetry_events",
        ):
            self.assertIn(f"rust_coord.{relation}", rollback_guard_sql)
        self.assertIn("SET default_transaction_read_only = on", READ_ONLY_SQL)
        self.assertIn("has_sequence_privilege", READ_ONLY_SQL)
        self.assertIn("has_schema_privilege", READ_ONLY_SQL)
        historical_ack_sql = READ_ONLY_SQL.split("'historical_terminal_acks'", 1)[1]
        self.assertIn("terminal.received_count > 1", historical_ack_sql)
        self.assertIn("attempt.state = 'acknowledged'", historical_ack_sql)

    def test_rds_collection_uses_quiet_read_only_psql_session(self) -> None:
        response = {
            "window_started_at": "2026-07-12T09:45:00Z",
            "window_ended_at": "2026-07-12T10:00:00Z",
            "database_instance_id": "fixture-read-replica",
            "database_system_identifier": "72623859790382856",
            "transaction_read_only": True,
            "read_only_role": True,
            "is_read_replica": False,
            "role_elevated": False,
            "role_has_write_privileges": False,
            "public_schema_version": 7,
            "rust_schema_version": 5,
            "external_unknown": 0,
            "review_pending": 0,
            "sent_unknown": 0,
            "pending_terminals": 0,
            "pending_external": 0,
            "pending_outbox": 0,
            "pending_fees": 0,
            "fee_projection": 0,
            "historical_terminal_acks": 1,
            "rollback_unresolved": 0,
            "unique_requests": 1,
            "go_db_mutation_writes": 0,
            "go_background_writes": 0,
            "go_financial_writes": 0,
            "go_ownership_epochs": 0,
            "go_sessions": 0,
            "unknown_ownership_epochs": 0,
            "go_audit_coverage_complete": True,
            "go_audit_trigger_states_valid": True,
            "go_audit_definition_hashes_valid": True,
            "go_audit_owner_coverage_complete": True,
        }
        completed = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=(json.dumps(response) + "\n").encode(),
            stderr=b"",
        )
        with tempfile.TemporaryDirectory() as directory:
            dsn_file = Path(directory) / "rds.txt"
            dsn = (
                "postgresql://darkbloom_cutover_readonly:fixture"
                "@127.0.0.1/cutover?sslmode=disable"
            )
            dsn_file.write_text(dsn + "\n", encoding="utf-8")
            descriptor = dict(TEST_BINDING["descriptor"])
            descriptor["database_instance_id"] = "fixture-read-replica"
            descriptor["read_only_dsn_sha256"] = read_only_dsn_fingerprint(dsn)
            descriptor["writer_endpoint_sha256"] = writer_endpoint_fingerprint(
                "writer.fixture:5432"
            )
            binding = payload_binding(descriptor)
            with mock.patch.dict("os.environ", {"PATH": "/usr/bin"}, clear=True), mock.patch(
                "scripts.cutover_readiness.rds.subprocess.run",
                return_value=completed,
            ) as run:
                result = collect_rds(
                    dsn_file,
                    environment_binding=binding,
                    environment="development",
                    writer_endpoint="writer.fixture:5432",
                    fixture=True,
                    window_start=NOW - timedelta(minutes=15),
                    window_end=NOW,
                )
                with self.assertRaisesRegex(ReadOnlyClientError, "writer endpoint"):
                    collect_rds(
                        dsn_file,
                        environment_binding=binding,
                        environment="development",
                        writer_endpoint="other-writer.fixture:5432",
                        fixture=True,
                        window_start=NOW - timedelta(minutes=15),
                        window_end=NOW,
                    )
        command = run.call_args.args[0]
        child_environment = run.call_args.kwargs["env"]
        self.assertIn("--quiet", command)
        self.assertIn("--no-password", command)
        self.assertEqual(command[0], "/usr/bin/psql")
        self.assertEqual(child_environment["PGTARGETSESSIONATTRS"], "read-only")
        self.assertEqual(child_environment["PGOPTIONS"], "-c default_transaction_read_only=on")
        self.assertTrue(result["read_only_role"])
        self.assertEqual(
            result["database_system_identifier"],
            TEST_BINDING["descriptor"]["database_system_identifier"],
        )

    def test_live_gate_cannot_omit_protocol_datadog_or_durable_counts(self) -> None:
        payload = _live_payload()
        rules = {
            "traffic_mode": "atomic_single_owner",
            "minimum_provider_version": "0.7.5",
            "minimum_v2_fraction": 0.5,
            "allow_v1": True,
            "require_quiescent": True,
            "require_historical_terminal_ack": True,
            "minimum_requests": 100,
            "maximum_error_ratio": 0.02,
            "maximum_latency_p95_ms": 30000,
            "datadog_query_path": "deploy/cutover/datadog-queries.json",
            "rds_query_path": "deploy/cutover/rds-readonly.sql",
        }
        checks = evaluate_live(payload, rules)
        self.assertTrue(all(check.passed for check in checks))

        payload["coordinator"]["health"]["commit"] = "d" * 40
        checks = evaluate_live(payload, rules)
        self.assertIn(
            "live:runtime_commit",
            {check.name for check in checks if not check.passed},
        )
        payload["coordinator"]["health"]["commit"] = COMMIT
        payload["coordinator"]["provider_coverage"]["protocol_v2"] = None
        payload["datadog"]["queries"].pop("external_unknown")
        payload["rds"].pop("pending_fees")
        payload["datadog"].pop("site")
        payload["datadog"].pop("response_dates")
        payload.pop("minimum_provider_version")
        payload["coordinator"]["durable_counts"].pop("go_fallback_safe")
        payload["coordinator"]["response_dates"].pop("metrics")
        checks = evaluate_live(payload, rules)
        failed = {check.name for check in checks if not check.passed}
        self.assertIn("live:provider_protocol_coverage", failed)
        self.assertIn("live:datadog:external_unknown", failed)
        self.assertIn("live:rds:pending_fees", failed)
        self.assertIn("live:datadog_site", failed)
        self.assertIn("live:datadog_response_dates", failed)
        self.assertIn("live:coordinator_response_dates", failed)
        self.assertIn("live:minimum_provider_version", failed)
        self.assertIn("live:coordinator:rollback_guard", failed)

    def test_environment_binding_rejects_arbitrary_origin_and_cross_source_mix(self) -> None:
        arbitrary = dict(TEST_BINDING["descriptor"])
        arbitrary["https_origin"] = "https://attacker.example"
        with self.assertRaisesRegex(EnvironmentBindingError, "production HTTPS origin"):
            validate_descriptor(arbitrary)
        same_cluster = dict(TEST_BINDING["descriptor"])
        same_cluster["canary_database_system_identifier"] = same_cluster[
            "database_system_identifier"
        ]
        with self.assertRaisesRegex(EnvironmentBindingError, "system identifiers"):
            validate_descriptor(same_cluster)

        payload = _live_payload()
        payload["datadog"]["environment_id"] = "0" * 64
        rules = {
            "traffic_mode": "atomic_single_owner",
            "minimum_provider_version": "0.7.5",
            "minimum_v2_fraction": 0.5,
            "allow_v1": True,
            "minimum_requests": 1,
            "maximum_error_ratio": 0.1,
            "maximum_latency_p95_ms": 30000,
            "datadog_query_path": "deploy/cutover/datadog-queries.json",
            "rds_query_path": "deploy/cutover/rds-readonly.sql",
        }
        failed = {
            check.name for check in evaluate_live(payload, rules) if not check.passed
        }
        self.assertIn("live:environment_id_equality", failed)

    def test_bake_builder_marks_short_or_gapped_windows_failed(self) -> None:
        bake_rules = {
            "gate": "test-bake",
            "maximum_age_seconds": 900,
            "minimum_duration_seconds": 3600,
            "traffic_mode": "atomic_single_owner",
            "maximum_gap_seconds": 0,
            "minimum_samples": 2,
            "minimum_requests": 100,
            "minimum_unique_requests": 100,
            "maximum_error_ratio": 0.02,
            "maximum_latency_p95_ms": 30000,
        }
        live_rules = {
            "maximum_age_seconds": 900,
            "traffic_mode": "atomic_single_owner",
            "minimum_provider_version": "0.7.5",
            "minimum_v2_fraction": 0.5,
            "allow_v1": True,
            "minimum_requests": 100,
            "maximum_error_ratio": 0.02,
            "maximum_latency_p95_ms": 30000,
            "datadog_query_path": "deploy/cutover/datadog-queries.json",
            "rds_query_path": "deploy/cutover/rds-readonly.sql",
        }
        with tempfile.TemporaryDirectory() as directory:
            paths = []
            for index, generated_at in enumerate((NOW - timedelta(minutes=15), NOW)):
                report = new_report(
                    "live_snapshot",
                    "production",
                    _live_payload(generated_at),
                    "pass",
                    validity=timedelta(minutes=15),
                    signing_key=self.gate_private,
                    now=generated_at,
                )
                path = Path(directory) / f"live-{index}.json"
                path.write_text(json.dumps(report), encoding="utf-8")
                paths.append(path)
            bake = _build_bake(
                paths,
                "test-bake",
                "production",
                bake_rules,
                live_rules,
                self.gate_private,
                {self.gate_key_id: self.gate_public},
                now=NOW,
            )
            with self.assertRaisesRegex(ValueError, "repeats the same signed"):
                _build_bake(
                    [paths[0], paths[0]],
                    "test-bake",
                    "production",
                    bake_rules,
                    live_rules,
                    self.gate_private,
                    {self.gate_key_id: self.gate_public},
                    now=NOW,
                )
            for replacement_end, expected in (
                (NOW + timedelta(minutes=5), "gap"),
                (NOW - timedelta(minutes=5), "overlap"),
            ):
                payload = _live_payload(replacement_end)
                replacement = new_report(
                    "live_snapshot",
                    "production",
                    payload,
                    "pass",
                    validity=timedelta(minutes=15),
                    signing_key=self.gate_private,
                    now=replacement_end,
                )
                replacement_path = Path(directory) / f"{expected}.json"
                replacement_path.write_text(
                    json.dumps(replacement),
                    encoding="utf-8",
                )
                with self.assertRaisesRegex(ValueError, "overlap or contain a gap"):
                    _build_bake(
                        [paths[0], replacement_path],
                        "test-bake",
                        "production",
                        bake_rules,
                        live_rules,
                        self.gate_private,
                        {self.gate_key_id: self.gate_public},
                        now=max(NOW, replacement_end),
                    )
        self.assertEqual(bake["verdict"], "fail")
        self.assertFalse(bake["payload"]["continuous_pass"])
        self.assertEqual(bake["payload"]["source_commit"], COMMIT)
        forged_bake = dict(bake["payload"])
        forged_bake["source_commit"] = "d" * 40
        self.assertIn(
            "bake:source_commit",
            {
                check.name
                for check in evaluate_report(
                    "bake_observation",
                    forged_bake,
                    bake_rules,
                )
                if not check.passed
            },
        )

    def test_route_ratios_are_computed_and_canary_isolation_is_enforced(self) -> None:
        trace = {
            "schema_version": 2,
            "generated_at": "2026-07-12T10:00:00Z",
            "mode": "sampled_shadow",
            "source_requests": 100000,
            "routed_requests": 1000,
            "failed_requests": 0,
            "latency_p95_ms": 100,
            "mutation_count": 0,
            "ownership_mode": "observe_only_no_owner",
            "listener": "offline-replay",
            "production_listener": "api.darkbloom.dev:443",
            "database_identity": "none",
            "production_database_identity": "prod-fingerprint",
            "money_mode": "none",
        }
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "trace.json"
            source.write_text(json.dumps(trace), encoding="utf-8")
            report = import_route_trace(
                source,
                environment="isolated",
                environment_binding=TEST_BINDING,
                now=NOW,
            )
            source.write_text(
                json.dumps({**trace, "schema_version": 1}),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(IntegrityError, "schema version 2"):
                import_route_trace(
                    source,
                    environment="isolated",
                    environment_binding=TEST_BINDING,
                    now=NOW,
                )
        self.assertEqual(report["payload"]["observed_route_ratio"], 0.01)
        rules = load_policy(POLICY)["gates"]["sampled-shadow-replay"]["reports"][
            "route_trace"
        ]
        self.assertTrue(
            all(
                check.passed
                for check in evaluate_report("route_trace", report["payload"], rules)
            )
        )
        forged = dict(report["payload"])
        forged["observed_route_ratio"] = 0.5
        failed = {
            check.name
            for check in evaluate_report("route_trace", forged, rules)
            if not check.passed
        }
        self.assertIn("route_trace:measured_ratio", failed)
        forged = dict(report["payload"])
        forged["database_identity"] = "prod-fingerprint"
        failed = {
            check.name
            for check in evaluate_report("route_trace", forged, rules)
            if not check.passed
        }
        self.assertIn("route_trace:shadow_database", failed)

        dedicated = dict(report["payload"])
        dedicated.update(
            {
                "mode": "dedicated_self_route",
                "source_requests": 10000,
                "routed_requests": 10000,
                "observed_route_ratio": 1.0,
                "ownership_mode": "single_rust_owner",
                "money_mode": "synthetic_isolated",
                "database_identity": "same",
                "production_database_identity": "same",
                "listener": "canary.internal:8080",
                "production_listener": "api.darkbloom.dev:443",
            }
        )
        dedicated_rules = load_policy(POLICY)["gates"]["dedicated-canary"]["reports"][
            "route_trace"
        ]
        failed = {
            check.name
            for check in evaluate_report("route_trace", dedicated, dedicated_rules)
            if not check.passed
        }
        self.assertIn("route_trace:separate_database", failed)
        dedicated["database_identity"] = "canary"
        dedicated["listener"] = dedicated["production_listener"]
        failed = {
            check.name
            for check in evaluate_report("route_trace", dedicated, dedicated_rules)
            if not check.passed
        }
        self.assertIn("route_trace:listener", failed)

    def test_arbitrary_query_psql_and_traffic_percent_flags_are_rejected(self) -> None:
        parser = build_parser()
        base = [
            "collect-live",
            "--environment",
            "development",
            "--base-url",
            "http://127.0.0.1:8080",
            "--ops-read-key-file",
            "ops",
            "--public-key-file",
            "public",
            "--datadog-site",
            "us1",
            "--datadog-api-key-file",
            "api",
            "--datadog-application-key-file",
            "app",
            "--rds-dsn-file",
            "rds",
            "--rds-writer-endpoint",
            "writer.example:5432",
            "--minimum-provider-version",
            "0.7.5",
            "--window-start",
            "2026-07-12T09:45:00Z",
            "--window-end",
            "2026-07-12T10:00:00Z",
            "--environment-manifest",
            "environment.json",
            "--trusted-environment-key",
            "environment.pub.pem",
            "--output",
            "out",
        ]
        for forbidden in (
            ["--psql", "/tmp/fake-psql"],
            ["--datadog-queries", "/tmp/fake-query.json"],
            ["--traffic-percent", "100"],
        ):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                parser.parse_args([*base, *forbidden])

    def test_pinned_query_hashes_and_ninety_day_zero_go_proof_fail_closed(self) -> None:
        payload = _live_payload()
        payload["coordinator"]["provider_coverage"].update(
            {
                "protocol_v1": 0,
                "protocol_v2": 2,
                "protocol_v2_inference_eligible": 2,
            }
        )
        rules = load_policy(POLICY)["gates"]["go-retirement"]["reports"][
            "live_snapshot"
        ]
        self.assertTrue(all(check.passed for check in evaluate_live(payload, rules)))
        payload["datadog"]["query_definition_sha256"] = "0" * 64
        payload["rds"]["query_definition_sha256"] = "1" * 64
        payload["rds"]["go_db_mutation_writes"] = 1
        payload["rds"]["go_ownership_epochs"] = 1
        payload["rds"]["go_audit_coverage_complete"] = False
        payload["rds"]["go_audit_trigger_states_valid"] = False
        payload["rds"]["go_audit_definition_hashes_valid"] = False
        payload["rds"]["go_audit_owner_coverage_complete"] = False
        payload["coordinator"]["health"]["image_digest"] = FALLBACK_IMAGE
        payload["rds"]["database_system_identifier"] = "999"
        payload["rds"]["writer_endpoint_sha256"] = "9" * 64
        payload["datadog"]["organization_id"] = "another-tenant"
        failed = {
            check.name for check in evaluate_live(payload, rules) if not check.passed
        }
        self.assertIn("live:datadog_query_definition", failed)
        self.assertIn("live:rds_query_definition", failed)
        self.assertIn("live:rds:go_mutation_writes", failed)
        self.assertIn("live:rds:go_ownership_epochs", failed)
        self.assertIn("live:rds:go_audit_coverage", failed)
        self.assertIn("live:rds:go_audit_trigger_states", failed)
        self.assertIn("live:rds:go_audit_definition_hashes", failed)
        self.assertIn("live:rds:go_audit_owner_coverage", failed)
        self.assertIn("live:runtime_image_digest", failed)
        self.assertIn("live:database_system_identifier", failed)
        self.assertIn("live:writer_endpoint", failed)
        self.assertIn("live:datadog_organization", failed)

    def test_ci_provenance_cannot_omit_run_binding(self) -> None:
        with mock.patch.dict(
            "os.environ",
            {
                "GITHUB_ACTIONS": "true",
                "GITHUB_REPOSITORY": "Layr-Labs/d-inference",
                "GITHUB_SHA": COMMIT,
            },
            clear=True,
        ):
            with self.assertRaisesRegex(IntegrityError, "provenance"):
                new_report(
                    "load",
                    "isolated",
                    _load_payload(),
                    "pass",
                    validity=timedelta(minutes=1),
                    now=NOW,
                )

        with mock.patch.dict(
            "os.environ",
            {
                "GITHUB_ACTIONS": "true",
                "GITHUB_REPOSITORY": "Layr-Labs/d-inference",
                "GITHUB_SHA": COMMIT,
                "GITHUB_RUN_ID": "123",
                "GITHUB_RUN_ATTEMPT": "1",
                "GITHUB_WORKFLOW": "Coordinator Cutover Readiness",
                "GITHUB_WORKFLOW_REF": (
                    "Layr-Labs/d-inference/.github/workflows/"
                    "cutover-readiness.yml@refs/heads/master"
                ),
                "GITHUB_WORKFLOW_SHA": COMMIT,
                "GITHUB_REF": "refs/heads/master",
                "GITHUB_REF_PROTECTED": "true",
                "GITHUB_EVENT_NAME": "schedule",
            },
            clear=True,
        ):
            provenance = _evidence_provenance()
        self.assertEqual(provenance["workflow_sha"], COMMIT)
        self.assertEqual(provenance["ref_protected"], "true")

        payload = _load_payload()
        payload["provenance"] = _test_provenance()
        payload["provenance"]["tool_manifest_sha256"] = "0" * 64
        failed = {
            check.name
            for check in evaluate_report("load", payload, {})
            if not check.passed
        }
        self.assertIn("provenance:repository_tool_schema", failed)

    def test_cutover_rejects_quick_profiles_as_scheduled_soak_evidence(self) -> None:
        load = _load_payload()
        load["profile"] = "quick"
        load["elapsed_seconds"] = 120
        differential = _differential_payload()
        differential["profile"] = "quick"
        differential["target_load_elapsed_seconds"] = {"go": 120, "rust": 120}

        self.assertIn(
            "load:scheduled_soak",
            {
                check.name
                for check in evaluate_report("load", load, {})
                if not check.passed
            },
        )
        self.assertIn(
            "differential:scheduled_soak",
            {
                check.name
                for check in evaluate_report("differential", differential, {})
                if not check.passed
            },
        )

    def test_full_cutover_target_rejects_mutable_or_equal_images(self) -> None:
        valid = {
            "commit": "a" * 40,
            "candidate_image": "registry.example/coordinator@sha256:" + "b" * 64,
            "fallback_image": "registry.example/coordinator@sha256:" + "c" * 64,
        }
        assessment = assess_gate(
            "full-cutover",
            POLICY,
            [],
            [],
            signing_key=self.gate_private,
            trusted_gate_keys={self.gate_key_id: self.gate_public},
            deployment_target=valid,
            now=NOW,
        )
        target_check = next(
            check
            for check in assessment["payload"]["checks"]
            if check["name"] == "deployment_target:valid"
        )
        self.assertTrue(target_check["passed"])
        for invalid in (
            {**valid, "candidate_image": "registry.example/coordinator:latest"},
            {**valid, "fallback_image": valid["candidate_image"]},
            {**valid, "commit": "short"},
        ):
            blocked = assess_gate(
                "full-cutover",
                POLICY,
                [],
                [],
                signing_key=self.gate_private,
                trusted_gate_keys={self.gate_key_id: self.gate_public},
                deployment_target=invalid,
                now=NOW,
            )
            target_check = next(
                check
                for check in blocked["payload"]["checks"]
                if check["name"] == "deployment_target:valid"
            )
            self.assertFalse(target_check["passed"])

    def test_full_cutover_authorization_verifies_complete_predecessor_chain(self) -> None:
        target = {
            "commit": COMMIT,
            "candidate_image": "registry.example/coordinator@sha256:" + "b" * 64,
            "fallback_image": "registry.example/coordinator@sha256:" + "c" * 64,
        }
        authorization = self._build_test_authorization("full-cutover", target=target)
        verify_authorization_bundle(
            authorization,
            policy_path=POLICY,
            trusted_gate_keys={self.gate_key_id: self.gate_public},
            trusted_approver_keys={self.human_key_id: self.human_public},
            expected_gate="full-cutover",
            expected_environment="production",
            expected_target=target,
            now=NOW,
        )
        with self.assertRaisesRegex(GateError, "trust sets must be distinct"):
            verify_authorization_bundle(
                authorization,
                policy_path=POLICY,
                trusted_gate_keys={self.gate_key_id: self.gate_public},
                trusted_approver_keys={
                    self.gate_key_id: self.gate_public,
                    self.human_key_id: self.human_public,
                },
                now=NOW,
            )

        unsigned = seal_document(
            {
                key: value
                for key, value in authorization.items()
                if key != "integrity"
            }
        )
        with self.assertRaisesRegex(IntegrityError, "not signed"):
            verify_authorization_bundle(
                unsigned,
                policy_path=POLICY,
                trusted_gate_keys={self.gate_key_id: self.gate_public},
                trusted_approver_keys={self.human_key_id: self.human_public},
                now=NOW,
            )
        with self.assertRaisesRegex(GateError, "does not match"):
            verify_authorization_bundle(
                authorization,
                policy_path=POLICY,
                trusted_gate_keys={self.gate_key_id: self.gate_public},
                trusted_approver_keys={self.human_key_id: self.human_public},
                expected_target={**target, "commit": "d" * 40},
                now=NOW,
            )

        missing_predecessor = {
            key: value
            for key, value in authorization.items()
            if key != "integrity"
        }
        missing_predecessor = json.loads(json.dumps(missing_predecessor))
        missing_predecessor["payload"]["evidence_bundle"]["predecessors"].pop()
        missing_predecessor = seal_document(
            missing_predecessor,
            signing_key=self.gate_private,
        )
        with self.assertRaisesRegex(GateError, "exact predecessor"):
            verify_authorization_bundle(
                missing_predecessor,
                policy_path=POLICY,
                trusted_gate_keys={self.gate_key_id: self.gate_public},
                trusted_approver_keys={self.human_key_id: self.human_public},
                now=NOW,
            )
        with self.assertRaisesRegex(IntegrityError, "stale|maximum"):
            verify_authorization_bundle(
                authorization,
                policy_path=POLICY,
                trusted_gate_keys={self.gate_key_id: self.gate_public},
                trusted_approver_keys={self.human_key_id: self.human_public},
                now=NOW + timedelta(minutes=16),
            )

    def test_progression_chain_remains_verifiable_through_ninety_day_bake(self) -> None:
        target = {
            "commit": COMMIT,
            "candidate_image": CANDIDATE_IMAGE,
            "fallback_image": FALLBACK_IMAGE,
        }
        times = {
            "isolated-pilot": NOW,
            "sampled-shadow-replay": NOW + timedelta(days=1),
            "rollback-drill": NOW + timedelta(days=1, hours=12),
            "dedicated-canary": NOW + timedelta(days=2),
            "full-cutover": NOW + timedelta(days=3),
            "bake-24h": NOW + timedelta(days=4),
            "bake-7d": NOW + timedelta(days=11),
            "bake-30d": NOW + timedelta(days=41),
            "bake-90d": NOW + timedelta(days=131),
            "go-retirement": NOW + timedelta(days=131, hours=1),
        }
        authorization = self._build_test_authorization(
            "go-retirement",
            target=target,
            times=times,
        )
        verify_authorization_bundle(
            authorization,
            policy_path=POLICY,
            trusted_gate_keys={self.gate_key_id: self.gate_public},
            trusted_approver_keys={self.human_key_id: self.human_public},
            expected_gate="go-retirement",
            expected_environment="production",
            now=times["go-retirement"] + timedelta(minutes=5),
        )

        stale_times = dict(times)
        stale_times["go-retirement"] += timedelta(days=2)
        with self.assertRaisesRegex(IntegrityError, "stale|maximum"):
            self._build_test_authorization(
                "go-retirement",
                target=target,
                times=stale_times,
            )

    def test_rollback_evidence_requires_internal_local_container_command(self) -> None:
        rules = load_policy(POLICY)["gates"]["rollback-drill"]["reports"]["rollback_drill"]
        payload = {
            "check": "rollback-rehearsal",
            "command": [
                str(ROOT / "scripts/rehearse-coordinator-rollback.sh"),
                "__execute",
                CANDIDATE_IMAGE,
                FALLBACK_IMAGE,
                rules["required_postgres_image"],
                TEST_BINDING["environment_id"],
            ],
            "coverage": rules["required_coverage"],
            "coverage_source": {
                "path": rules["coverage_script_path"],
                "sha256": sha256_file(
                    ROOT / rules["coverage_script_path"]
                ),
            },
            "exit_code": 0,
            "provenance": _test_provenance(),
            "environment_binding": TEST_BINDING,
        }
        self.assertTrue(
            all(check.passed for check in evaluate_report("rollback_drill", payload, rules))
        )
        payload["command"].append("ignored-bypass")
        failed = {
            check.name
            for check in evaluate_report("rollback_drill", payload, rules)
            if not check.passed
        }
        self.assertIn("rollback_drill:identity", failed)

    def _build_test_authorization(
        self,
        gate: str,
        *,
        target: dict[str, str] | None = None,
        cache: dict[str, dict] | None = None,
        times: dict[str, datetime] | None = None,
    ) -> dict:
        policy = load_policy(POLICY)
        cache = {} if cache is None else cache
        if gate in cache:
            return cache[gate]
        gate_policy = policy["gates"][gate]
        gate_now = NOW if times is None else times[gate]
        predecessors = [
            self._build_test_authorization(
                predecessor,
                target=target,
                cache=cache,
                times=times,
            )
            for predecessor in gate_policy["requires"]
        ]
        sources = [
            {
                "report_type": "gate_authorization",
                "gate": predecessor["payload"]["gate"],
                "canonical_sha256": verify_document(
                    predecessor,
                    trusted_keys={self.gate_key_id: self.gate_public},
                    require_signature=True,
                ),
            }
            for predecessor in predecessors
        ]
        predecessor_validation_at = None
        if predecessors:
            predecessor_validation_at = (
                max(
                    datetime.fromisoformat(
                        predecessor["generated_at"].replace("Z", "+00:00")
                    )
                    for predecessor in predecessors
                )
                if gate.startswith("bake-")
                else gate_now
            )
        assessment = new_report(
            "gate_assessment",
            gate_policy["environment"],
            {
                "gate": gate,
                "policy_version": policy["policy_version"],
                "policy_sha256": sha256_file(POLICY),
                "checks": [{"name": "test", "passed": True}],
                "sources": sources,
                "approval_required": True,
                "decision": "ready_for_human_approval",
                "deployment_target": target if gate == "full-cutover" else None,
                "environment_id": TEST_BINDING["environment_id"],
                "environment_descriptor": TEST_BINDING["descriptor"],
                "predecessor_validation_at": (
                    predecessor_validation_at.isoformat().replace("+00:00", "Z")
                    if predecessor_validation_at is not None
                    else None
                ),
            },
            "pass",
            validity=timedelta(minutes=15),
            signing_key=self.gate_private,
            now=gate_now,
        )
        assessment_digest = verify_document(
            assessment,
            trusted_keys={self.gate_key_id: self.gate_public},
            require_signature=True,
        )
        request = create_approval_request(
            assessment,
            trusted_gate_keys={self.gate_key_id: self.gate_public},
            trusted_approver_keys={self.human_key_id: self.human_public},
            approver_key_id=self.human_key_id,
            approver="release@example.test",
            confirmation=f"APPROVE {gate} {assessment_digest}",
            environment={},
            interactive=True,
            now=gate_now,
        )
        approval = finalize_approval(
            request,
            signature=_sign_bytes(approval_signing_payload(request), self.human_private),
            trusted_approver_keys={self.human_key_id: self.human_public},
            environment={},
            interactive=True,
            now=gate_now,
        )
        authorization = authorize_gate(
            assessment,
            approval,
            policy_path=POLICY,
            predecessor_authorizations=predecessors,
            trusted_gate_keys={self.gate_key_id: self.gate_public},
            trusted_approver_keys={self.human_key_id: self.human_public},
            signing_key=self.gate_private,
            now=gate_now,
        )
        cache[gate] = authorization
        return authorization


def _key_pair(root: Path, name: str) -> tuple[Path, Path]:
    private = root / f"{name}.pem"
    public = root / f"{name}.pub.pem"
    subprocess.run(
        [
            "openssl",
            "genpkey",
            "-algorithm",
            "EC",
            "-pkeyopt",
            "ec_paramgen_curve:P-256",
            "-out",
            str(private),
        ],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    subprocess.run(
        ["openssl", "pkey", "-in", str(private), "-pubout", "-out", str(public)],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return private, public


def _sign_bytes(payload: bytes, private_key: Path) -> bytes:
    return subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", str(private_key)],
        input=payload,
        check=True,
        capture_output=True,
    ).stdout


def _test_provenance() -> dict:
    return _evidence_provenance()


def _fault_payload() -> dict:
    return {
        "check": "fault-matrix-receipts",
        "receipt_schema_version": 1,
        "objective": 9,
        "commit": COMMIT,
        "signer_key_id": "b" * 64,
        "boundary_count": 21,
        "uncovered_boundary_count": 0,
        "coverage": FAULT_COVERAGE,
        "source": {"path": "fault-matrix.json", "sha256": "c" * 64},
        "environment_binding": TEST_BINDING,
        "provenance": _test_provenance(),
    }


def _differential_payload() -> dict:
    return {
        "source": {"sha256": "a" * 64},
        "profile": "scheduled",
        "targets": ["go", "rust"],
        "target_load_elapsed_seconds": {"go": 1_800, "rust": 1_800},
        "comparison_passed": True,
        "unapproved_differences": 0,
        "gate_failure_count": 0,
        "skipped_scenario_count": 0,
        "environment_binding": TEST_BINDING,
        "provenance": _test_provenance(),
    }


def _load_payload() -> dict:
    return {
        "source": {"sha256": "b" * 64},
        "profile": "scheduled",
        "elapsed_seconds": 1_800,
        "iterations": 1,
        "command_count": 8,
        "failed_command_count": 0,
        "coverage": {
            "go_in_process_coordinator": True,
            "rust_in_process_coordinator": True,
            "synthetic_go_peer": True,
            "synthetic_rust_v2_peer": True,
            "slow_consumers": True,
            "session_replacement": True,
            "hedge": True,
            "sent_unknown": True,
        },
        "environment_binding": TEST_BINDING,
        "provenance": _test_provenance(),
    }


def _live_payload(window_end: datetime = NOW) -> dict:
    zero_counts = {
        "review_pending": 0,
        "sent_unknown": 0,
        "pending_terminals": 0,
        "pending_external": 0,
        "pending_outbox": 0,
        "pending_fees": 0,
        "fee_projection": 0,
    }
    window_start = window_end - timedelta(minutes=15)
    window_started_at = window_start.isoformat().replace("+00:00", "Z")
    window_ended_at = window_end.isoformat().replace("+00:00", "Z")
    values = {
        "availability_5xx_ratio": 0.0,
        "ownership_healthy": 1.0,
        "migration_checksum_valid": 1.0,
        "external_unknown": 0.0,
        "review_pending": 0.0,
        "pending_outbox": 0.0,
        "pending_fees": 0.0,
        "request_count": 1000.0,
        "latency_p95_ms": 100.0,
    }
    queries = {
        name: {
            "value": value,
            "window_seconds": 900,
            "bucket_seconds": 900,
            "rollup_aggregator": (
                "min"
                if name in {"ownership_healthy", "migration_checksum_valid"}
                else "sum"
                if name in {
                    "availability_5xx_ratio",
                    "external_unknown",
                    "request_count",
                }
                else "max"
            ),
            "bucket_started_at": [window_started_at],
            "window_started_at": window_started_at,
            "window_ended_at": window_ended_at,
        }
        for name, value in values.items()
    }
    return {
        "window_started_at": window_started_at,
        "window_ended_at": window_ended_at,
        "traffic_mode": "atomic_single_owner",
        "minimum_provider_version": "0.7.5",
        "coordinator": {
            "health": {
                "healthy": True,
                "ownership_healthy": True,
                "binary": "rust",
                "commit": COMMIT,
                "image_digest": CANDIDATE_IMAGE,
                "migration_checksum_valid": True,
                "public_schema_version": 7,
                "rust_schema_version": 5,
                "environment_id": TEST_BINDING["environment_id"],
                "listener_identity": "api.darkbloom.dev:443",
                "coordinator_ownership_id": "production-owner",
                "coordinator_app_id": "production-app",
            },
            "ready": {"ready": True, "ownership_healthy": None},
            "quiescence": {
                "observed": True,
                "quiescent": True,
                "ownership_healthy": True,
                "supervisor_ready": True,
                "supervisor_failed": False,
            },
            "provider_coverage": {
                "total": 2,
                "hardware": 2,
                "versions_known": 2,
                "at_or_above_floor": 2,
                "protocol_v1": 1,
                "protocol_v2": 1,
                "protocol_v2_inference_eligible": 1,
            },
            "durable_counts": {
                **zero_counts,
                "rollback_unresolved": 0,
                "go_fallback_safe": True,
            },
            "response_dates": {
                name: "Sun, 12 Jul 2026 10:00:00 GMT"
                for name in (
                    "health",
                    "ready",
                    "quiescence",
                    "attestation",
                    "utilization",
                    "metrics",
                )
            },
            "environment_id": TEST_BINDING["environment_id"],
        },
        "datadog": {
            "environment_id": TEST_BINDING["environment_id"],
            "query_environment": "production",
            "site": "us1",
            "organization_id": "production-datadog-org",
            "organization_response_date": "Sun, 12 Jul 2026 10:00:00 GMT",
            "queries": queries,
            "response_dates": ["Sun, 12 Jul 2026 10:00:00 GMT"] * len(queries),
            "query_definition_sha256": sha256_file(
                ROOT / "deploy/cutover/datadog-queries.json"
            ),
        },
        "rds": {
            "environment_id": TEST_BINDING["environment_id"],
            "database_instance_id": "prod-fingerprint",
            "database_system_identifier": "72623859790382856",
            "read_only_dsn_sha256": "d" * 64,
            "writer_endpoint_sha256": "1" * 64,
            "window_started_at": window_started_at,
            "window_ended_at": window_ended_at,
            "unique_requests": 1000,
            "go_db_mutation_writes": 0,
            "go_background_writes": 0,
            "go_financial_writes": 0,
            "go_ownership_epochs": 0,
            "go_sessions": 0,
            "unknown_ownership_epochs": 0,
            "go_audit_coverage_complete": True,
            "go_audit_trigger_states_valid": True,
            "go_audit_definition_hashes_valid": True,
            "go_audit_owner_coverage_complete": True,
            **zero_counts,
            "external_unknown": 0,
            "rollback_unresolved": 0,
            "historical_terminal_acks": 1,
            "transaction_read_only": True,
            "read_only_role": True,
            "role_has_write_privileges": False,
            "role_elevated": False,
            "is_read_replica": True,
            "query_definition_sha256": sha256_file(READ_ONLY_SQL_PATH),
        },
        "environment_binding": TEST_BINDING,
        "provenance": _test_provenance(),
    }


class _FixtureHandler(BaseHTTPRequestHandler):
    def log_message(self, *_args) -> None:
        return

    def do_GET(self) -> None:
        path = urllib.parse.urlsplit(self.path).path
        if path in {
            "/v1/admin/quiescence",
            "/v1/admin/utilization",
            "/v1/admin/metrics",
        } and self.headers.get("Authorization") != "Bearer read-only":
            self.send_error(403)
            return
        if (
            path == "/v1/providers/attestation"
            and self.headers.get("Authorization") != "Bearer public"
        ):
            self.send_error(403)
            return
        if path == "/health":
            self._json(
                {
                    "status": "ok",
                    "ownership_healthy": True,
                    "binary": "rust",
                    "build_commit": "fixture",
                    "schema": {
                        "public_version": 6,
                        "rust_version": 4,
                        "migration_checksum_valid": True,
                    },
                }
            )
        elif path == "/readyz":
            self._json({"ready": True, "ownership_healthy": True})
        elif path == "/v1/admin/quiescence":
            self._json(
                {
                    "quiescent": True,
                    "draining": True,
                    "ownership_healthy": True,
                    "supervisor": {"ready": True, "failed": False},
                }
            )
        elif path == "/v1/providers/attestation":
            self._json(
                {
                    "providers": [
                        {"trust_level": "hardware", "version": "0.7.5"},
                        {"trust_level": "hardware", "version": "0.8.0"},
                    ]
                }
            )
        elif path == "/v1/admin/utilization":
            self._json(
                {
                    "protocol": {
                        "v1": 1,
                        "v2": 1,
                        "v2_inference_eligible": 1,
                    }
                }
            )
        elif path == "/v1/admin/metrics":
            states = [
                ("inference_jobs", "review_pending"),
                ("inference_attempts", "sent_unknown"),
                ("provider_terminals", "pending"),
                ("external_events", "pending"),
                ("outbox", "pending"),
                ("fee_allocations", "pending"),
                ("fee_projection_checkpoints", "running"),
            ]
            self._json(
                {
                    "durable_states": [
                        {"relation": relation, "state": state, "count": 0}
                        for relation, state in states
                    ],
                    "rollback_guard": {
                        "go_fallback_safe": True,
                        "unresolved": 0,
                    },
                }
            )
        elif path == "/api/v2/current_user":
            self._json(
                {
                    "data": {
                        "relationships": {
                            "org": {"data": {"id": "production-datadog-org"}}
                        }
                    }
                }
            )
        elif path == "/api/v1/query":
            parameters = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
            bucket_start = int(parameters["from"][0]) * 1000
            self._json({"series": [{"pointlist": [[bucket_start, 1.0]]}]})
        else:
            self.send_error(404)

    def do_POST(self) -> None:
        self.send_error(405)

    def _json(self, body: dict) -> None:
        encoded = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)


class _fixture_server:
    def __enter__(self) -> str:
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), _FixtureHandler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        return f"http://127.0.0.1:{self.server.server_port}"

    def __exit__(self, *_args) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)


if __name__ == "__main__":
    unittest.main()

