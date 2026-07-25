"""Benchmark build, execution, validation, and report orchestration."""

from __future__ import annotations

import json
import os
import shlex
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

from .baseline import (
    load_baseline,
    resolve_model_snapshot,
    validate_baseline_pins,
)
from .config import PERFORMANCE_ENV_PREFIXES, parse_args
from .process import (
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
from .validation import assert_finite, validate_raw_outputs


def safe_label(label: str) -> str:
    normalized = "".join(character if character.isalnum() else "-" for character in label)
    return "-".join(part for part in normalized.split("-") if part).lower()


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

    benchmark = [str(binary), "benchmark", "--model", args.model]
    repeated_lengths = ",".join(
        str(length)
        for length in args.prefill_lengths
        for _ in range(args.iterations)
    )
    sweep = run_json(
        benchmark
        + [
            "--sweep",
            "--prefill-lengths",
            repeated_lengths,
            "--max-batch",
            str(args.max_batch),
            "--decode-tokens",
            str(args.decode_tokens),
            "--decode-prompt-tokens",
            str(args.decode_prompt_tokens),
            "--decode-iterations",
            str(args.iterations),
        ],
        provider_dir,
    )
    scheduler = run_json(
        benchmark
        + [
            "--scheduler-prefill",
            "--prefill-lengths",
            ",".join(map(str, args.prefill_lengths)),
            "--prefill-iterations",
            str(args.iterations),
        ],
        provider_dir,
    )
    arrival = run_json(
        benchmark
        + [
            "--arrival-invariance",
            "--arrival-prompt-tokens",
            str(args.arrival_prompt_tokens),
            "--arrival-decode-tokens",
            str(args.arrival_decode_tokens),
            "--arrival-iterations",
            str(args.iterations),
        ],
        provider_dir,
    )

    raw_outputs = {
        "throughputSweep": sweep,
        "schedulerPrefill": scheduler,
        "arrivalInvariance": arrival,
    }
    validate_raw_outputs(args, sweep, scheduler, arrival)
    summary = summarize(sweep, scheduler, arrival)
    model_snapshot = resolve_model_snapshot(raw_outputs)
    hardware = sweep["hardware"]

    environment = {
        key: value
        for key, value in sorted(os.environ.items())
        if key.startswith(PERFORMANCE_ENV_PREFIXES)
    }
    report = {
        # 2: the arrival summary carries the measured delivered-topology
        # evidence (offsets, arrival error, tolerance, discarded attempts).
        "schemaVersion": 2,
        "generatedAt": generated_at,
        "label": args.label,
        "modelID": args.model,
        "modelSnapshot": model_snapshot,
        "hardware": hardware,
        "configuration": {
            "iterations": args.iterations,
            "prefillLengths": args.prefill_lengths,
            "decodePromptTokens": args.decode_prompt_tokens,
            "decodeTokens": args.decode_tokens,
            "maxBatch": args.max_batch,
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

    if not args.no_compare:
        baseline_path = Path(args.baseline)
        if not baseline_path.is_absolute():
            baseline_path = repo_root / baseline_path
        baseline = load_baseline(baseline_path)
        # Pin weights, host, and workload before any delta is computed: an
        # unpinned snapshot or a different Mac turns unrelated differences into
        # what reads as an engine regression.
        validate_baseline_pins(args, baseline, model_snapshot, hardware)
        report["comparison"] = compare(summary, baseline)

    assert_finite(report)
    markdown = markdown_report(report)
    output_dir = Path(args.output_dir)
    if not output_dir.is_absolute():
        output_dir = repo_root / output_dir
    output_dir.mkdir(parents=True, exist_ok=True)
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
    return 0
