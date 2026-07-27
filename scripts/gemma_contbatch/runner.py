"""Benchmark build, execution, validation, and report orchestration."""

from __future__ import annotations

import argparse
import json
import os
import shlex
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

from .backend import resolve_kv_backend, validate_kv_backend_pin
from .baseline import (
    load_baseline,
    resolve_model_snapshot,
    validate_baseline_pins,
)
from .checks import assert_finite
from .config import SCHEMA_VERSION, parse_args
from .environment import performance_environment
from .process import (
    BenchmarkCommandFailure,
    atomic_write,
    capture,
    capture_optional,
    run_json,
    run_step,
    sha256,
    source_fingerprint,
)
from .report import markdown_report
from .results import compare
from .summary import summarize
from .validation import validate_raw_outputs


def safe_label(label: str) -> str:
    normalized = "".join(character if character.isalnum() else "-" for character in label)
    return "-".join(part for part in normalized.split("-") if part).lower()


def resolve_output_dir(args: argparse.Namespace, repo_root: Path) -> Path:
    output_dir = Path(args.output_dir)
    if not output_dir.is_absolute():
        output_dir = repo_root / output_dir
    output_dir.mkdir(parents=True, exist_ok=True)
    return output_dir


def persist_failed_report(failure: BenchmarkCommandFailure, output_dir: Path) -> int:
    """Keep the structured report a failed benchmark deliberately printed.

    An explicit `--kv-backend` sweep that cannot build a requested cell prints
    its report and exits non-zero on purpose -- the report names the cells it
    could not measure and why. The status is propagated verbatim; only the
    discard is fixed.
    """
    print(str(failure), file=sys.stderr)
    if failure.report is None:
        return failure.returncode
    path = output_dir / "gemma-contbatch-failed.json"
    atomic_write(
        path,
        json.dumps(
            {
                "schemaVersion": SCHEMA_VERSION,
                "failedCommand": shlex.join(failure.command),
                "exitStatus": failure.returncode,
                "report": failure.report,
            },
            indent=2,
            sort_keys=True,
        )
        + "\n",
    )
    print(f"Failed-run report: {path}", file=sys.stderr)
    return failure.returncode


def sweep_argv(benchmark: list[str], args: argparse.Namespace) -> list[str]:
    """The full `darkbloom benchmark --sweep` argv this wrapper runs.

    Pure, so the two controls that make a run attributable can be asserted
    without a GPU: before #583 was wired through here, the wrapper measured
    whatever `--kv-backend auto` happened to resolve, on a `B=1..--max-batch`
    ladder that stopped below the paged/contiguous crossover at ~B=5. A green
    run could therefore neither name its backend nor reach the batch sizes
    the release is claimed on.
    """
    repeated_lengths = ",".join(
        str(length)
        for length in args.prefill_lengths
        for _ in range(args.iterations)
    )
    return benchmark + [
        "--sweep",
        "--prefill-lengths",
        repeated_lengths,
        "--kv-backend",
        args.kv_backend,
        "--batch-sizes",
        ",".join(map(str, args.batch_sizes)),
        "--decode-tokens",
        str(args.decode_tokens),
        "--decode-prompt-tokens",
        str(args.decode_prompt_tokens),
        "--decode-iterations",
        str(args.iterations),
    ]


def scheduler_argv(benchmark: list[str], args: argparse.Namespace) -> list[str]:
    """The full `darkbloom benchmark --scheduler-prefill` argv.

    Carries `--kv-backend` for the same reason the sweep does. This phase
    builds a FRESH production engine per measurement, so without the
    selection every TTFT number came off `.auto` -- CONTIGUOUS -- while the
    sweep beside it measured paged, and the report attributed both to one
    backend. There is no batch-size curve to forward: each cold prefill is a
    single request, `maxConcurrentRequests: 1` by construction.
    """
    return benchmark + [
        "--scheduler-prefill",
        "--prefill-lengths",
        ",".join(map(str, args.prefill_lengths)),
        "--kv-backend",
        args.kv_backend,
        "--prefill-iterations",
        str(args.iterations),
    ]


def arrival_argv(benchmark: list[str], args: argparse.Namespace) -> list[str]:
    """The full `darkbloom benchmark --arrival-invariance` argv.

    Same pin, one engine: every arrival topology is measured on a single warm
    engine, so this phase resolves exactly one backend and an unpinned run
    resolved `.auto`'s. No batch-size curve here either -- the concurrency is
    the widest arrival pattern (burst, 4 rows), fixed by the topologies the
    benchmark defines rather than by a flag.
    """
    return benchmark + [
        "--arrival-invariance",
        "--kv-backend",
        args.kv_backend,
        "--arrival-prompt-tokens",
        str(args.arrival_prompt_tokens),
        "--arrival-decode-tokens",
        str(args.arrival_decode_tokens),
        "--arrival-iterations",
        str(args.iterations),
    ]


def main() -> int:
    args = parse_args()
    repo_root = Path(__file__).resolve().parents[2]
    provider_dir = repo_root / "provider-swift"
    binary = provider_dir / ".build/release/darkbloom"
    metallib = provider_dir / ".build/release/mlx.metallib"
    mlx_metal_source = repo_root / "libs/mlx-swift/Source/Cmlx/mlx"
    started = time.monotonic()
    generated_at = datetime.now(timezone.utc).replace(microsecond=0).isoformat()
    thermal_before = capture_optional(["pmset", "-g", "therm"], repo_root)

    if not (repo_root / "libs/mlx-swift/Package.swift").is_file():
        raise RuntimeError("MLX submodules are missing; run git submodule update --init --recursive")
    if not args.skip_build:
        run_step(["swift", "build", "-c", "release", "--product", "darkbloom"], provider_dir)
    mlx_metal_status, mlx_metal_fingerprint = source_fingerprint(mlx_metal_source)
    if not args.skip_metallib:
        metallib_environment = os.environ.copy()
        source_cache = (
            repo_root
            / "tmp/benchmarks/metallib-cache"
            / mlx_metal_fingerprint[:16]
        )
        source_cache.mkdir(parents=True, exist_ok=True)
        metallib_environment["METALLIB_CACHE_DIR"] = str(source_cache)
        if mlx_metal_status:
            print(
                f"Dirty MLX Metal source: using cache {source_cache}",
                file=sys.stderr,
            )
        run_step(
            [str(repo_root / "scripts/fetch-metallib.sh"), "release"],
            repo_root,
            env=metallib_environment,
        )
    if not binary.is_file() or not metallib.is_file():
        raise RuntimeError("release binary or mlx.metallib is missing")

    output_dir = resolve_output_dir(args, repo_root)
    benchmark = [str(binary), "benchmark", "--model", args.model]
    # Parse before aborting: a refused sweep prints its report and THEN
    # fails, and that report is the whole diagnostic.
    try:
        sweep = run_json(sweep_argv(benchmark, args), provider_dir)
        scheduler = run_json(scheduler_argv(benchmark, args), provider_dir)
        arrival = run_json(arrival_argv(benchmark, args), provider_dir)
    except BenchmarkCommandFailure as failure:
        return persist_failed_report(failure, output_dir)

    raw_outputs = {
        "throughputSweep": sweep,
        "schedulerPrefill": scheduler,
        "arrivalInvariance": arrival,
    }
    validate_raw_outputs(args, sweep, scheduler, arrival)
    # The backend every phase was actually built with. Extracted before the
    # summary so a run that cannot name its backends never reaches a report,
    # let alone a comparison.
    kv_backend = resolve_kv_backend(args.kv_backend, sweep, scheduler, arrival)
    summary = summarize(sweep, scheduler, arrival)
    model_snapshot = resolve_model_snapshot(raw_outputs)
    hardware = sweep["hardware"]

    # The same capture is recorded in the report and pinned against the
    # baseline below, so the two can never describe different runs.
    environment = performance_environment(os.environ)
    report = {
        # See config.SCHEMA_VERSION for what each version changed.
        "schemaVersion": SCHEMA_VERSION,
        "generatedAt": generated_at,
        "label": args.label,
        "modelID": args.model,
        "modelSnapshot": model_snapshot,
        "hardware": hardware,
        # Selection and resolved backend, kept apart: "paged was requested"
        # and "paged was built" are different facts, and the gap between them
        # is the only evidence that `.auto` did not quietly degrade.
        "kvBackend": kv_backend,
        "configuration": {
            "iterations": args.iterations,
            "prefillLengths": args.prefill_lengths,
            "decodePromptTokens": args.decode_prompt_tokens,
            "decodeTokens": args.decode_tokens,
            "batchSizes": args.batch_sizes,
            # The decode curve is repeated once per iteration, so every batch
            # size in the summary is a median over exactly this many samples.
            "decodeIterations": args.iterations,
            "arrivalPromptTokens": args.arrival_prompt_tokens,
            "arrivalDecodeTokens": args.arrival_decode_tokens,
        },
        "metadata": {
            "rootCommit": capture(["git", "rev-parse", "HEAD"], repo_root),
            "gitStatus": capture(["git", "status", "--short"], repo_root).splitlines(),
            "submodules": capture(["git", "submodule", "status"], repo_root).splitlines(),
            "mlxMetalSourceStatus": mlx_metal_status,
            "mlxMetalSourceFingerprint": mlx_metal_fingerprint,
            "binarySha256": sha256(binary),
            "metallibSha256": sha256(metallib),
            "environment": environment,
            "thermalBefore": thermal_before,
            "thermalAfter": capture_optional(["pmset", "-g", "therm"], repo_root),
        },
        "summary": summary,
        "raw": raw_outputs,
        "durationSeconds": time.monotonic() - started,
        "invocation": shlex.join([sys.executable, *sys.argv]),
    }

    if args.baseline:
        baseline_path = Path(args.baseline)
        if not baseline_path.is_absolute():
            baseline_path = repo_root / baseline_path
        baseline = load_baseline(baseline_path)
        # Pin weights, host, workload, and engine/Metal overrides before any
        # delta is computed: an unpinned snapshot, a different Mac, or a
        # flipped kill switch turns unrelated differences into what reads as
        # an engine regression.
        validate_baseline_pins(args, baseline, model_snapshot, hardware, environment)
        # The pin this release turns on. A paged-versus-contiguous difference
        # would otherwise show up as a double-digit aggregate delta with no
        # trace of its cause anywhere in the report.
        validate_kv_backend_pin(baseline, kv_backend)
        report["comparison"] = compare(summary, baseline)

    assert_finite(report)
    markdown = markdown_report(report)
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    suffix = f"-{safe_label(args.label)}" if args.label else ""
    stem = f"gemma-contbatch-{timestamp}{suffix}"
    json_text = json.dumps(report, indent=2, sort_keys=True) + "\n"
    paths = {
        output_dir / f"{stem}.json": json_text,
        output_dir / f"{stem}.md": markdown,
        output_dir / "gemma-contbatch-latest.json": json_text,
        output_dir / "gemma-contbatch-latest.md": markdown,
    }
    for path, content in paths.items():
        atomic_write(path, content)

    print(markdown)
    print("Reports:")
    print(f"  {output_dir / f'{stem}.md'}")
    print(f"  {output_dir / f'{stem}.json'}")
    # Fail the process, but only after the artifact is on disk: a run that
    # measured the wrong backend is exactly the run whose report an operator
    # needs to read.
    violations = kv_backend["postureViolations"]
    if violations:
        for violation in violations:
            print(f"KV backend posture FAILED: {violation}", file=sys.stderr)
        return 1
    return 0
