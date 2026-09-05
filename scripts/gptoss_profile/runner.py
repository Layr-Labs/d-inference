"""CLI orchestration; no builds, installs, service changes, or parallel GPU jobs."""

import argparse
import json
import os
import sys
from pathlib import Path

from .config import cells, command, environment
from .process import run
from .power import power_failure
from .provenance import assert_artifacts_unchanged, digest, file_pin, fingerprint, host_snapshot, model_pin, now, source_pin, write_json
from .summary import summarize
from .validation import validate


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    commands = result.add_subparsers(dest="action", required=True)
    execute = commands.add_parser("run", help="Run an explicit sequential benchmark matrix")
    execute.add_argument("--binary", type=Path, required=True)
    execute.add_argument("--model", default="mlx-community/gpt-oss-20b-MXFP4-Q8")
    execute.add_argument("--model-dir", type=Path, required=True, help="Exact scanner-resolved snapshot, hashed before execution")
    execute.add_argument("--metallib", type=Path, action="append", required=True, help="Loaded Metal library path; repeat for multiple libraries")
    execute.add_argument("--config", type=Path, help="Optional provider TOML; hash recorded, contents never copied")
    execute.add_argument("--build-record", "--build-receipt", type=Path, help="Optional build provenance JSON/log to hash and associate with supplied binary")
    execute.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[2])
    execute.add_argument("--output", type=Path, required=True)
    execute.add_argument("--phase", choices=("all", "prefill", "decode", "arrival"), default="all")
    execute.add_argument("--cells", help="Comma-separated names, e.g. decode-512-b1,decode-512-b2,decode-512-b4")
    execute.add_argument("--iterations", type=int, default=5)
    execute.add_argument("--decode-tokens", type=int, default=256)
    execute.add_argument("--kv-backend", choices=("contiguous", "paged"), default="contiguous")
    execute.add_argument("--timeout", type=float, default=3600, help="Per-cell seconds; kills only the owned child process group")
    execute.add_argument("--mode", choices=("measurement", "diagnostic"), default="measurement")
    execute.add_argument("--require-ac-power-mode", type=int, choices=(0, 1, 2),
                         help="Require AC power with this pmset powermode before AND after every cell (2 = High Power)")
    execute.add_argument("--env", action="append", default=[], help="Explicit performance KEY=VALUE; inherited experimental flags are cleared")
    execute.add_argument("--rerun", action="store_true", help="Archive and rerun matching existing cells; never silently overwrite raw artifacts")
    execute.add_argument("--keep-going", action="store_true", help="Continue after an invalid cell, retaining failure and nonzero final exit")
    execute.add_argument("--list-cells", action="store_true", help="Print selection without hashing or launching a benchmark")
    summary = commands.add_parser("summarize", help="Revalidate raw artifacts and regenerate JSON/CSV/Markdown")
    summary.add_argument("output", type=Path)
    return result


def execute(args):
    selected = cells(args.phase, args.cells)
    if args.list_cells:
        print("\n".join(cell.name for cell in selected))
        return 0
    if args.iterations < 1 or args.decode_tokens < 32 or args.timeout <= 0:
        raise ValueError("Require positive iterations/timeout and at least 32 decode tokens")
    binary, repo, output = args.binary.resolve(), args.repo.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if args.config:
        config = args.config.resolve()
    else:
        config = output / "benchmark-defaults.toml"
        if config.exists() and config.read_text() != "":
            raise ValueError("Default benchmark config was modified; use a new output or explicit --config")
        config.write_text("")
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise ValueError("--binary must name an existing executable; this runner does not build")
    child_env, controls = environment(os.environ, args.env)
    instrumentation = [key for key, value in controls.items()
                       if any(word in key for word in ("PROFILE", "TRACE", "TIMING", "CAPTURE", "DEBUG"))
                       and value.lower() not in {"0", "false", "no", "off", ""}]
    if args.mode == "measurement" and instrumentation:
        raise ValueError(f"Instrumentation controls require --mode diagnostic: {instrumentation}")
    print("Hashing binary, Metal libraries, and model snapshot for run provenance…", flush=True)
    pins = {"binary": file_pin(binary), "metallibs": [file_pin(p) for p in args.metallib],
            "model": model_pin(args.model_dir), "modelID": args.model,
            "config": file_pin(config) if config else None,
            "buildRecord": file_pin(args.build_record) if args.build_record else None,
            "controls": controls, "source": source_pin(repo), "mode": args.mode,
            "requiredACPowerMode": args.require_ac_power_mode,
            "workload": {"iterations": args.iterations, "decodeTokens": args.decode_tokens,
                         "backend": args.kv_backend},
            "environmentPolicy": "Inherited DARKBLOOM_, MLX_, DYLD_, MTL_, METAL_ keys removed; only explicit controls re-added.",
            "benchmarkConstruction": "Prefix cache and MTP drafter omitted by production benchmark factory; explicit env disables both as an additional guard."}
    provenance_id = fingerprint(pins)
    manifest = {"schemaVersion": 1, "createdAt": now(), "provenanceID": provenance_id, **pins,
                "host": host_snapshot()}
    if (output / "manifest.json").exists():
        previous = json.loads((output / "manifest.json").read_text())
        if previous.get("provenanceID") != provenance_id:
            raise ValueError("Existing output has different binary/model/source/environment/workload provenance; use a new --output")
        manifest = previous
    else:
        write_json(output / "manifest.json", manifest)
    (output / "cells").mkdir(exist_ok=True)
    failed = False
    for cell in selected:
        spec = {"cell": cell.record(), "iterations": args.iterations, "decodeTokens": args.decode_tokens,
                "backend": args.kv_backend, "provenanceID": provenance_id,
                "requiredACPowerMode": args.require_ac_power_mode,
                "warmup": "In-process benchmark warmup before measured repetitions; retain stderr for exact implementation evidence."}
        destination = output / "cells" / cell.name
        if destination.exists():
            old_spec = json.loads((destination / "spec.json").read_text())
            if old_spec != spec:
                raise ValueError(f"{cell.name}: existing cell has a different workload contract; use a new output directory")
            if not args.rerun:
                state = json.loads((destination / "process.json").read_text())
                if state.get("returncode") != 0 or state.get("timedOut") or state.get("interrupted") or state.get("powerRequirementFailed"):
                    raise ValueError(f"{cell.name}: previous process failed; use --rerun to archive and retry")
                validation = json.loads((destination / "validation.json").read_text())
                if not validation.get("valid") or validation.get("rawSHA256") != digest(destination / "stdout.raw"):
                    raise ValueError(f"{cell.name}: raw output failed validation or changed; use --rerun to archive and retry")
                validate(json.loads((destination / "stdout.raw").read_text()), spec, manifest)
                for moment in ("before", "after"):
                    failure = power_failure(json.loads((destination / f"host-{moment}.json").read_text()), args.require_ac_power_mode)
                    if failure:
                        raise ValueError(f"{cell.name}: recorded {moment} power invalid: {failure}")
                print(f"{cell.name}: verified existing same-provenance result, skipping", flush=True)
                continue
            archive = output / "archive" / now().replace(":", "-")
            archive.mkdir(parents=True)
            destination.rename(archive / cell.name)
        assert_artifacts_unchanged(pins)
        destination.mkdir()
        write_json(destination / "spec.json", spec)
        invocation = command(binary, args.model, config, cell, args.iterations, args.decode_tokens, args.kv_backend)
        print(f"Running {cell.name} ({args.iterations} repetitions)…", flush=True)
        state = run(invocation, repo, child_env, destination, args.timeout, args.require_ac_power_mode)
        try:
            assert_artifacts_unchanged(pins)
            if state.get("powerRequirementFailed"):
                raise ValueError(state["powerRequirementFailed"])
            if state.get("returncode") != 0 or state.get("timedOut"):
                raise ValueError(f"Benchmark failed: returncode={state.get('returncode')} timedOut={state.get('timedOut', False)}")
            report = json.loads((destination / "stdout.raw").read_text())
            validate(report, spec, manifest)
            write_json(destination / "validation.json", {"valid": True, "rawSHA256": digest(destination / "stdout.raw")})
        except (ValueError, OSError, KeyError, TypeError, IndexError) as error:
            failed = True
            write_json(destination / "validation.json", {"valid": False, "error": str(error)})
            print(f"{cell.name}: INVALID: {error}", file=sys.stderr, flush=True)
            if not args.keep_going:
                summarize(output)
                return 1
        summarize(output)
    summary = summarize(output)
    print(f"Artifacts and summaries: {output}", flush=True)
    return 1 if failed or summary["failures"] else 0


def main():
    args = parser().parse_args()
    try:
        if args.action == "summarize":
            summary = summarize(args.output)
            print(json.dumps({"validCells": len(summary["cells"]), "failures": summary["failures"]}, indent=2))
            return bool(summary["failures"])
        return execute(args)
    except (ValueError, OSError, KeyError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("Interrupted; owned benchmark stopped and raw artifacts retained.", file=sys.stderr)
        return 130
