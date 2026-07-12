from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import secrets
import shlex
import subprocess
import sys
import tempfile
import time
import urllib.parse
from datetime import datetime, timezone
from pathlib import Path

from .baseline import create_baseline, validate_baseline_for_run
from .client import execute_trace
from .component import (
    RUST_COMPONENT_TESTS,
    component_coverage as _component_coverage,
    expected_component_tests as _expected_component_tests,
    measured_component_tests as _measured_component_tests,
)
from .compare import compare_database_snapshots, compare_runs
from .config import load_difference_rules, load_profile
from .database import collect_database_snapshot
from .evidence import artifact_metadata, runtime_metadata, write_evidence
from .gates import (
    evaluate_database_availability,
    evaluate_load_execution,
    evaluate_required_scenarios,
    evaluate_resource_baseline,
    evaluate_resources,
)
from .metrics import evaluate_baseline, evaluate_budgets, summarize_target
from .oracle import evaluate_oracle, load_oracle
from .processes import (
    ResourceSampler,
    fetch_peer_counters,
    isolated_environment,
    launch,
    require_loopback_url,
    validate_isolated_targets,
    wait_peer_ready,
    wait_provider_count,
    wait_ready,
)
from .report import build_report, load_baseline, write_reports
from .trace import deterministic_trace


PROCESS_PRIVATE = "XasIfmJKikt54X+Lg4AO5m87sSkmGLb9HC+LJ/+I4Os="
PROCESS_PUBLIC = "3p7bfXt9wbTTW2HC7OQ1Nz+DQ8hbeGdNrfx+FG+IK08="
PROVIDER_ID = "00000000-0000-0000-0000-000000000901"


def main(argv: list[str] | None = None) -> int:
    parser = _parser()
    arguments = parser.parse_args(argv)
    try:
        if arguments.command == "component":
            return _component(arguments)
        if arguments.command == "baseline":
            return _baseline(arguments)
        if arguments.command == "swift-hardware":
            _configure_swift(arguments)
        return _run(arguments)
    except (ValueError, RuntimeError, OSError) as error:
        print(f"pilot-load: {error}", file=sys.stderr)
        return 2


def _parser() -> argparse.ArgumentParser:
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(
        description="Isolated Go/Rust coordinator load, soak, and differential pilot"
    )
    subparsers = parser.add_subparsers(dest="command", required=True)
    run = subparsers.add_parser("run", help="run identical HTTP traces against isolated coordinators")
    _run_arguments(run, root)
    component = subparsers.add_parser(
        "component",
        help="run the real in-process Go and Rust synthetic-peer stress profiles",
    )
    component.add_argument("--profile", choices=("quick", "scheduled"), default="quick")
    component.add_argument("--duration-seconds", type=int)
    component.add_argument(
        "--non-authorizing",
        action="store_true",
        help="mark component evidence as ineligible for signing or cutover",
    )
    component.add_argument("--output-directory", type=Path, default=root / "artifacts/pilot-load")
    component.add_argument("--repo-root", type=Path, default=root)
    baseline = subparsers.add_parser(
        "baseline",
        help="generate a hash-pinned measured regression baseline from a passing report",
    )
    baseline.add_argument("--profile", choices=("quick", "scheduled", "swift-hardware"), required=True)
    baseline.add_argument("--profiles", type=Path, default=root / "e2e/pilot/profiles.json")
    baseline.add_argument("--report", type=Path, required=True)
    baseline.add_argument("--output", type=Path)
    baseline.add_argument("--fixture", type=Path)
    baseline.add_argument(
        "--candidate",
        action="store_true",
        help="write an unreviewed, non-authorizing scheduled capture candidate",
    )
    baseline.add_argument("--repo-root", type=Path, default=root)
    swift = subparsers.add_parser(
        "swift-hardware",
        help="require and use a real Apple-Silicon Swift provider for the differential run",
    )
    _run_arguments(swift, root)
    swift.set_defaults(profile="swift-hardware")
    swift.add_argument("--swift-provider-binary", type=Path)
    swift.add_argument("--swift-go-auth-token-path", type=Path, required=True)
    swift.add_argument("--swift-rust-auth-token-path", type=Path, required=True)
    swift.add_argument(
        "--require-feature",
        action="append",
        choices=("session_replacement", "hedge", "sent_unknown"),
        default=[],
        help="require an injectable synthetic-only fault feature",
    )
    return parser


def _baseline(arguments: argparse.Namespace) -> int:
    profile = load_profile(arguments.profiles, arguments.profile)
    if arguments.candidate and (
        arguments.output is None or arguments.fixture is None
    ):
        raise ValueError("candidate baseline requires explicit --output and --fixture paths")
    output = arguments.output or (
        arguments.repo_root / "e2e/pilot/baselines" / f"{profile.name}.json"
    )
    fixture = arguments.fixture or (
        output.parent / "fixtures" / f"{profile.name}-measurement.json"
    )
    committed_directory = (
        arguments.repo_root / "e2e/pilot/baselines"
    ).resolve()
    if arguments.candidate and output.resolve().is_relative_to(committed_directory):
        raise ValueError("candidate baseline cannot be written to the committed baseline directory")
    create_baseline(
        arguments.report,
        output,
        fixture,
        profile,
        runtime_metadata(arguments.repo_root),
        arguments.repo_root,
        candidate=arguments.candidate,
    )
    print(f"baseline={output}")
    print(f"fixture={fixture}")
    return 0


def _run_arguments(parser: argparse.ArgumentParser, root: Path) -> None:
    parser.add_argument("--profile", choices=("quick", "scheduled", "swift-hardware"), default="quick")
    parser.add_argument("--profiles", type=Path, default=root / "e2e/pilot/profiles.json")
    parser.add_argument(
        "--allowed-differences",
        type=Path,
        default=root / "e2e/pilot/allowed-differences.json",
    )
    parser.add_argument(
        "--oracle",
        type=Path,
        default=root / "e2e/pilot/expected-contract.json",
    )
    parser.add_argument("--baseline", type=Path)
    parser.add_argument(
        "--capture-baseline",
        action="store_true",
        help="run absolute/differential gates without a prior regression baseline",
    )
    parser.add_argument("--go-url", default="http://127.0.0.1:18080")
    parser.add_argument("--rust-url", default="http://127.0.0.1:18081")
    parser.add_argument("--go-command")
    parser.add_argument("--rust-command")
    parser.add_argument("--go-setup-command")
    parser.add_argument("--rust-setup-command")
    parser.add_argument("--go-peer-command")
    parser.add_argument("--rust-peer-command")
    parser.add_argument("--go-peer-control")
    parser.add_argument("--rust-peer-control")
    parser.add_argument("--go-counter-url")
    parser.add_argument("--rust-counter-url")
    parser.add_argument(
        "--counter-token",
        help="secret bearer token shared only with pilot-build counter and peer-control endpoints",
    )
    parser.add_argument("--go-database-url")
    parser.add_argument("--rust-database-url")
    parser.add_argument("--go-database-pool-max", type=int, default=32)
    parser.add_argument("--rust-database-pool-max", type=int, default=16)
    parser.add_argument("--api-key", default="objective9-consumer-key")
    parser.add_argument("--provider-token", default="objective9-provider-token")
    parser.add_argument("--model", default="darkbloom/pilot-text")
    parser.add_argument("--alias", default="darkbloom-pilot")
    parser.add_argument("--timeout-seconds", type=float, default=300)
    parser.add_argument("--output-directory", type=Path, default=root / "artifacts/pilot-load")
    parser.add_argument("--repo-root", type=Path, default=root)


def _run(arguments: argparse.Namespace) -> int:
    profile = load_profile(arguments.profiles, arguments.profile)
    provenance = runtime_metadata(arguments.repo_root)
    if arguments.capture_baseline and arguments.baseline is not None:
        raise ValueError("--capture-baseline cannot be combined with --baseline")
    rules = load_difference_rules(arguments.allowed_differences)
    oracle = load_oracle(arguments.oracle)
    if arguments.counter_token is None:
        arguments.counter_token = secrets.token_urlsafe(32)
    if len(arguments.counter_token) < 32:
        raise ValueError("--counter-token must contain at least 32 characters")
    launching = bool(arguments.go_command or arguments.rust_command)
    if bool(arguments.go_command) != bool(arguments.rust_command):
        raise ValueError("launch mode requires both --go-command and --rust-command")
    if bool(arguments.go_peer_command) != bool(arguments.rust_peer_command):
        raise ValueError("peer launch mode requires both --go-peer-command and --rust-peer-command")
    validate_isolated_targets(
        arguments.go_url,
        arguments.rust_url,
        arguments.go_database_url,
        arguments.rust_database_url,
        launching,
        control_urls=(arguments.go_peer_control, arguments.rust_peer_control),
        counter_urls=(arguments.go_counter_url, arguments.rust_counter_url),
    )
    directives = {
        request.peer_directive
        for request in deterministic_trace(
            profile,
            arguments.api_key,
            arguments.model,
            arguments.alias,
        )
        if request.peer_directive
    }
    if directives and (not arguments.go_peer_control or not arguments.rust_peer_control):
        raise ValueError(
            "profile requires peer control URLs for: "
            + ", ".join(sorted(directives))
        )
    if profile.require_resource_counters:
        if not launching:
            raise ValueError("profile requires launch mode for process resource counters")
        if not arguments.go_counter_url or not arguments.rust_counter_url:
            raise ValueError("profile requires both --go-counter-url and --rust-counter-url")
    if profile.require_billing_snapshot and (
        not arguments.go_database_url or not arguments.rust_database_url
    ):
        raise ValueError("profile requires both database URLs for billing snapshots")
    baseline_path = None if arguments.capture_baseline else arguments.baseline
    if (
        baseline_path is None
        and profile.require_regression_baseline
        and not arguments.capture_baseline
    ):
        baseline_path = (
            arguments.repo_root / "e2e/pilot/baselines" / f"{profile.name}.json"
        )
    baseline = load_baseline(baseline_path, profile) if baseline_path else None
    if baseline is not None:
        validate_baseline_for_run(baseline, profile, provenance)
        expected_pool_max = baseline["execution_environment"]["database_pool_max"]
        actual_pool_max = {
            "go": arguments.go_database_pool_max,
            "rust": arguments.rust_database_pool_max,
        }
        if expected_pool_max != actual_pool_max:
            raise ValueError(
                "baseline database pool environment does not match this run: "
                f"expected {expected_pool_max}, got {actual_pool_max}"
            )
    output = arguments.output_directory / profile.name
    output.mkdir(parents=True, exist_ok=True)
    managed = []
    sampler = None
    try:
        coordinator_environments = {}
        peer_environments = {}
        if launching:
            _run_setup(arguments.go_setup_command, "go", arguments.go_database_url, arguments.repo_root)
            _run_setup(
                arguments.rust_setup_command,
                "rust",
                arguments.rust_database_url,
                arguments.repo_root,
            )
            coordinator_environments = {
                "go": _go_environment(arguments),
                "rust": _rust_environment(arguments, output),
            }
        if arguments.go_peer_command:
            peer_environments["go"] = _peer_environment(arguments, "go")
        if arguments.rust_peer_command:
            peer_environments["rust"] = _peer_environment(arguments, "rust")
        if arguments.command == "swift-hardware":
            _verify_swift_auth_wiring(
                arguments,
                coordinator_environments["rust"],
                peer_environments,
            )
        if launching:
            go_process = launch(
                "go-coordinator",
                arguments.go_command,
                output / "logs",
                coordinator_environments["go"],
            )
            managed.append(go_process)
            rust_process = launch(
                "rust-coordinator",
                arguments.rust_command,
                output / "logs",
                coordinator_environments["rust"],
            )
            managed.append(rust_process)
            wait_ready(go_process, arguments.go_url)
            wait_ready(rust_process, arguments.rust_url)
        if arguments.go_peer_command:
            go_peer = launch(
                "go-peer",
                arguments.go_peer_command,
                output / "logs",
                peer_environments["go"],
            )
            managed.append(go_peer)
        if arguments.rust_peer_command:
            rust_peer = launch(
                "rust-peer",
                arguments.rust_peer_command,
                output / "logs",
                peer_environments["rust"],
            )
            managed.append(rust_peer)
        if arguments.go_peer_command:
            if arguments.command == "swift-hardware":
                wait_provider_count(
                    go_peer,
                    arguments.go_url,
                    profile.websocket_sessions,
                )
                wait_provider_count(
                    rust_peer,
                    arguments.rust_url,
                    profile.websocket_sessions,
                )
            else:
                wait_peer_ready(
                    go_peer,
                    arguments.go_peer_control,
                    profile.websocket_sessions,
                )
                wait_peer_ready(
                    rust_peer,
                    arguments.rust_peer_control,
                    profile.websocket_sessions,
                )
                wait_provider_count(
                    go_peer,
                    arguments.go_url,
                    profile.websocket_sessions,
                )
                wait_provider_count(
                    rust_peer,
                    arguments.rust_url,
                    profile.websocket_sessions,
                )
        counter_urls = {
            name: value
            for name, value in (
                ("go", arguments.go_counter_url),
                ("rust", arguments.rust_counter_url),
            )
            if value
        }
        database_urls = {
            name: value
            for name, value in (
                ("go", arguments.go_database_url),
                ("rust", arguments.rust_database_url),
            )
            if value
        }
        if managed:
            sampler = ResourceSampler(
                [process for process in managed if process.name.endswith("coordinator")],
                database_urls,
                {
                    "go": arguments.go_database_pool_max,
                    "rust": arguments.rust_database_pool_max,
                },
                counter_urls,
                arguments.counter_token,
            )
            sampler.start()
        trace = deterministic_trace(profile, arguments.api_key, arguments.model, arguments.alias)
        go_run, rust_run, skipped = execute_trace(
            profile,
            trace,
            arguments.go_url,
            arguments.rust_url,
            arguments.go_peer_control,
            arguments.rust_peer_control,
            arguments.timeout_seconds,
            arguments.counter_token,
        )
        peer_counters = None
        if profile.require_peer_counters:
            if not arguments.go_peer_control or not arguments.rust_peer_control:
                raise RuntimeError("profile requires measured Go and Rust peer counters")
            peer_counters = {
                "go": fetch_peer_counters(
                    arguments.go_peer_control,
                    arguments.counter_token,
                ),
                "rust": fetch_peer_counters(
                    arguments.rust_peer_control,
                    arguments.counter_token,
                ),
            }
        resources = sampler.stop() if sampler else None
        sampler = None
        comparison = compare_runs(go_run, rust_run, rules)
        summaries = {"go": summarize_target(go_run), "rust": summarize_target(rust_run)}
        snapshots = None
        database_comparison = None
        if profile.require_billing_snapshot:
            snapshots = {
                "go": collect_database_snapshot(arguments.go_database_url, "go"),
                "rust": collect_database_snapshot(arguments.rust_database_url, "rust"),
            }
            database_comparison = compare_database_snapshots(
                snapshots["go"], snapshots["rust"], rules
            )
        failures = evaluate_budgets(profile, summaries)
        failures.extend(evaluate_baseline(profile, summaries, baseline))
        failures.extend(evaluate_resources(profile, resources))
        if baseline is not None or (
            profile.require_regression_baseline and not arguments.capture_baseline
        ):
            failures.extend(evaluate_resource_baseline(profile, resources, baseline))
        failures.extend(evaluate_required_scenarios(profile, skipped))
        failures.extend(evaluate_database_availability(profile, snapshots))
        failures.extend(
            evaluate_load_execution(
                profile,
                summaries,
                peer_counters,
            )
        )
        failures.extend(
            evaluate_oracle(
                oracle,
                trace,
                {"go": go_run, "rust": rust_run},
            )
        )
        input_artifacts = {
            name: {
                "path": str(path),
                **artifact_metadata(path),
            }
            for name, path in (
                ("profiles", arguments.profiles),
                ("allowed_differences", arguments.allowed_differences),
                ("oracle", arguments.oracle),
                ("baseline", baseline_path),
            )
            if path is not None
        }
        executable_artifacts = {
            name: fact
            for name, command in (
                ("go_coordinator", arguments.go_command),
                ("rust_coordinator", arguments.rust_command),
                ("go_peer", arguments.go_peer_command),
                ("rust_peer", arguments.rust_peer_command),
            )
            if (fact := _command_artifact(command, arguments.repo_root)) is not None
        }
        report = build_report(
            profile,
            summaries,
            comparison,
            database_comparison,
            snapshots,
            resources,
            skipped,
            failures,
            {
                **provenance,
                "go_url": arguments.go_url,
                "rust_url": arguments.rust_url,
                "execution_mode": arguments.command,
                "regression_baseline_mode": (
                    "capture"
                    if arguments.capture_baseline
                    else ("measured" if baseline is not None else "absolute_only")
                ),
                "database_pool_max": {
                    "go": arguments.go_database_pool_max,
                    "rust": arguments.rust_database_pool_max,
                },
                "baseline_provenance": (
                    {
                        "review_status": baseline["review"]["status"],
                        "source_commit": baseline["source_commit"],
                        "source_run_id": baseline["ci"].get("run_id"),
                        "source_report_sha256": baseline["source_report"]["sha256"],
                    }
                    if baseline is not None
                    else None
                ),
                "input_artifacts": input_artifacts,
                "executable_artifacts": executable_artifacts,
                "managed_processes": {
                    process.name: {
                        "pid": process.pid,
                        "alive": process.process.poll() is None,
                    }
                    for process in managed
                },
                "oracle_version": oracle.version,
                "peer_counters": peer_counters,
            },
        )
        json_path = output / "report.json"
        markdown_path = output / "report.md"
        write_reports(report, json_path, markdown_path)
        evidence_path = write_evidence(
            json_path,
            markdown_path,
            provenance,
            profile_name=profile.name,
            minimum_samples={"p50": 1, "p95": 100, "p99": 100, "max": 1},
            authorizing=report["verdict"] == "pass",
        )
        print(f"{report['verdict']}: {json_path}")
        print(markdown_path)
        print(evidence_path)
        return (
            0
            if report["verdict"] in {"pass", "baseline_review_required"}
            else 1
        )
    finally:
        if sampler:
            sampler.stop()
        for process in reversed(managed):
            process.stop()


def _component(arguments: argparse.Namespace) -> int:
    if arguments.duration_seconds is not None and arguments.duration_seconds <= 0:
        raise ValueError("--duration-seconds must be positive")
    profile = load_profile(arguments.repo_root / "e2e/pilot/profiles.json", arguments.profile)
    duration = arguments.duration_seconds
    if duration is None:
        duration = profile.duration_seconds
    if profile.soak and duration < profile.duration_seconds:
        raise ValueError(
            f"{profile.name} component soak must run for at least "
            f"{profile.duration_seconds} seconds"
        )
    commands = _component_commands(arguments.repo_root)
    output = arguments.output_directory / f"component-{arguments.profile}"
    logs = output / "logs"
    logs.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    iterations = 0
    results = []
    failed = False
    while iterations == 0 or (
        arguments.profile == "scheduled" and time.monotonic() - started < duration
    ):
        iterations += 1
        for name, command, cwd in commands:
            print(f"pilot-load: running {name}", flush=True)
            command_started = time.monotonic()
            try:
                completed = subprocess.run(
                    command,
                    cwd=cwd,
                    env=isolated_environment({}),
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    timeout=max(duration, 600),
                )
                command_output = completed.stdout
                exit_code = completed.returncode
            except subprocess.TimeoutExpired as error:
                command_output = error.stdout or ""
                exit_code = 124
            if isinstance(command_output, bytes):
                command_output = command_output.decode("utf-8", errors="replace")
            elapsed = time.monotonic() - command_started
            log_path = logs / f"{iterations:03d}-{name}.log"
            log_path.write_text(command_output, encoding="utf-8")
            expected_tests = _expected_component_tests(name)
            passed_tests = _measured_component_tests(name, command_output)
            measurement_complete = expected_tests.issubset(passed_tests)
            results.append(
                {
                    "iteration": iterations,
                    "name": name,
                    "command": shlex.join(command),
                    "elapsed_seconds": elapsed,
                    "exit_code": exit_code,
                    "log": str(log_path.relative_to(output)),
                    "log_sha256": hashlib.sha256(command_output.encode()).hexdigest(),
                    "expected_tests": sorted(expected_tests),
                    "passed_tests": sorted(passed_tests),
                    "measurement_complete": measurement_complete,
                }
            )
            if exit_code != 0 or not measurement_complete:
                failed = True
                break
        if failed or arguments.profile == "quick":
            break
    non_authorizing = getattr(arguments, "non_authorizing", False)
    verdict = (
        "fail"
        if failed
        else ("baseline_review_required" if non_authorizing else "pass")
    )
    report = {
        "schema_version": 1,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "profile": arguments.profile,
        "verdict": verdict,
        "authorization_eligible": verdict == "pass",
        "elapsed_seconds": time.monotonic() - started,
        "iterations": iterations,
        "profile_parameters": {
            "websocket_sessions": profile.websocket_sessions,
            "request_multiplier": profile.request_multiplier,
            "chunk_multiplier": profile.chunk_multiplier,
        },
        "measured_components": sorted(
            {
                test
                for result in results
                if result["exit_code"] == 0 and result["measurement_complete"]
                for test in result["passed_tests"]
            }
        ),
        "coverage": _component_coverage(results),
        "commands": results,
    }
    output.mkdir(parents=True, exist_ok=True)
    report_path = output / "report.json"
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    lines = [
        "# Pilot component profile",
        "",
        f"- Verdict: **{report['verdict'].upper()}**",
        f"- Profile: `{arguments.profile}`",
        f"- Iterations: `{iterations}`",
        f"- Elapsed: `{report['elapsed_seconds']:.2f}s`",
        "",
        "| Command | Exit | Seconds | Log |",
        "|---|---:|---:|---|",
    ]
    for result in results:
        lines.append(
            f"| {result['name']} | {result['exit_code']} | {result['elapsed_seconds']:.2f} | "
            f"`{result['log']}` |"
        )
    markdown_path = output / "report.md"
    markdown_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    write_evidence(
        report_path,
        markdown_path,
        runtime_metadata(arguments.repo_root),
        profile_name=f"component-{arguments.profile}",
        minimum_samples={"iterations": 1},
        authorizing=not getattr(arguments, "non_authorizing", False),
    )
    print(f"{report['verdict']}: {report_path}")
    return 1 if failed else 0


def _component_commands(root: Path) -> list[tuple[str, list[str], Path]]:
    rust = root / "coordinator-rs"
    return [
        (
            "python-tooling-tests",
            [sys.executable, "-m", "unittest", "scripts.tests.test_pilot_load"],
            root,
        ),
        (
            "go-load",
            [
                "go",
                "test",
                "-json",
                "./coordinator/api",
                "-run",
                "^TestLoad_|^TestHandleChunkOverflowGrace",
                "-count=1",
            ],
            root,
        ),
        (
            "rust-1000-ws",
            _rust_component_command(RUST_COMPONENT_TESTS["rust-1000-ws"]),
            rust,
        ),
        (
            "rust-10x-requests",
            _rust_component_command(RUST_COMPONENT_TESTS["rust-10x-requests"]),
            rust,
        ),
        (
            "rust-concurrency-slow-consumers",
            _rust_component_command(
                RUST_COMPONENT_TESTS["rust-concurrency-slow-consumers"]
            ),
            rust,
        ),
        (
            "rust-session-replacement",
            _rust_component_command(RUST_COMPONENT_TESTS["rust-session-replacement"]),
            rust,
        ),
        (
            "rust-hedge",
            _rust_component_command(RUST_COMPONENT_TESTS["rust-hedge"]),
            rust,
        ),
        (
            "rust-sent-unknown",
            _rust_component_command(RUST_COMPONENT_TESTS["rust-sent-unknown"]),
            rust,
        ),
    ]


def _rust_component_command(test_name: str) -> list[str]:
    return [
        "cargo",
        "test",
        "--locked",
        "-p",
        "darkbloom-coordinator-server",
        "--lib",
        test_name,
        "--",
        "--exact",
    ]


def _configure_swift(arguments: argparse.Namespace) -> None:
    if arguments.profile != "swift-hardware":
        raise RuntimeError("swift-hardware command requires the swift-hardware profile")
    if platform.system() != "Darwin" or platform.machine() not in {"arm64", "aarch64"}:
        raise RuntimeError(
            "swift-hardware was requested but this host is not an Apple-Silicon macOS machine"
        )
    binary = arguments.swift_provider_binary
    if binary is None:
        candidates = [
            arguments.repo_root / "provider-swift/.build/release/darkbloom",
            arguments.repo_root / "provider-swift/.build/debug/darkbloom",
        ]
        binary = next((candidate for candidate in candidates if candidate.is_file()), None)
    if binary is None or not binary.is_file() or not os.access(binary, os.X_OK):
        raise RuntimeError(
            "swift-hardware was requested but no executable provider exists; "
            "pass --swift-provider-binary or build provider-swift"
        )
    existing_pids = _existing_provider_pids(binary)
    if existing_pids:
        raise RuntimeError(
            "swift-hardware refuses to start while an existing provider is running "
            f"(PIDs: {', '.join(str(pid) for pid in existing_pids)}); stop it explicitly first"
        )
    if arguments.require_feature:
        raise RuntimeError(
            "swift-hardware cannot inject synthetic peer features "
            f"{sorted(set(arguments.require_feature))}; use the scheduled synthetic profile"
        )
    tokens: dict[str, str] = {}
    for label, token_path in (
        ("go", arguments.swift_go_auth_token_path),
        ("rust", arguments.swift_rust_auth_token_path),
    ):
        if not token_path.is_file():
            raise RuntimeError(f"Swift provider auth token file is unavailable: {token_path}")
        token = token_path.read_text(encoding="utf-8").strip()
        if not token:
            raise RuntimeError(f"Swift {label.title()}-provider auth token file is empty")
        tokens[label] = token
    if (
        arguments.swift_go_auth_token_path.resolve()
        == arguments.swift_rust_auth_token_path.resolve()
    ):
        raise RuntimeError("Swift Go and Rust providers require distinct auth token files")
    if len(set(tokens.values())) != len(tokens):
        raise RuntimeError("Swift Go and Rust providers require distinct auth tokens")
    arguments.swift_provider_tokens = tokens
    quoted = shlex.quote(str(binary))
    go_websocket = shlex.quote(_provider_websocket_url(arguments.go_url))
    rust_websocket = shlex.quote(_provider_websocket_url(arguments.rust_url))
    arguments.go_peer_command = (
        f"{quoted} start --foreground --coordinator-url "
        f"{go_websocket} --model {shlex.quote(arguments.model)}"
    )
    arguments.rust_peer_command = (
        f"{quoted} start --foreground --coordinator-url "
        f"{rust_websocket} --model {shlex.quote(arguments.model)}"
    )


def _run_setup(command: str | None, name: str, database_url: str | None, cwd: Path) -> None:
    if not command:
        return
    environment = isolated_environment({"PILOT_DATABASE_URL": database_url or ""})
    completed = subprocess.run(
        shlex.split(command),
        cwd=cwd,
        env=environment,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=300,
    )
    if completed.returncode != 0:
        raise RuntimeError(f"{name} setup failed:\n{completed.stdout[-4000:]}")


def _command_artifact(command: str | None, repo_root: Path) -> dict[str, object] | None:
    if not command:
        return None
    arguments = shlex.split(command)
    if not arguments:
        return None
    path = Path(arguments[0])
    if not path.is_absolute():
        path = repo_root / path
    if not path.is_file():
        return None
    try:
        display_path = str(path.relative_to(repo_root))
    except ValueError:
        display_path = str(path)
    return {"path": display_path, **artifact_metadata(path)}


def _go_environment(arguments: argparse.Namespace) -> dict[str, str]:
    return {
        "EIGENINFERENCE_DATABASE_URL": arguments.go_database_url,
        "EIGENINFERENCE_PORT": str(_port(arguments.go_url)),
        "EIGENINFERENCE_ADMIN_KEY": "objective9-isolated-admin-key",
        "EIGENINFERENCE_RATE_LIMIT_RPS": "0",
        "EIGENINFERENCE_FINANCIAL_RATE_LIMIT_RPS": "0",
        "EIGENINFERENCE_MIN_TRUST": "none",
        "EIGENINFERENCE_DEDICATED_MODELS": "none",
        "EIGENINFERENCE_PILOT_COUNTER_TOKEN": arguments.counter_token,
        "EIGENINFERENCE_PILOT_LOAD_ENABLED": "true",
        "EIGENINFERENCE_PILOT_CONSUMER_KEY": arguments.api_key,
        "EIGENINFERENCE_PILOT_MODEL_ID": arguments.model,
        "EIGENINFERENCE_PILOT_MODEL_ALIAS": arguments.alias,
    }


def _rust_environment(arguments: argparse.Namespace, output: Path) -> dict[str, str]:
    profile = load_profile(arguments.profiles, arguments.profile)
    maximum_concurrency = max(profile.concurrency_ramp)
    maximum_requests = max(1024, profile.request_count, maximum_concurrency * 4)
    consumer_account_id = "legacy:" + hashlib.sha256(arguments.api_key.encode()).hexdigest()
    # Each Rust response reservation is a fixed 32 MiB worst-case permit.
    # Keep measured concurrency as the load driver while leaving equivalent
    # headroom for slow consumers and a reconnecting sent-unknown attempt.
    byte_budget = maximum_concurrency * 2 * 32 * 1024 * 1024
    state_directory = Path(tempfile.mkdtemp(prefix="objective9-rust-state-"))
    swift_tokens = getattr(arguments, "swift_provider_tokens", None)
    if swift_tokens:
        if profile.websocket_sessions != 1:
            raise ValueError(
                "swift-hardware starts one provider per coordinator; its profile "
                "must configure exactly one WebSocket session"
            )
        rust_tokens = [swift_tokens["rust"]]
    else:
        rust_tokens = [
            f"{arguments.provider_token}-{index:06d}"
            for index in range(profile.websocket_sessions)
        ]
    credentials = [
        {
            "provider_id": _provider_id(index),
            "token": token,
            "beneficiary_account_id": PROCESS_PUBLIC,
        }
        for index, token in enumerate(rust_tokens)
    ]
    credentials_path = (
        Path(tempfile.mkdtemp(prefix="objective9-rust-credentials-"))
        / "providers.json"
    )
    credentials_path.write_text(
        json.dumps(credentials, separators=(",", ":")),
        encoding="utf-8",
    )
    credentials_path.chmod(0o600)
    return {
        "EIGENINFERENCE_DATABASE_URL": arguments.rust_database_url,
        "EIGENINFERENCE_RUST_BIND_ADDRESS": f"127.0.0.1:{_port(arguments.rust_url)}",
        "EIGENINFERENCE_COORDINATOR_OWNERSHIP_ENABLED": "true",
        "EIGENINFERENCE_RUST_DATABASE_MAX_CONNECTIONS": str(
            arguments.rust_database_pool_max
        ),
        "EIGENINFERENCE_RUST_PILOT_ENABLED": "true",
        "EIGENINFERENCE_RUST_PILOT_STATE_DIRECTORY": str(state_directory),
        "EIGENINFERENCE_RUST_PROVIDER_CREDENTIALS_FILE": str(credentials_path),
        "EIGENINFERENCE_RUST_CONSUMER_API_KEYS_JSON": json.dumps(
            [
                {
                    "api_key": arguments.api_key,
                    "account_id": consumer_account_id,
                    "api_key_id": "objective9-consumer-key",
                }
            ],
            separators=(",", ":"),
        ),
        "EIGENINFERENCE_RUST_PILOT_BILLING_JSON": json.dumps(
            {
                "platform_account_id": "platform",
                "pricing_version": 1,
                "rounding_version": 1,
                "base_reservation_micro_usd": 100,
                "input_micro_usd_per_million": 0,
                "output_micro_usd_per_million": 10_000_000,
                "provider_share_ppm": 1_000_000,
                "referral_share_ppm": 0,
            },
            separators=(",", ":"),
        ),
        "EIGENINFERENCE_RUST_PILOT_LOAD_SEED_ENABLED": "true",
        "EIGENINFERENCE_RUST_PILOT_FUNDING_ACCOUNT_ID": consumer_account_id,
        "EIGENINFERENCE_RUST_PILOT_FUNDING_MICRO_USD": "1000000000000",
        "EIGENINFERENCE_RUST_PROCESS_X25519_KEY_ID": "objective9-process-key",
        "EIGENINFERENCE_RUST_PROCESS_X25519_PRIVATE_KEY": PROCESS_PRIVATE,
        "EIGENINFERENCE_RUST_PROCESS_X25519_PUBLIC_KEY": PROCESS_PUBLIC,
        "EIGENINFERENCE_RUST_PILOT_MODEL_ID": arguments.model,
        "EIGENINFERENCE_RUST_PILOT_MODEL_ALIAS": arguments.alias,
        "EIGENINFERENCE_RUST_PILOT_TRUST_FLOOR": "self_signed",
        "EIGENINFERENCE_PILOT_COUNTER_TOKEN": arguments.counter_token,
        "EIGENINFERENCE_RUST_PILOT_MAXIMUM_SESSIONS": str(
            max(1024, profile.websocket_sessions + 16)
        ),
        "EIGENINFERENCE_RUST_PILOT_MAXIMUM_REQUESTS": str(maximum_requests),
        "EIGENINFERENCE_RUST_PILOT_REQUEST_QUEUE_CAPACITY": str(maximum_requests),
        "EIGENINFERENCE_RUST_PILOT_INPUT_BUDGET_BYTES": str(byte_budget),
        "EIGENINFERENCE_RUST_PILOT_RESPONSE_BUDGET_BYTES": str(byte_budget),
    }


def _peer_environment(arguments: argparse.Namespace, target: str) -> dict[str, str]:
    token_path = getattr(arguments, f"swift_{target}_auth_token_path", None)
    state_directory = Path(tempfile.mkdtemp(prefix=f"objective9-{target}-provider-"))
    profile = load_profile(arguments.profiles, arguments.profile)
    environment = {
        "DARKBLOOM_NO_UPDATE_CHECK": "1",
        "DARKBLOOM_STATE_FILE": str(state_directory / "daemon-state.json"),
        "DARKBLOOM_LOADED_MODELS_FILE": str(state_directory / "loaded-models.json"),
    }
    if token_path:
        configured_tokens = getattr(arguments, "swift_provider_tokens", None)
        if not isinstance(configured_tokens, dict) or target not in configured_tokens:
            raise ValueError(f"Swift {target} provider token was not configured")
        home = state_directory / "home"
        config_path = home / ".config/darkbloom/provider.toml"
        config_path.parent.mkdir(parents=True, exist_ok=True)
        config_path.write_text(
            "[provider]\nauto_update = false\nauto_restart = false\n",
            encoding="utf-8",
        )
        source_cache = Path.home() / ".cache/huggingface"
        if source_cache.is_dir():
            cache_parent = home / ".cache"
            cache_parent.mkdir(parents=True, exist_ok=True)
            (cache_parent / "huggingface").symlink_to(
                source_cache,
                target_is_directory=True,
            )
        environment.update(
            {
                "HOME": str(home),
                "DARKBLOOM_PID_FILE": str(state_directory / "provider.pid"),
                "DARKBLOOM_WATCHDOG_STATE": str(
                    state_directory / "watchdog-state.json"
                ),
                "DARKBLOOM_LOCAL_DIR": str(state_directory / "local"),
            }
        )
        isolated_token_path = state_directory / "auth-token"
        isolated_token_path.write_text(configured_tokens[target] + "\n", encoding="utf-8")
        isolated_token_path.chmod(0o600)
        environment["DARKBLOOM_AUTH_TOKEN_PATH"] = str(isolated_token_path)
        return environment
    control_url = getattr(arguments, f"{target}_peer_control")
    if not control_url:
        raise ValueError(f"{target} synthetic peer command requires a peer control URL")
    parsed_control = urllib.parse.urlparse(control_url)
    environment.update(
        {
            "PILOT_PROVIDER_TOKEN": arguments.provider_token,
            "PILOT_COORDINATOR_URL": getattr(arguments, f"{target}_url"),
            "PILOT_TARGET": target,
            "PILOT_CONTROL_ADDRESS": _loopback_socket_address(parsed_control),
            "PILOT_MODEL": arguments.model,
            "PILOT_SEED": str(profile.seed),
            "PILOT_WEBSOCKET_SESSIONS": str(profile.websocket_sessions),
            "PILOT_REQUEST_MULTIPLIER": str(profile.request_multiplier),
            "PILOT_CHUNK_MULTIPLIER": str(profile.chunk_multiplier),
            "PILOT_CONCURRENCY_RAMP": json.dumps(profile.concurrency_ramp),
            "PILOT_SLOW_CONSUMER_FRACTION": str(profile.slow_consumer_fraction),
            "PILOT_SLOW_CONSUMER_DELAY_MS": str(profile.slow_consumer_delay_ms),
            "PILOT_CONTROL_TOKEN": arguments.counter_token,
        }
    )
    return environment


def _verify_swift_auth_wiring(
    arguments: argparse.Namespace,
    rust_coordinator_environment: dict[str, str],
    peer_environments: dict[str, dict[str, str]],
) -> None:
    configured_tokens = getattr(arguments, "swift_provider_tokens", None)
    if not isinstance(configured_tokens, dict) or set(configured_tokens) != {
        "go",
        "rust",
    }:
        raise ValueError("Swift provider tokens are not fully configured")
    sent_tokens: dict[str, str] = {}
    for target in ("go", "rust"):
        environment = peer_environments.get(target)
        token_path = environment.get("DARKBLOOM_AUTH_TOKEN_PATH") if environment else None
        if not token_path:
            raise ValueError(f"Swift {target} provider has no isolated token path")
        sent_tokens[target] = Path(token_path).read_text(encoding="utf-8").strip()
    if sent_tokens != configured_tokens:
        raise ValueError("Swift isolated provider tokens do not match configured tokens")
    credentials_path = rust_coordinator_environment.get(
        "EIGENINFERENCE_RUST_PROVIDER_CREDENTIALS_FILE"
    )
    if not credentials_path:
        raise ValueError("Rust coordinator has no Swift provider credential file")
    credentials = json.loads(Path(credentials_path).read_text(encoding="utf-8"))
    if (
        not isinstance(credentials, list)
        or len(credentials) != 1
        or not isinstance(credentials[0], dict)
        or credentials[0].get("token") != sent_tokens["rust"]
    ):
        raise ValueError(
            "Rust coordinator credential does not exactly match the Swift provider token"
        )


def _existing_provider_pids(binary: Path) -> list[int]:
    pids: set[int] = set()
    pid_path = Path.home() / ".darkbloom/provider.pid"
    try:
        pid = int(pid_path.read_text(encoding="utf-8").strip())
    except (FileNotFoundError, ValueError):
        pass
    else:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            pass
        except PermissionError:
            # A live PID that cannot be inspected is still unsafe to overlap.
            pids.add(pid)
        else:
            pids.add(pid)
    try:
        completed = subprocess.run(
            ["ps", "-axo", "pid=,command="],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return sorted(pids)
    provider_names = {binary.name, "darkbloom"}
    for line in completed.stdout.splitlines():
        pid_text, separator, command = line.strip().partition(" ")
        if not separator:
            continue
        try:
            tokens = shlex.split(command)
            pid = int(pid_text)
        except (ValueError, IndexError):
            continue
        if (
            tokens
            and Path(tokens[0]).name in provider_names
            and "start" in tokens
            and "--foreground" in tokens
        ):
            pids.add(pid)
    return sorted(pids)


def _port(url: str) -> int:
    port = urllib.parse.urlparse(url).port
    if port is None:
        raise ValueError(f"URL has no explicit port: {url}")
    return port


def _loopback_socket_address(parsed: urllib.parse.ParseResult) -> str:
    require_loopback_url(parsed.geturl(), "peer control", schemes={"http"})
    host = parsed.hostname
    port = parsed.port
    if host is None or port is None:
        raise ValueError("peer control URL requires an explicit loopback host and port")
    if host == "localhost":
        host = "127.0.0.1"
    if ":" in host:
        host = f"[{host}]"
    return f"{host}:{port}"


def _provider_websocket_url(coordinator_url: str) -> str:
    require_loopback_url(coordinator_url, "coordinator", schemes={"http"})
    parsed = urllib.parse.urlparse(coordinator_url)
    host = parsed.hostname
    port = parsed.port
    if host is None or port is None:
        raise ValueError("coordinator URL requires an explicit loopback host and port")
    encoded_host = f"[{host}]" if ":" in host else host
    value = f"ws://{encoded_host}:{port}/ws/provider"
    require_loopback_url(value, "provider WebSocket", schemes={"ws"})
    return value


def _provider_id(index: int) -> str:
    value = index + 901
    if value >= 1_000_000_000_000:
        raise ValueError("pilot provider index exceeds UUID fixture range")
    return f"00000000-0000-0000-0000-{value:012d}"


if __name__ == "__main__":
    raise SystemExit(main())
