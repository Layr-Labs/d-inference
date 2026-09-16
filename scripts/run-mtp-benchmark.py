#!/usr/bin/env python3
"""Run cache-only MTP live tests under a hard process-group deadline."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import secrets
import signal
import stat
import subprocess
import sys
import tempfile
import time
from typing import Any


# Direct CLI execution already adds scripts/ to sys.path. Also support existing
# importlib/runpy callers loading this launcher by absolute path from another cwd.
_SCRIPT_DIRECTORY = str(Path(__file__).resolve().parent)
if _SCRIPT_DIRECTORY not in sys.path:
    sys.path.insert(0, _SCRIPT_DIRECTORY)

from mtp_benchmark.constants import (
    REPO_ROOT, PACKAGE_ROOT, DEFAULT_TARGET_ID, DEFAULT_ASSISTANT_ID, DEFAULT_TEST_FILTER,
    REPORT_SCHEMA_VERSION, REPORT_NAME, LOG_NAME, SUPERVISOR_CONTRACT,
    LEGACY_M5_INACTIVE_REASON_PREFIX, MAX_CACHE_ROOTS, MAX_FALLBACK_REPOSITORY_ENTRIES,
    MAX_FALLBACK_REPOSITORIES, MAX_SNAPSHOT_ENTRIES, MAX_REF_BYTES, MAX_REPORT_BYTES,
    PERFORMANCE_KEYS, HEX_DIGITS,
)
from mtp_benchmark.artifacts import (
    repo_cache_name, bounded_scandir, cache_roots, confined_regular_file,
    repository_snapshot, resolve_cached_snapshot, validate_snapshot,
    infer_huggingface_model_id, resolve_model_snapshot, sha256_file,
    append_fingerprint_field, collect_nested_bit_overrides,
    launch_effective_quantization_bits, artifact_facts,
)
from mtp_benchmark.run_directory import (
    open_directory, SecureRunDirectory, validate_leaf_name, write_all, read_bounded,
)
from mtp_benchmark.metrics import (
    observed_bucket, expected_mtp_expectation, inactive_reason_matches,
    validate_zero_speculative_work, automatic_rectangular_cap, positive_cost_inputs,
    positive_costs_within_cap, validate_automatic_fixed_fallback,
    validate_automatic_adaptive_within_cap,
)
from mtp_benchmark.report import (
    parse_timestamp, recursively_present_keys, effective_quantization_bits,
    expected_coverage, validate_report_artifact, validate_report,
)
from mtp_benchmark.self_tests import (
    self_test_output_safety, self_test_artifact_provenance,
)

def terminate_group(process: subprocess.Popen[Any]) -> None:
    """Terminate the supervised session and always reap the direct child."""

    def signal_supervised(sig: int) -> None:
        # Always try the GROUP first, even when the direct worker has already
        # exited: a crashed worker can leave its `swift test` descendants
        # alive in the supervised group, and the pgid stays valid while any
        # member lives. Returning early on poll() would skip both the SIGTERM
        # and the SIGKILL and orphan a live MLX benchmark.
        try:
            os.killpg(process.pid, sig)
            return
        except ProcessLookupError:
            # The whole group is gone.
            return
        except PermissionError:
            # Sandboxed macOS sessions can deny process-group signalling even
            # though the direct child remains ours. Fall back to that child;
            # its own cleanup owns any descendants.
            if process.poll() is not None:
                return
            try:
                process.send_signal(sig)
            except (ProcessLookupError, PermissionError):
                return

    def group_exists() -> bool:
        try:
            os.killpg(process.pid, 0)
            return True
        except ProcessLookupError:
            return False
        except PermissionError:
            return process.poll() is None

    deadline = time.monotonic() + 10
    signal_supervised(signal.SIGTERM)
    while group_exists() and time.monotonic() < deadline:
        process.poll()
        time.sleep(0.05)
    if group_exists():
        signal_supervised(signal.SIGKILL)
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        signal_supervised(signal.SIGKILL)
        process.wait()


def fingerprint_for(
    args: argparse.Namespace,
    *,
    target_id: str,
    assistant_id: str,
    target: dict[str, Any],
    assistant: dict[str, Any],
    warmup: int,
    repetitions: int,
    build_configuration: str,
) -> str:
    payload = json.dumps(
        {
            "target_id": target_id,
            "assistant_id": assistant_id,
            "target_fingerprint": target["artifactFingerprint"],
            "assistant_fingerprint": assistant["artifactFingerprint"],
            "mode": args.mode,
            "mtp_expectation": expected_mtp_expectation(args.expect_mtp_inactive),
            "build_configuration": build_configuration,
            "test_filter": args.test_filter,
            "max_tokens": args.max_tokens,
            "warmup": warmup,
            "repetitions": repetitions,
            "seed": args.seed,
            "launch_ns": time.time_ns(),
            "nonce": secrets.token_hex(16),
        },
        sort_keys=True,
    ).encode()
    return hashlib.sha256(payload).hexdigest()


def worker_main(args: argparse.Namespace, warmup: int, repetitions: int) -> int:
    run = SecureRunDirectory.reopen(
        args._worker_run_directory,
        args._worker_run_device,
        args._worker_run_inode,
    )
    try:
        build_configuration = "debug" if args.debug else "release"
        target_id, target = resolve_model_snapshot(
            args.target_id, args.target_path, DEFAULT_TARGET_ID, "target"
        )
        assistant_id, assistant = resolve_model_snapshot(
            args.assistant_id, args.assistant_path, DEFAULT_ASSISTANT_ID, "assistant"
        )
        target_facts = artifact_facts(target_id, target)
        assistant_facts = artifact_facts(assistant_id, assistant)
        fingerprint = fingerprint_for(
            args,
            target_id=target_id,
            assistant_id=assistant_id,
            target=target_facts,
            assistant=assistant_facts,
            warmup=warmup,
            repetitions=repetitions,
            build_configuration=build_configuration,
        )
        launch_time = time.time()
        output = run.path / REPORT_NAME
        log_path = run.path / LOG_NAME

        environment = os.environ.copy()
        environment.update(
            {
                "DARKBLOOM_LIVE_MLX_TESTS": "1",
                "DARKBLOOM_LIVE_MLX_GEMMA": "1",
                "DARKBLOOM_LIVE_MLX_MTP": "1",
                "DARKBLOOM_MTP_EXTERNAL_SUPERVISOR": SUPERVISOR_CONTRACT,
                "DARKBLOOM_MTP_TARGET_ID": target_id,
                "DARKBLOOM_MTP_ASSISTANT_ID": assistant_id,
                "DARKBLOOM_MTP_TARGET_PATH": str(target),
                "DARKBLOOM_MTP_ASSISTANT_PATH": str(assistant),
                "DARKBLOOM_MTP_BENCHMARK_OUTPUT": str(output),
                "DARKBLOOM_MTP_BENCHMARK_RUN_DIRECTORY": str(run.path),
                "DARKBLOOM_MTP_BENCHMARK_RUN_DEVICE": str(run.device),
                "DARKBLOOM_MTP_BENCHMARK_RUN_INODE": str(run.inode),
                "DARKBLOOM_MTP_BENCHMARK_BUILD_CONFIGURATION": build_configuration,
                "DARKBLOOM_MTP_BENCHMARK_MAX_TOKENS": str(args.max_tokens),
                "DARKBLOOM_MTP_BENCHMARK_MODE": args.mode,
                "DARKBLOOM_MTP_BENCHMARK_EXPECT_MTP_INACTIVE": (
                    "1" if args.expect_mtp_inactive else "0"
                ),
                "DARKBLOOM_MTP_BENCHMARK_WARMUP": str(warmup),
                "DARKBLOOM_MTP_BENCHMARK_REPETITIONS": str(repetitions),
                "DARKBLOOM_MTP_BENCHMARK_SEED": str(args.seed),
                "DARKBLOOM_MTP_BENCHMARK_RUN_FINGERPRINT": fingerprint,
                "DARKBLOOM_MTP_BENCHMARK_DEADLINE_SECONDS": str(
                    max(1, args.timeout_seconds - 30)
                ),
                "HF_HUB_OFFLINE": "1",
                "TRANSFORMERS_OFFLINE": "1",
            }
        )
        command = [
            "swift",
            "test",
            "-c",
            build_configuration,
            "--filter",
            args.test_filter,
        ]
        print(f"target={target}")
        print(f"assistant={assistant}")
        print(f"run_directory={run.path}")
        print(f"result={output}")
        print(f"log={log_path}")
        print(f"mode={args.mode}")
        print(f"expect_mtp_inactive={args.expect_mtp_inactive}")
        print(f"build_configuration={build_configuration}")
        print(f"test_filter={args.test_filter}")
        print(f"launch_fingerprint={fingerprint}")
        expectation_kind = expected_mtp_expectation(args.expect_mtp_inactive)["kind"]
        print(
            f"report_fingerprint={build_configuration}:{expectation_kind}:{fingerprint}"
        )
        sys.stdout.flush()

        process = subprocess.Popen(
            command,
            cwd=PACKAGE_ROOT,
            env=environment,
            stdout=args._worker_log_fd,
            stderr=subprocess.STDOUT,
        )
        return_code = process.wait()
        if return_code != 0:
            print(f"live test failed with exit {return_code}; see {log_path}", file=sys.stderr)
            return return_code

        try:
            if artifact_facts(target_id, target) != target_facts:
                raise ValueError("target artifact drifted during the live run")
            if artifact_facts(assistant_id, assistant) != assistant_facts:
                raise ValueError("assistant artifact drifted during the live run")
        except (OSError, ValueError) as error:
            print(f"artifact drift validation failed: {error}; see {log_path}", file=sys.stderr)
            return 3

        if args.test_filter.startswith(DEFAULT_TEST_FILTER):
            try:
                validate_report(
                    run,
                    fingerprint=fingerprint,
                    launch_time=launch_time,
                    mode=args.mode,
                    build_configuration=build_configuration,
                    target=target_facts,
                    assistant=assistant_facts,
                    max_tokens=args.max_tokens,
                    warmup=warmup,
                    repetitions=repetitions,
                    seed=args.seed,
                    expect_mtp_inactive=args.expect_mtp_inactive,
                )
            except (OSError, ValueError, UnicodeDecodeError, json.JSONDecodeError) as error:
                print(
                    f"benchmark report validation failed: {error}; see {log_path}",
                    file=sys.stderr,
                )
                return 3
            print(output)
        else:
            print(f"focused live test passed; log={log_path}")
        return 0
    finally:
        run.close()


def supervisor_main(args: argparse.Namespace, warmup: int, repetitions: int) -> int:
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    requested = args.output or REPO_ROOT / "tmp/mtp-benchmarks" / f"mtp-{timestamp}.json"
    run = SecureRunDirectory.create(requested)
    log_descriptor = run.create_file(LOG_NAME)
    manifest = {
        "schema_version": 1,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "build_configuration": "debug" if args.debug else "release",
        "mode": args.mode,
        "mtp_expectation": expected_mtp_expectation(args.expect_mtp_inactive),
        "test_filter": args.test_filter,
        "timeout_seconds": args.timeout_seconds,
    }
    run.atomic_write(
        "run.json",
        (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode(),
    )

    worker_command = [
        sys.executable,
        str(Path(__file__).resolve()),
        *sys.argv[1:],
        "--_worker-run-directory",
        str(run.path),
        "--_worker-run-device",
        str(run.device),
        "--_worker-run-inode",
        str(run.inode),
        "--_worker-log-fd",
        str(log_descriptor),
    ]
    process: subprocess.Popen[Any] | None = None
    previous_handlers: dict[int, Any] = {}

    def handle_signal(signum: int, _frame: Any) -> None:
        if process is not None:
            terminate_group(process)
        raise SystemExit(128 + signum)

    try:
        process = subprocess.Popen(
            worker_command,
            pass_fds=(log_descriptor,),
            start_new_session=True,
        )
        for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            previous_handlers[signum] = signal.signal(signum, handle_signal)
        try:
            return_code = process.wait(timeout=args.timeout_seconds)
        except subprocess.TimeoutExpired:
            print(
                f"live test timed out after {args.timeout_seconds}s; see {run.path / LOG_NAME}",
                file=sys.stderr,
            )
            return_code = 124
        finally:
            terminate_group(process)
        if not run.visible_identity_matches():
            print("benchmark run directory path was replaced", file=sys.stderr)
            return 3
        return return_code
    finally:
        for signum, previous in previous_handlers.items():
            signal.signal(signum, previous)
        os.close(log_descriptor)
        run.close()


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target-id")
    parser.add_argument("--assistant-id")
    parser.add_argument("--target-path", type=Path)
    parser.add_argument("--assistant-path", type=Path)
    parser.add_argument("--timeout-seconds", type=int, default=3600)
    parser.add_argument("--max-tokens", type=int, default=16)
    parser.add_argument(
        "--mode",
        choices=("raw-parity", "production-performance"),
        default="raw-parity",
        help="raw parity recursively omits performance keys; performance requires release",
    )
    parser.add_argument(
        "--expect-mtp-inactive",
        action="store_true",
        help=(
            "legacy pre-serial-target regression mode: require the retired Apple M5 "
            "hardware-veto reason and zero speculative work"
        ),
    )
    parser.add_argument("--warmup", type=int)
    parser.add_argument("--repetitions", type=int)
    parser.add_argument("--seed", type=int, default=0x4D545032)
    parser.add_argument(
        "--output",
        type=Path,
        help="select an approved temp root and run-name prefix; output is always unique",
    )
    parser.add_argument("--debug", action="store_true", help="use a debug Swift build")
    parser.add_argument(
        "--test-filter",
        default=DEFAULT_TEST_FILTER,
        help="Swift test filter; all env-gated MTP live tests remain process-supervised",
    )
    parser.add_argument("--self-test-output-safety", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--self-test-artifact-provenance", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--_worker-run-directory", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--_worker-run-device", type=int, help=argparse.SUPPRESS)
    parser.add_argument("--_worker-run-inode", type=int, help=argparse.SUPPRESS)
    parser.add_argument("--_worker-log-fd", type=int, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.timeout_seconds <= 0 or args.max_tokens <= 0 or args.seed < 0:
        parser.error("--timeout-seconds and --max-tokens must be positive; --seed nonnegative")
    if args.mode == "production-performance" and args.debug:
        parser.error("production-performance mode requires a release build")
    if args.mode == "production-performance" and args.expect_mtp_inactive:
        parser.error("production-performance mode rejects --expect-mtp-inactive")
    if not args.test_filter or args.test_filter.startswith("-"):
        parser.error("--test-filter must be nonempty")
    return args


def main() -> int:
    args = parse_arguments()
    if args.self_test_output_safety:
        return self_test_output_safety()
    if args.self_test_artifact_provenance:
        return self_test_artifact_provenance()
    warmup = args.warmup if args.warmup is not None else (
        0 if args.mode == "raw-parity" else 1
    )
    repetitions = args.repetitions if args.repetitions is not None else (
        1 if args.mode == "raw-parity" else 3
    )
    if warmup < 0 or repetitions <= 0:
        raise SystemExit("--warmup must be nonnegative and --repetitions positive")
    internal_values = (
        args._worker_run_directory,
        args._worker_run_device,
        args._worker_run_inode,
        args._worker_log_fd,
    )
    if any(value is not None for value in internal_values):
        if any(value is None for value in internal_values):
            raise SystemExit("incomplete internal worker contract")
        return worker_main(args, warmup, repetitions)
    return supervisor_main(args, warmup, repetitions)


if __name__ == "__main__":
    raise SystemExit(main())
