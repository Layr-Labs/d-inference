"""Execute decode or single-request prefill ABBA controls with one fresh process per run.

Usage: PYTHONPATH=scripts python3 -m gptoss_profile.controls design.json --output artifacts/abba
"""

import argparse
import json
import os
from pathlib import Path
import sys

from .config import Cell, command, environment
from .control_design import load_design, schedule
from .control_report import read_run, summarize_controls
from .process import run
from .provenance import digest, file_pin, fingerprint, host_snapshot, model_pin, now, source_pin, write_json
from .validation import validate


def model_file_state(model):
    result = []
    for item in model["files"]:
        stat = (Path(model["path"]) / item["name"]).stat()
        result.append({"name": item["name"], "bytes": stat.st_size, "modifiedNanoseconds": stat.st_mtime_ns})
    return result


def assert_unchanged(arm, model, model_state):
    for artifact in [arm["binary"], *arm["metallibs"], arm["buildRecord"], arm["config"]]:
        if digest(artifact["path"]) != artifact["sha256"]:
            raise ValueError(f"Pinned artifact changed: {artifact['path']}")
    if model_file_state(model) != model_state:
        raise ValueError("Model snapshot file size/mtime changed after its initial full content hash")


def prepare(design_path, output, repo, cycles):
    design = load_design(design_path)
    planned = schedule(cycles)
    output.mkdir(parents=True, exist_ok=True)
    config = Path(design["config"]) if design.get("config") else output / "benchmark-defaults.toml"
    if not design.get("config"):
        if config.exists() and config.read_text() != "":
            raise ValueError("Existing default config was modified")
        config.write_text("")
    print("Pinning two arms and hashing the shared model snapshot once…", flush=True)
    model = model_pin(design["modelDirectory"])
    model_state = model_file_state(model)
    arms = {}
    for arm in design["arms"]:
        if not os.access(arm["binary"], os.X_OK):
            raise ValueError(f"Arm {arm['name']} binary is not executable")
        pins = {"label": arm["label"], "cell": arm["cell"], "binary": file_pin(arm["binary"]),
                "metallibs": [file_pin(path) for path in arm["metallibs"]],
                "buildRecord": file_pin(arm["buildRecord"]), "config": file_pin(config),
                "controls": arm["environment"], "modelID": design["modelID"], "model": model,
                "requiredACPowerMode": 2, "mode": "measurement"}
        arms[arm["name"]] = {"provenanceID": fingerprint(pins), **pins}
    pins = {"design": design, "designFileSHA256": digest(design_path), "cycles": cycles, "schedule": planned,
            "arms": arms, "modelFileState": model_state, "sourceObserved": source_pin(repo)}
    manifest = {"schemaVersion": 1, "createdAt": now(), "provenanceID": fingerprint(pins), **pins,
                "host": host_snapshot(),
                "note": "Shared model content hashed once at startup; size/mtime checked around each run. Binary, metallib, receipt, and config content hashes rechecked around each run. Current source is an observation; build receipts provide separate provenance."}
    path = output / "manifest.json"
    if path.exists():
        previous = json.loads(path.read_text())
        if previous.get("provenanceID") != manifest["provenanceID"]:
            raise ValueError("Existing ABBA output has different design/artifact/source provenance; use a new output")
        manifest = previous
    else:
        write_json(path, manifest)
    (output / "runs").mkdir(exist_ok=True)
    return manifest


def execute_controls(design_path, output, repo=None, cycles=3, timeout=3600):
    if timeout <= 0:
        raise ValueError("timeout must be positive")
    output, design_path = Path(output).resolve(), Path(design_path).resolve()
    repo = Path(repo).resolve() if repo else Path(__file__).resolve().parents[2]
    manifest = prepare(design_path, output, repo, cycles)
    design = manifest["design"]
    try:
        for planned in manifest["schedule"]:
            arm = manifest["arms"][planned["arm"]]
            cell = Cell(arm["cell"]["phase"], arm["cell"]["context"], arm["cell"]["batch"])
            spec = {"cell": cell.record(), "iterations": 1, "decodeTokens": design["decodeTokens"],
                    "backend": design["kvBackend"], "provenanceID": arm["provenanceID"],
                    "designProvenanceID": manifest["provenanceID"], "requiredACPowerMode": 2,
                    "control": planned, "warmup": "In-process full-shape benchmark warmup, excluded from the one measured repetition."}
            directory = output / "runs" / planned["name"]
            if directory.exists():
                read_run(directory, manifest, spec)
                print(f"{planned['name']}: verified prior run; skipping", flush=True)
                continue
            assert_unchanged(arm, arm["model"], manifest["modelFileState"])
            directory.mkdir()
            write_json(directory / "spec.json", spec)
            child_env, _ = environment(os.environ, [f"{key}={value}" for key, value in arm["controls"].items()])
            invocation = command(Path(arm["binary"]["path"]), design["modelID"], Path(arm["config"]["path"]),
                                 cell, 1, design["decodeTokens"], design["kvBackend"])
            print(f"Running {planned['name']} / {arm['label']} ({cell.name})…", flush=True)
            state = run(invocation, repo, child_env, directory, timeout, 2)
            try:
                if state.get("returncode") != 0 or any(state.get(key) for key in ("timedOut", "interrupted", "powerRequirementFailed")):
                    raise ValueError(f"Run failed: {state}")
                assert_unchanged(arm, arm["model"], manifest["modelFileState"])
                report = json.loads((directory / "stdout.raw").read_text())
                validate(report, spec, arm)
                write_json(directory / "validation.json", {"valid": True, "rawSHA256": digest(directory / "stdout.raw")})
                read_run(directory, manifest, spec)
            except (ValueError, KeyError, OSError, TypeError, IndexError) as error:
                write_json(directory / "validation.json", {"valid": False, "error": str(error)})
                raise
            summarize_controls(output)
    finally:
        result = summarize_controls(output)
    print(f"Comparison artifacts: {output}", flush=True)
    return 0 if result["validForPerformanceComparison"] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("design", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--repo", type=Path)
    parser.add_argument("--cycles", type=int, default=3)
    parser.add_argument("--timeout", type=float, default=3600)
    parser.add_argument("--inspect", action="store_true", help="Print normalized design/order without hashing model or launching jobs")
    parser.add_argument("--summarize", action="store_true", help="Revalidate existing raw runs only")
    args = parser.parse_args()
    try:
        if args.inspect:
            print(json.dumps({"design": load_design(args.design), "schedule": schedule(args.cycles)}, indent=2))
            return 0
        if args.summarize:
            result = summarize_controls(args.output.resolve())
            return 0 if result["validForPerformanceComparison"] else 1
        return execute_controls(args.design, args.output, args.repo, args.cycles, args.timeout)
    except (ValueError, OSError, KeyError, TypeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("Interrupted; owned benchmark stopped and raw ABBA artifacts retained.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
