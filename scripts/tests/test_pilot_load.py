from __future__ import annotations

import argparse
import hashlib
import json
import os
import tempfile
import threading
import unittest
import unittest.mock as mock
import urllib.parse
from dataclasses import replace
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from scripts.cutover_readiness.integrity import IntegrityError
from scripts.cutover_readiness.reports import import_pilot_report
from scripts.pilot_load.client import Observation, TargetRun, execute_trace
from scripts.pilot_load.baseline import (
    create_baseline,
    validate_baseline_for_run,
)
from scripts.pilot_load.cli import (
    _component,
    _component_coverage,
    _configure_swift,
    _existing_provider_pids,
    _loopback_socket_address,
    _peer_environment,
    _rust_environment,
    _verify_swift_auth_wiring,
)
from scripts.pilot_load.component import expected_component_tests
from scripts.pilot_load.compare import compare_database_snapshots, compare_runs
from scripts.pilot_load.config import DifferenceRule, Profile, load_difference_rules, load_profile
from scripts.pilot_load.evidence import runtime_metadata, write_evidence
from scripts.pilot_load.gates import evaluate_load_execution, evaluate_resources
from scripts.pilot_load.metrics import evaluate_baseline, evaluate_budgets
from scripts.pilot_load.oracle import evaluate_oracle, load_oracle
from scripts.pilot_load.processes import (
    isolated_environment,
    require_loopback_url,
    validate_isolated_targets,
)
from scripts.pilot_load.report import build_report, load_baseline, write_reports
from scripts.pilot_load.trace import deterministic_trace


ROOT = Path(__file__).resolve().parents[2]


class PilotLoadTests(unittest.TestCase):
    def test_component_coverage_is_derived_from_passing_commands(self) -> None:
        names = (
            "go-load",
            "rust-1000-ws",
            "rust-concurrency-slow-consumers",
            "rust-session-replacement",
            "rust-hedge",
            "rust-sent-unknown",
        )
        results = [
            {
                "name": name,
                "exit_code": 0,
                "measurement_complete": True,
                "passed_tests": sorted(expected_component_tests(name)),
            }
            for name in names
        ]
        self.assertTrue(all(_component_coverage(results).values()))
        results[-1]["exit_code"] = 1
        coverage = _component_coverage(results)
        self.assertFalse(coverage["sent_unknown"])
        self.assertTrue(coverage["hedge"])

    def test_scheduled_component_cannot_shorten_the_committed_soak(self) -> None:
        arguments = argparse.Namespace(
            duration_seconds=1,
            profile="scheduled",
            repo_root=ROOT,
            output_directory=ROOT / "artifacts/pilot-load",
        )
        with self.assertRaisesRegex(ValueError, "at least 1800 seconds"):
            _component(arguments)

    def test_committed_profiles_and_manifest_are_valid(self) -> None:
        profiles = ROOT / "e2e/pilot/profiles.json"
        quick = load_profile(profiles, "quick")
        scheduled = load_profile(profiles, "scheduled")
        hardware = load_profile(profiles, "swift-hardware")
        self.assertEqual(quick.websocket_sessions, 1000)
        self.assertEqual(quick.request_multiplier, 10)
        self.assertEqual(scheduled.duration_seconds, 1800)
        self.assertTrue(scheduled.soak)
        self.assertEqual(hardware.name, "swift-hardware")
        hardware_trace = deterministic_trace(hardware, "key", "model", "alias")
        self.assertFalse(any(request.peer_directive for request in hardware_trace))
        rules = load_difference_rules(ROOT / "e2e/pilot/allowed-differences.json")
        self.assertEqual(len({rule.id for rule in rules}), len(rules))
        oracle = load_oracle(ROOT / "e2e/pilot/expected-contract.json")
        self.assertGreaterEqual(oracle.version, 1)

    def test_trace_is_identical_for_seed_and_covers_required_scenarios(self) -> None:
        profile = _profile()
        first = deterministic_trace(profile, "key", "model", "alias")
        second = deterministic_trace(profile, "key", "model", "alias")
        self.assertEqual(first, second)
        self.assertEqual(
            [request.scenario for request in first[: len(profile.required_scenarios)]],
            list(profile.required_scenarios),
        )
        self.assertEqual(len(first), len(profile.required_scenarios) + profile.request_count)
        self.assertEqual(
            len({request.headers.get("idempotency-key") for request in first if request.method == "POST"}),
            sum(request.method == "POST" for request in first),
        )

    def test_only_manifest_rules_can_allow_differences(self) -> None:
        go = TargetRun(
            "go",
            [
                Observation(
                    "go",
                    1,
                    "chat_stream",
                    200,
                    {"content-type": "application/json"},
                    b'{"id":"go-id","value":1}',
                    None,
                    {"total": 1},
                    None,
                )
            ],
        )
        rust = TargetRun(
            "rust",
            [
                Observation(
                    "rust",
                    1,
                    "chat_stream",
                    200,
                    {"content-type": "application/json"},
                    b'{"id":"rust-id","value":2}',
                    None,
                    {"total": 1},
                    None,
                )
            ],
        )
        rules = (
            DifferenceRule(
                "dynamic-id",
                "*",
                "body/id",
                "same_type",
                "opaque IDs are independently allocated",
            ),
        )
        comparison = compare_runs(go, rust, rules)
        self.assertFalse(comparison.passed)
        self.assertEqual(comparison.allowed_differences[0].path, "body/id")
        self.assertEqual(comparison.differences[0].path, "body/value")

    def test_database_differences_also_require_manifest_rules(self) -> None:
        go = {"tables": {"balances": [{"account_id": "a", "balance_micro_usd": 2}]}}
        rust = {"tables": {"balances": [{"account_id": "a", "balance_micro_usd": 1}]}}
        comparison = compare_database_snapshots(go, rust, ())
        self.assertFalse(comparison.passed)
        self.assertEqual(
            comparison.differences[0].path,
            "database/balances/0/balance_micro_usd",
        )

    def test_database_numeric_delta_rule_requires_exact_measured_offset(self) -> None:
        rule = DifferenceRule(
            "expected-offset",
            "database",
            "database/balances/0/balance_micro_usd",
            "numeric_delta",
            "one accepted request differs",
            go_minus_rust=100,
        )
        rust = {"tables": {"balances": [{"balance_micro_usd": 1000}]}}
        accepted = compare_database_snapshots(
            {"tables": {"balances": [{"balance_micro_usd": 1100}]}},
            rust,
            (rule,),
        )
        self.assertTrue(accepted.passed)
        rejected = compare_database_snapshots(
            {"tables": {"balances": [{"balance_micro_usd": 1101}]}},
            rust,
            (rule,),
        )
        self.assertFalse(rejected.passed)

    def test_ignore_value_requires_both_fields_to_exist(self) -> None:
        go = TargetRun(
            "go",
            [
                Observation(
                    "go",
                    0,
                    "health",
                    200,
                    {"content-type": "application/json"},
                    b'{"status":"ok","binary":"go"}',
                    None,
                    {"total": 1},
                    None,
                )
            ],
        )
        rust = TargetRun(
            "rust",
            [
                Observation(
                    "rust",
                    0,
                    "health",
                    200,
                    {"content-type": "application/json"},
                    b'{"status":"ok"}',
                    None,
                    {"total": 1},
                    None,
                )
            ],
        )
        rules = (
            DifferenceRule(
                "binary",
                "health",
                "body/binary",
                "ignore_value",
                "binary names may differ",
            ),
        )
        comparison = compare_runs(go, rust, rules)
        self.assertFalse(comparison.passed)
        self.assertEqual(comparison.differences[0].path, "body/binary")
        self.assertEqual(comparison.allowed_differences, ())

    def test_client_runs_paired_deterministic_trace_and_slow_reads(self) -> None:
        profile = _profile()
        with _server("go") as go_url, _server("rust") as rust_url:
            trace = deterministic_trace(profile, "key", "model", "alias")
            go, rust, skipped = execute_trace(
                profile,
                trace,
                go_url,
                rust_url,
                None,
                None,
                5,
            )
        self.assertEqual(skipped, ["session_replacement", "hedge", "sent_unknown"])
        self.assertEqual(len(go.observations), len(rust.observations))
        self.assertGreater(go.throughput_rps, 0)
        self.assertTrue(all(item.stages_ms["total"] >= item.stages_ms["headers"] for item in go.observations))

    def test_soak_gate_uses_continuous_load_time_not_contract_preamble(self) -> None:
        profile = replace(_profile(), soak=True, duration_seconds=2)
        summary = {
            "requests": profile.request_count + len(profile.required_scenarios),
            "concurrency_levels": list(profile.concurrency_ramp),
            "slow_consumers": 1,
            "elapsed_seconds": 20,
            "load_elapsed_seconds": 1,
        }
        failures = evaluate_load_execution(
            profile,
            {"go": summary, "rust": summary},
            None,
        )
        self.assertEqual(
            {
                failure.gate
                for failure in failures
                if failure.gate.endswith(".load.soak_seconds")
            },
            {"go.load.soak_seconds", "rust.load.soak_seconds"},
        )

    def test_budget_and_prediction_regressions_fail_closed(self) -> None:
        profile = _profile()
        summary = {
            "requests": 1,
            "elapsed_seconds": 1,
            "throughput_rps": 1,
            "statuses": {"200": 1},
            "transport_errors": 0,
            "stages_ms": {},
            "prediction_error_ms": {"samples": 1, "mean_absolute": 12},
        }
        budget_failures = evaluate_budgets(profile, {"go": summary})
        self.assertEqual(budget_failures[0].gate, "go.stage.total.samples")
        baseline = {
            "schema_version": 1,
            "profile": {"name": profile.name},
            "targets": {
                "go": {
                    "throughput_rps": 1,
                    "stages_ms": {},
                    "prediction_error_ms": {"mean_absolute": 10},
                }
            },
        }
        baseline_failures = evaluate_baseline(profile, {"go": summary}, baseline)
        self.assertIn(
            "go.baseline.prediction_error.mean_absolute",
            {failure.gate for failure in baseline_failures},
        )

    def test_regression_tolerance_uses_observed_distribution_spread(self) -> None:
        profile = replace(
            _profile(),
            stage_budgets_ms={
                "total": {"p50": 100, "p95": 200, "p99": 300, "max": 400}
            },
            require_prediction_samples=True,
        )
        expected_distribution = {
            "samples": 100,
            "p50": 10.0,
            "p95": 20.0,
            "p99": 90.0,
            "max": 100.0,
        }
        baseline = {
            "profile": {"name": profile.name},
            "sample_thresholds": {
                "p50": 100,
                "p95": 100,
                "p99": 100,
                "max": 100,
            },
            "targets": {
                "go": {
                    "throughput_rps": 10.0,
                    "stages_ms": {"total": expected_distribution},
                    "prediction_error_ms": {
                        "samples": 100,
                        "p50": 5.0,
                        "p99": 105.0,
                        "mean_absolute": 10.0,
                    },
                }
            },
        }
        summary = {
            "throughput_rps": 10.0,
            "stages_ms": {
                "total": {
                    "samples": 100,
                    "p50": 10.0,
                    "p95": 60.0,
                    "p99": 90.0,
                    "max": 100.0,
                }
            },
            "prediction_error_ms": {"samples": 100, "mean_absolute": 30.0},
        }
        self.assertEqual(evaluate_baseline(profile, {"go": summary}, baseline), [])
        summary["stages_ms"]["total"]["max"] = 111.0
        self.assertIn(
            "go.baseline.total.max",
            {
                failure.gate
                for failure in evaluate_baseline(profile, {"go": summary}, baseline)
            },
        )

    def test_committed_baselines_pin_tail_sample_and_resource_metadata(self) -> None:
        profile = load_profile(ROOT / "e2e/pilot/profiles.json", "quick")
        path = ROOT / "e2e/pilot/baselines/quick.json"
        baseline = load_baseline(path, profile)
        self.assertEqual(
            baseline["sample_thresholds"],
            {"p50": 100, "p95": 100, "p99": 100, "max": 100},
        )
        self.assertEqual(set(baseline["targets"]), {"go", "rust"})
        self.assertGreaterEqual(baseline["resources"]["samples"], 2)
        self.assertRegex(baseline["source_report"]["sha256"], r"^[0-9a-f]{64}$")
        for target in baseline["targets"].values():
            for stage in target["stages_ms"].values():
                self.assertGreaterEqual(stage["samples"], 100)
        for target_name, target in baseline["targets"].items():
            for stage_name, budgets in profile.stage_budgets_ms.items():
                for quantile, ceiling in budgets.items():
                    self.assertNotEqual(
                        target["stages_ms"][stage_name][quantile],
                        ceiling,
                        f"{target_name}.{stage_name}.{quantile}",
                    )

    def test_baseline_loader_rejects_fixture_tamper_and_missing_sample_counts(self) -> None:
        profile = load_profile(ROOT / "e2e/pilot/profiles.json", "quick")
        source_baseline = ROOT / "e2e/pilot/baselines/quick.json"
        source_fixture = ROOT / "e2e/pilot/baselines/fixtures/quick-measurement.json"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture_path = root / "fixtures/quick-measurement.json"
            fixture_path.parent.mkdir()
            fixture_path.write_bytes(source_fixture.read_bytes())
            baseline_path = root / "quick.json"
            baseline_path.write_bytes(source_baseline.read_bytes())
            fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
            fixture["resources"]["samples"] = 0
            fixture_path.write_text(
                json.dumps(fixture, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "fixture hash mismatch"):
                load_baseline(baseline_path, profile)

            baseline = json.loads(source_baseline.read_text(encoding="utf-8"))
            fixture = json.loads(source_fixture.read_text(encoding="utf-8"))
            fixture["targets"]["go"]["stages_ms"]["total"].pop("samples")
            baseline["targets"] = fixture["targets"]
            fixture_path.write_text(
                json.dumps(fixture, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
            baseline["source_fixture"]["sha256"] = hashlib.sha256(
                fixture_path.read_bytes()
            ).hexdigest()
            baseline_path.write_text(
                json.dumps(baseline, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "at least 100 samples"):
                load_baseline(baseline_path, profile)

            baseline = json.loads(source_baseline.read_text(encoding="utf-8"))
            fixture = json.loads(source_fixture.read_text(encoding="utf-8"))
            ceiling = profile.stage_budgets_ms["total"]["p99"]
            fixture["targets"]["go"]["stages_ms"]["total"]["p99"] = ceiling
            fixture["targets"]["go"]["stages_ms"]["total"]["max"] = max(
                ceiling,
                fixture["targets"]["go"]["stages_ms"]["total"]["max"],
            )
            baseline["targets"] = fixture["targets"]
            fixture_path.write_text(
                json.dumps(fixture, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
            baseline["source_fixture"]["sha256"] = hashlib.sha256(
                fixture_path.read_bytes()
            ).hexdigest()
            baseline_path.write_text(
                json.dumps(baseline, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "absolute budget ceiling"):
                load_baseline(baseline_path, profile)

    def test_explicit_baseline_generation_hashes_a_passing_report(self) -> None:
        profile = load_profile(ROOT / "e2e/pilot/profiles.json", "quick")
        committed = load_baseline(
            ROOT / "e2e/pilot/baselines/quick.json",
            profile,
        )
        report = _report_from_baseline_fixture(committed, profile)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report_path = root / "report.json"
            report_path.write_text(
                json.dumps(report, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
            baseline_path = root / "baselines/quick.json"
            fixture_path = root / "baselines/fixtures/quick-measurement.json"
            create_baseline(
                report_path,
                baseline_path,
                fixture_path,
                profile,
                runtime_metadata(ROOT),
                ROOT,
            )
            generated = load_baseline(baseline_path, profile)
            self.assertEqual(
                generated["source_report"]["sha256"],
                hashlib.sha256(report_path.read_bytes()).hexdigest(),
            )
            self.assertEqual(
                generated["targets"]["go"]["stages_ms"]["total"]["samples"],
                committed["targets"]["go"]["stages_ms"]["total"]["samples"],
            )
            report["resources"].pop("samples")
            report_path.write_text(json.dumps(report), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "resource sample count"):
                create_baseline(
                    report_path,
                    baseline_path,
                    fixture_path,
                    profile,
                    runtime_metadata(ROOT),
                    ROOT,
                )

    def test_scheduled_capture_cannot_self_authorize_and_reviewed_tamper_fails(self) -> None:
        profile = load_profile(ROOT / "e2e/pilot/profiles.json", "scheduled")
        self.assertTrue(profile.require_regression_baseline)
        with self.assertRaisesRegex(ValueError, "committed versioned baseline"):
            load_baseline(None, profile)
        report = _scheduled_capture_report(profile)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report_path = root / "scheduled-report.json"
            report_path.write_text(
                json.dumps(report, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
            candidate_path = root / "candidate/candidate-baseline.json"
            candidate_fixture = root / "candidate/fixtures/measurement.json"
            source_metadata = runtime_metadata(ROOT)
            source_metadata["source"] = {
                **source_metadata["source"],
                "commit": report["metadata"]["source"]["commit"],
            }
            insufficient = json.loads(json.dumps(report))
            insufficient["targets"]["go"]["stages_ms"]["total"]["samples"] = 99
            report_path.write_text(json.dumps(insufficient), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "at least 100 samples"):
                create_baseline(
                    report_path,
                    candidate_path,
                    candidate_fixture,
                    profile,
                    source_metadata,
                    ROOT,
                    candidate=True,
                )
            insufficient = json.loads(json.dumps(report))
            insufficient["resources"]["samples"] = 99
            report_path.write_text(json.dumps(insufficient), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "resource sample count"):
                create_baseline(
                    report_path,
                    candidate_path,
                    candidate_fixture,
                    profile,
                    source_metadata,
                    ROOT,
                    candidate=True,
                )
            insufficient = json.loads(json.dumps(report))
            insufficient["targets"]["rust"]["load_elapsed_seconds"] = 1_799
            report_path.write_text(json.dumps(insufficient), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "full configured soak"):
                create_baseline(
                    report_path,
                    candidate_path,
                    candidate_fixture,
                    profile,
                    source_metadata,
                    ROOT,
                    candidate=True,
                )
            report_path.write_text(
                json.dumps(report, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
            create_baseline(
                report_path,
                candidate_path,
                candidate_fixture,
                profile,
                source_metadata,
                ROOT,
                candidate=True,
            )
            with self.assertRaisesRegex(ValueError, "unreviewed non-authorizing"):
                load_baseline(candidate_path, profile)
            reviewed_path = root / "reviewed/scheduled.json"
            reviewed_fixture = root / "reviewed/fixtures/measurement.json"
            create_baseline(
                report_path,
                reviewed_path,
                reviewed_fixture,
                profile,
                source_metadata,
                ROOT,
            )
            reviewed = load_baseline(reviewed_path, profile)
            current = {
                "source": {"commit": "3" * 40},
                "ci": {"provider": "github-actions", "run_id": "200"},
            }
            validate_baseline_for_run(reviewed, profile, current)
            current["ci"]["run_id"] = reviewed["ci"]["run_id"]
            with self.assertRaisesRegex(ValueError, "differ"):
                validate_baseline_for_run(reviewed, profile, current)
            current["ci"]["run_id"] = "200"
            current["source"]["commit"] = reviewed["source_commit"]
            with self.assertRaisesRegex(ValueError, "differ"):
                validate_baseline_for_run(reviewed, profile, current)

            reviewed_fixture.write_text("{}\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "fixture hash mismatch"):
                load_baseline(reviewed_path, profile)

    def test_launch_safety_rejects_every_non_loopback_url_shape(self) -> None:
        invalid_urls = (
            "https://api.darkbloom.dev",
            "http://api.darkbloom.dev:443",
            "http:///tmp/coordinator.sock",
            "unix:///tmp/coordinator.sock",
            "http://127.0.0.1",
            "http://user@127.0.0.1:18080",
            "http://127.0.0.2:18080",
            "http://0.0.0.0:18080",
            "http://[::]:18080",
        )
        for invalid in invalid_urls:
            with self.subTest(url=invalid), self.assertRaises(ValueError):
                validate_isolated_targets(
                    invalid,
                    "http://127.0.0.1:18081",
                    None,
                    None,
                    False,
                )
        with self.assertRaises(ValueError):
            validate_isolated_targets(
                "http://localhost:18080",
                "http://127.0.0.1:18080",
                None,
                None,
                False,
            )
        with self.assertRaises(ValueError):
            validate_isolated_targets(
                "http://127.0.0.1:18080",
                "http://127.0.0.1:18081",
                None,
                None,
                False,
                control_urls=(
                    "http://127.0.0.1:19080/control",
                    "http://remote.example:19081/control",
                ),
            )
        with self.assertRaises(ValueError):
            validate_isolated_targets(
                "http://127.0.0.1:18080",
                "http://127.0.0.1:18081",
                None,
                None,
                False,
                counter_urls=(
                    "http://127.0.0.1:18080/_pilot/counters",
                    "http:///tmp/counters.sock",
                ),
            )

    def test_websocket_and_peer_control_addresses_require_explicit_loopback(self) -> None:
        for value in (
            "ws://127.0.0.1:18080/ws/provider",
            "ws://localhost:18080/ws/provider",
            "ws://[::1]:18080/ws/provider",
        ):
            require_loopback_url(value, "provider WebSocket", schemes={"ws"})
        for value in (
            "ws:///tmp/provider.sock",
            "unix:///tmp/provider.sock",
            "ws://provider.example:18080/ws/provider",
            "ws://127.0.0.1/ws/provider",
            "ws://user@127.0.0.1:18080/ws/provider",
        ):
            with self.subTest(url=value), self.assertRaises(ValueError):
                require_loopback_url(value, "provider WebSocket", schemes={"ws"})
        self.assertEqual(
            _loopback_socket_address(
                urllib.parse.urlparse("http://localhost:19080/control")
            ),
            "127.0.0.1:19080",
        )
        self.assertEqual(
            _loopback_socket_address(
                urllib.parse.urlparse("http://[::1]:19080/control")
            ),
            "[::1]:19080",
        )
        with self.assertRaises(ValueError):
            _loopback_socket_address(
                urllib.parse.urlparse("http://provider.example:19080/control")
            )

    def test_launch_safety_requires_distinct_marked_loopback_databases(self) -> None:
        valid_go = (
            "postgresql://user:password@localhost:5432/"
            "pilot_objective9_go?sslmode=disable"
        )
        valid_rust = (
            "postgresql://user:password@127.0.0.1:5432/"
            "pilot_objective9_rust?sslmode=disable"
        )
        validate_isolated_targets(
            "http://127.0.0.1:18080",
            "http://127.0.0.1:18081",
            valid_go,
            valid_rust,
            True,
        )
        invalid_databases = (
            "postgresql:///pilot_local",
            "postgresql://user@remote.example:5432/pilot_local",
            "postgresql://user@127.0.0.1/pilot_local",
            "postgresql://user@127.0.0.1:5432/production",
            "postgresql://user@127.0.0.1:5432/postgres",
            "postgresql://user@127.0.0.1:5432/team/pilot_local",
            "postgresql://user@127.0.0.1:5432/pilot_local%2Fproduction",
            "postgresql://user@127.0.0.1:5432/PILOT_local",
            "postgresql://user@127.0.0.1:5432/pilot_local?host=",
            "postgresql://user@127.0.0.1:5432/pilot_local?service=prod",
            "postgresql://user@127.0.0.1:5432/pilot_local?dbname=production",
            "postgresql+unix://user@localhost:5432/pilot_local",
        )
        for invalid in invalid_databases:
            with self.subTest(database=invalid), self.assertRaises(ValueError):
                validate_isolated_targets(
                    "http://127.0.0.1:18080",
                    "http://127.0.0.1:18081",
                    invalid,
                    valid_rust,
                    True,
                )
        with self.assertRaises(ValueError):
            validate_isolated_targets(
                "http://127.0.0.1:18080",
                "http://127.0.0.1:18081",
                valid_go,
                valid_go.replace("user:password", "other:secret").replace(
                    "localhost", "127.0.0.1"
                ),
                True,
            )
        with mock.patch.dict(
            os.environ,
            {
                "EIGENINFERENCE_DATABASE_URL": "postgresql://production.example/prod",
                "DATABASE_URL": "postgresql://production.example/prod",
                "PGHOST": "production.example",
                "PGSERVICE": "production",
                "PGPASSWORD": "secret",
            },
        ):
            environment = isolated_environment(
                {
                    "EIGENINFERENCE_PORT": "18080",
                    "PGHOST": "override.example",
                    "PGSERVICE": "override-production",
                }
            )
        self.assertEqual(environment["EIGENINFERENCE_PORT"], "18080")
        for name in (
            "EIGENINFERENCE_DATABASE_URL",
            "DATABASE_URL",
            "PGHOST",
            "PGSERVICE",
            "PGPASSWORD",
        ):
            self.assertNotIn(name, environment)
        self.assertEqual(environment["PGPASSFILE"], os.devnull)
        self.assertEqual(environment["PGSERVICEFILE"], os.devnull)

    def test_measured_coordinator_session_protocol_and_trust_counters_are_required(self) -> None:
        profile = replace(
            _profile(),
            require_peer_counters=True,
            require_resource_counters=True,
        )
        process = {
            "available": True,
            "alive_end": True,
            "rss_growth_bytes": 0,
            "tasks_growth": 0,
            "fd_growth": 0,
        }
        resources = {
            "samples": 2,
            "processes": {
                "go-coordinator": dict(process),
                "rust-coordinator": dict(process),
            },
            "databases": {
                name: {"source": "runtime_counter", "utilization_peak": 0}
                for name in ("go", "rust")
            },
            "mailboxes": {
                name: {"available": True, "utilization_peak": 0}
                for name in ("go", "rust")
            },
            "sessions": {
                "go": {
                    "available": True,
                    "provider_sessions_end": 1000,
                    "provider_sessions_min": 999,
                    "protocol_v1_sessions_end": 1000,
                    "protocol_v2_sessions_end": 0,
                    "untrusted_sessions_end": 0,
                    "self_signed_sessions_end": 1000,
                    "hardware_sessions_end": 0,
                },
                "rust": {
                    "available": True,
                    "provider_sessions_end": 1000,
                    "provider_sessions_min": 999,
                    "protocol_v1_sessions_end": 0,
                    "protocol_v2_sessions_end": 1000,
                    "untrusted_sessions_end": 0,
                    "self_signed_sessions_end": 1000,
                    "hardware_sessions_end": 0,
                },
            },
        }
        self.assertEqual(evaluate_resources(profile, resources), [])
        resources["sessions"]["rust"]["self_signed_sessions_end"] = 999
        self.assertIn(
            "rust.coordinator_sessions.self_signed_sessions_end",
            {failure.gate for failure in evaluate_resources(profile, resources)},
        )

    def test_swift_hardware_wires_exact_distinct_tokens_for_auth_handshake(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            binary = temporary / "darkbloom"
            binary.write_text("#!/bin/sh\n", encoding="utf-8")
            binary.chmod(0o755)
            go_token = temporary / "go-token"
            rust_token = temporary / "rust-token"
            go_token.write_text("go-secret\n", encoding="utf-8")
            rust_token.write_text("rust-secret\n", encoding="utf-8")
            arguments = argparse.Namespace(
                profile="swift-hardware",
                swift_provider_binary=binary,
                swift_go_auth_token_path=go_token,
                swift_rust_auth_token_path=rust_token,
                require_feature=[],
                repo_root=ROOT,
                go_url="http://127.0.0.1:18080",
                rust_url="http://127.0.0.1:18081",
                model="darkbloom/pilot-text",
                provider_token="unset",
                go_peer_command=None,
                rust_peer_command=None,
                profiles=ROOT / "e2e/pilot/profiles.json",
                rust_database_url="postgres://pilot@127.0.0.1:5432/pilot_swift",
                rust_database_pool_max=32,
                counter_token="c" * 32,
                api_key="objective9-consumer-key",
                alias="darkbloom-pilot",
            )
            with (
                mock.patch("scripts.pilot_load.cli.platform.system", return_value="Darwin"),
                mock.patch("scripts.pilot_load.cli.platform.machine", return_value="arm64"),
                mock.patch(
                    "scripts.pilot_load.cli._existing_provider_pids",
                    return_value=[1234],
                ),
                self.assertRaises(RuntimeError),
            ):
                _configure_swift(arguments)
            self.assertIsNone(arguments.go_peer_command)
            with (
                mock.patch("scripts.pilot_load.cli.platform.system", return_value="Darwin"),
                mock.patch("scripts.pilot_load.cli.platform.machine", return_value="arm64"),
                mock.patch("scripts.pilot_load.cli._existing_provider_pids", return_value=[]),
            ):
                _configure_swift(arguments)
            self.assertIn("start --foreground", arguments.go_peer_command)
            self.assertIn("start --foreground", arguments.rust_peer_command)
            self.assertEqual(
                arguments.swift_provider_tokens,
                {"go": "go-secret", "rust": "rust-secret"},
            )
            go_environment = _peer_environment(arguments, "go")
            rust_environment = _peer_environment(arguments, "rust")
            for name in (
                "HOME",
                "DARKBLOOM_PID_FILE",
                "DARKBLOOM_STATE_FILE",
                "DARKBLOOM_LOADED_MODELS_FILE",
                "DARKBLOOM_WATCHDOG_STATE",
                "DARKBLOOM_LOCAL_DIR",
            ):
                self.assertNotEqual(go_environment[name], rust_environment[name])
            for environment in (go_environment, rust_environment):
                self.assertEqual(environment["DARKBLOOM_NO_UPDATE_CHECK"], "1")
                config = (
                    Path(environment["HOME"]) / ".config/darkbloom/provider.toml"
                ).read_text(encoding="utf-8")
                self.assertIn("auto_update = false", config)
                self.assertIn("auto_restart = false", config)
            go_isolated_token = Path(go_environment["DARKBLOOM_AUTH_TOKEN_PATH"])
            rust_isolated_token = Path(rust_environment["DARKBLOOM_AUTH_TOKEN_PATH"])
            self.assertNotEqual(go_isolated_token, go_token)
            self.assertNotEqual(rust_isolated_token, rust_token)
            self.assertNotEqual(go_isolated_token, rust_isolated_token)
            self.assertEqual(go_isolated_token.read_text(encoding="utf-8").strip(), "go-secret")
            self.assertEqual(
                rust_isolated_token.read_text(encoding="utf-8").strip(),
                "rust-secret",
            )
            rust_coordinator_environment = _rust_environment(arguments, temporary)
            credentials = json.loads(
                Path(
                    rust_coordinator_environment[
                        "EIGENINFERENCE_RUST_PROVIDER_CREDENTIALS_FILE"
                    ]
                ).read_text(encoding="utf-8")
            )
            self.assertEqual(len(credentials), 1)
            self.assertEqual(credentials[0]["token"], "rust-secret")
            self.assertNotIn("rust-secret-", credentials[0]["token"])
            _verify_swift_auth_wiring(
                arguments,
                rust_coordinator_environment,
                {"go": go_environment, "rust": rust_environment},
            )
            credentials[0]["token"] = "rust-secret-000000"
            credential_path = Path(
                rust_coordinator_environment[
                    "EIGENINFERENCE_RUST_PROVIDER_CREDENTIALS_FILE"
                ]
            )
            credential_path.write_text(json.dumps(credentials), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "exactly match"):
                _verify_swift_auth_wiring(
                    arguments,
                    rust_coordinator_environment,
                    {"go": go_environment, "rust": rust_environment},
                )
            rust_token.write_text("go-secret\n", encoding="utf-8")
            with (
                mock.patch("scripts.pilot_load.cli.platform.system", return_value="Darwin"),
                mock.patch("scripts.pilot_load.cli.platform.machine", return_value="arm64"),
                mock.patch("scripts.pilot_load.cli._existing_provider_pids", return_value=[]),
                self.assertRaisesRegex(RuntimeError, "distinct auth tokens"),
            ):
                _configure_swift(arguments)

    def test_swift_pid_permission_denial_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            pid_path = home / ".darkbloom/provider.pid"
            pid_path.parent.mkdir()
            pid_path.write_text("1234\n", encoding="utf-8")
            process_list = mock.Mock(stdout="")
            with (
                mock.patch("scripts.pilot_load.cli.Path.home", return_value=home),
                mock.patch(
                    "scripts.pilot_load.cli.os.kill",
                    side_effect=PermissionError,
                ),
                mock.patch(
                    "scripts.pilot_load.cli.subprocess.run",
                    return_value=process_list,
                ),
            ):
                self.assertEqual(
                    _existing_provider_pids(home / "darkbloom"),
                    [1234],
                )

    def test_local_evidence_ignores_ambient_github_identity(self) -> None:
        with mock.patch.dict(
            os.environ,
            {
                "GITHUB_ACTIONS": "false",
                "GITHUB_REPOSITORY": "owner/production",
                "GITHUB_REF": "refs/heads/production",
            },
        ):
            metadata = runtime_metadata(ROOT)
        self.assertEqual(metadata["ci"]["provider"], "local")
        self.assertIsNone(metadata["source"]["repository"])
        self.assertIsNone(metadata["source"]["ref"])

    def test_oracle_fails_when_both_implementations_regress_identically(self) -> None:
        profile = _profile()
        request = deterministic_trace(profile, "key", "model", "alias")[0]
        runs = {}
        for implementation in ("go", "rust"):
            runs[implementation] = TargetRun(
                implementation,
                [
                    Observation(
                        implementation,
                        request.index,
                        request.scenario,
                        500,
                        {"content-type": "application/json"},
                        b'{"status":"broken"}',
                        None,
                        {"total": 1},
                        None,
                    )
                ],
            )
        failures = evaluate_oracle(
            load_oracle(ROOT / "e2e/pilot/expected-contract.json"),
            (request,),
            runs,
        )
        self.assertEqual(
            {failure.gate for failure in failures if failure.gate.endswith(".status")},
            {"go.oracle.health.status", "rust.oracle.health.status"},
        )

    def test_oracle_implementation_override_does_not_allow_identical_regression(self) -> None:
        profile = _profile()
        request = next(
            request
            for request in deterministic_trace(profile, "key", "model", "alias")
            if request.scenario == "sent_unknown"
        )
        runs = {
            implementation: TargetRun(
                implementation,
                [
                    Observation(
                        implementation,
                        request.index,
                        request.scenario,
                        499,
                        {"content-type": "application/json"},
                        b'{"error":{"code":"request_cancelled"}}',
                        None,
                        {"total": 1},
                        None,
                    )
                ],
            )
            for implementation in ("go", "rust")
        }
        failures = evaluate_oracle(
            load_oracle(ROOT / "e2e/pilot/expected-contract.json"),
            (request,),
            runs,
        )
        status_failures = {
            failure.gate for failure in failures if failure.gate.endswith(".status")
        }
        self.assertEqual(status_failures, {"go.oracle.sent_unknown.status"})

    def test_oracle_enforces_implementation_specific_alias_model_semantics(self) -> None:
        profile = _profile()
        request = next(
            request
            for request in deterministic_trace(
                profile,
                "key",
                "darkbloom/pilot-text",
                "darkbloom-pilot",
            )
            if request.scenario == "chat_alias_stream"
        )
        body = (
            b'data: {"model":"darkbloom/pilot-text","choices":[{"delta":{"content":"ok"}}]}\n\n'
            b"data: [DONE]\n\n"
        )
        runs = {
            implementation: TargetRun(
                implementation,
                [
                    Observation(
                        implementation,
                        request.index,
                        request.scenario,
                        200,
                        {"content-type": "text/event-stream"},
                        body,
                        None,
                        {"total": 1},
                        None,
                        stream=True,
                    )
                ],
            )
            for implementation in ("go", "rust")
        }
        failures = evaluate_oracle(
            load_oracle(ROOT / "e2e/pilot/expected-contract.json"),
            (request,),
            runs,
        )
        model_failures = {
            failure.gate for failure in failures if failure.gate.endswith(".sse.model")
        }
        self.assertEqual(model_failures, {"go.oracle.chat_alias_stream.sse.model"})

    def test_oracle_keeps_expected_models_for_repeated_soak_cycles(self) -> None:
        observation = Observation(
            "go",
            10_000,
            "load_000001_000001",
            200,
            {"content-type": "application/json"},
            (
                b'{"object":"chat.completion","model":"darkbloom-pilot",'
                b'"choices":[{"message":{"content":"ok"}}]}'
            ),
            None,
            {"total": 1},
            None,
            expected_response_model="darkbloom-pilot",
        )
        failures = evaluate_oracle(
            load_oracle(ROOT / "e2e/pilot/expected-contract.json"),
            (),
            {"go": TargetRun("go", [observation])},
        )
        self.assertEqual(failures, [])

    def test_reports_are_json_and_markdown_and_baseline_compatible(self) -> None:
        profile = _profile()
        comparison = compare_runs(TargetRun("go"), TargetRun("rust"), ())
        summaries = {
            name: {
                "requests": 0,
                "elapsed_seconds": 1,
                "throughput_rps": 0,
                "statuses": {},
                "transport_errors": 0,
                "stages_ms": {},
                "prediction_error_ms": {"samples": 0, "mean_absolute": None},
            }
            for name in ("go", "rust")
        }
        report = build_report(
            profile,
            summaries,
            comparison,
            None,
            None,
            None,
            [],
            [],
            {"test": True},
        )
        with tempfile.TemporaryDirectory() as directory:
            json_path = Path(directory) / "report.json"
            markdown_path = Path(directory) / "report.md"
            write_reports(report, json_path, markdown_path)
            parsed = json.loads(json_path.read_text(encoding="utf-8"))
            self.assertEqual(parsed["schema_version"], 1)
            self.assertIn("Coordinator differential pilot report", markdown_path.read_text(encoding="utf-8"))

    def test_capture_report_succeeds_only_as_baseline_review_required(self) -> None:
        profile = load_profile(ROOT / "e2e/pilot/profiles.json", "scheduled")
        comparison = compare_runs(TargetRun("go"), TargetRun("rust"), ())
        report = build_report(
            profile,
            {},
            comparison,
            None,
            None,
            None,
            [],
            [],
            {"regression_baseline_mode": "capture"},
        )
        self.assertEqual(report["verdict"], "baseline_review_required")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "capture.json"
            path.write_text(json.dumps(report), encoding="utf-8")
            markdown = Path(directory) / "capture.md"
            markdown.write_text("capture\n", encoding="utf-8")
            evidence_path = write_evidence(
                path,
                markdown,
                runtime_metadata(ROOT),
                profile_name="scheduled",
                minimum_samples={"p50": 100, "p95": 100, "p99": 100, "max": 100},
                authorizing=False,
            )
            evidence = json.loads(evidence_path.read_text(encoding="utf-8"))
            self.assertFalse(evidence["authorization"]["eligible"])
            self.assertFalse(evidence["signature"]["required_in_ci"])
            with self.assertRaisesRegex(IntegrityError, "non-authorizing"):
                import_pilot_report(path)
            report["verdict"] = "pass"
            report["authorization_eligible"] = True
            report["metadata"] = {
                "regression_baseline_mode": "measured",
                "source": {"commit": "2" * 40},
                "ci": {"provider": "github-actions", "run_id": "200"},
                "baseline_provenance": None,
            }
            path.write_text(json.dumps(report), encoding="utf-8")
            with self.assertRaisesRegex(IntegrityError, "distinct prior"):
                import_pilot_report(path)


def _report_from_baseline_fixture(baseline: dict, profile: Profile) -> dict:
    return {
        "schema_version": 1,
        "generated_at": baseline["generated_at"],
        "profile": {
            "name": profile.name,
            "seed": profile.seed,
            "duration_seconds": profile.duration_seconds,
            "soak": profile.soak,
            "request_count": profile.request_count,
            "websocket_sessions": profile.websocket_sessions,
            "concurrency_ramp": list(profile.concurrency_ramp),
        },
        "metadata": {
            "source": baseline["source"],
            "tool": baseline["tool"],
            "runner_image": baseline["environment"],
            "ci": baseline["ci"],
            "input_artifacts": baseline["inputs"],
            "executable_artifacts": baseline["executables"],
            "database_pool_max": baseline["execution_environment"][
                "database_pool_max"
            ],
            "regression_baseline_mode": baseline["execution_environment"][
                "source_baseline_mode"
            ],
        },
        "verdict": "pass",
        "targets": baseline["targets"],
        "comparison": {
            "passed": True,
            "differences": [],
            "allowed_differences": [],
        },
        "skipped_scenarios": [],
        "resources": baseline["resources"],
        "gate_failures": [],
    }


def _scheduled_capture_report(profile: Profile) -> dict:
    quick = load_baseline(
        ROOT / "e2e/pilot/baselines/quick.json",
        load_profile(ROOT / "e2e/pilot/profiles.json", "quick"),
    )
    report = _report_from_baseline_fixture(quick, profile)
    report["verdict"] = "baseline_review_required"
    report["authorization_eligible"] = False
    report["profile"].update(
        {
            "duration_seconds": profile.duration_seconds,
            "soak": True,
        }
    )
    report["metadata"]["regression_baseline_mode"] = "capture"
    report["metadata"]["source"] = {
        **report["metadata"]["source"],
        "commit": "1" * 40,
    }
    report["metadata"]["ci"] = {
        **report["metadata"]["ci"],
        "provider": "github-actions",
        "run_id": "100",
    }
    report["targets"] = json.loads(json.dumps(report["targets"]))
    report["resources"] = json.loads(json.dumps(report["resources"]))
    report["resources"]["samples"] = profile.duration_seconds
    for target in report["targets"].values():
        target["load_elapsed_seconds"] = profile.duration_seconds
    return report


def _profile() -> Profile:
    required = (
        "health",
        "models_authorized",
        "models_unauthorized",
        "chat_stream",
        "chat_nonstream",
        "chat_alias_stream",
        "unknown_model",
        "malformed_json",
        "session_replacement",
        "hedge",
        "sent_unknown",
    )
    return Profile(
        name="test",
        description="test",
        seed=9,
        duration_seconds=2,
        soak=False,
        base_requests=1,
        request_multiplier=2,
        chunk_multiplier=10,
        websocket_sessions=1000,
        concurrency_ramp=(1, 2),
        slow_consumer_fraction=1,
        slow_consumer_delay_ms=1,
        required_scenarios=required,
        stage_budgets_ms={"total": {"p50": 1, "p95": 2, "p99": 3, "max": 4}},
        resource_bounds={
            "rss_growth_bytes": 1,
            "tasks_growth": 1,
            "fd_growth": 1,
            "mailbox_utilization": 1,
            "database_pool_utilization": 1,
        },
        regression_thresholds={
            "latency_percent": 10,
            "throughput_percent": 10,
            "prediction_error_percent": 10,
            "resource_percent": 10,
        },
        require_billing_snapshot=False,
        require_prediction_samples=False,
        require_resource_counters=False,
        require_peer_counters=False,
    )


class _Handler(BaseHTTPRequestHandler):
    implementation = "test"

    def log_message(self, *_args) -> None:
        return

    def do_GET(self) -> None:
        if self.path == "/health":
            self._json(200, {"status": "ok", "binary": self.implementation})
        elif self.path == "/v1/models" and self.headers.get("authorization"):
            self._json(200, {"object": "list", "data": [{"id": "model"}]})
        else:
            self._json(401, {"error": {"type": "authentication_error", "code": "unauthorized"}})

    def do_POST(self) -> None:
        length = int(self.headers.get("content-length", "0"))
        body = self.rfile.read(length)
        try:
            request = json.loads(body)
        except json.JSONDecodeError:
            self._json(400, {"error": {"type": "invalid_request_error", "code": "invalid_json"}})
            return
        if request.get("model") == "objective9/missing":
            self._json(404, {"error": {"type": "invalid_request_error", "code": "model_not_found"}})
            return
        if request.get("stream"):
            content = (
                'data: {"id":"opaque","object":"chat.completion.chunk","choices":'
                '[{"index":0,"delta":{"content":"ok"},"finish_reason":"stop"}]}\n\n'
                "data: [DONE]\n\n"
            ).encode()
            self.send_response(200)
            self.send_header("content-type", "text/event-stream")
            self.send_header("content-length", str(len(content)))
            self.end_headers()
            self.wfile.write(content)
            return
        self._json(
            200,
            {
                "id": "opaque",
                "object": "chat.completion",
                "choices": [{"index": 0, "message": {"role": "assistant", "content": "ok"}}],
            },
        )

    def _json(self, status: int, value: dict) -> None:
        encoded = json.dumps(value, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)


class _server:
    def __init__(self, implementation: str) -> None:
        self.implementation = implementation

    def __enter__(self) -> str:
        handler = type(
            f"{self.implementation.title()}Handler",
            (_Handler,),
            {"implementation": self.implementation},
        )
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        return f"http://127.0.0.1:{self.server.server_port}"

    def __exit__(self, *_args) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)


if __name__ == "__main__":
    unittest.main()
