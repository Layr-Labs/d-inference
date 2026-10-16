#!/usr/bin/env python3
"""Run a frozen candidate sequentially; keep every result, including failures."""
import argparse
import datetime
import hashlib
import json
import os
import pathlib
import signal
import shutil
import stat
import subprocess
import tempfile
import time

from curate_runs import assistant_identity, execution_artifacts, report_projection
from qualification_environment import child_environment, environment_identity
from suite_inputs import PreparedSuite, validate_report_input


def sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_candidate(directory, receipt):
    for name, expected in receipt["artifacts"].items():
        if pathlib.Path(name).name != name:
            raise RuntimeError("Invalid candidate artifact filename: " + name)
        if sha(directory / name) != expected:
            raise RuntimeError("Frozen candidate changed: " + name)
    resources = {str(path.relative_to(directory)): sha(path)
                 for path in sorted(directory.glob("*.bundle/**/*")) if path.is_file()}
    if resources != receipt.get("resources", {}):
        raise RuntimeError("Frozen candidate resource inventory changed")


def assistant_files(directory, allow_symlinks=False):
    if not directory.is_dir() or (directory.is_symlink() and not allow_symlinks):
        raise RuntimeError("Assistant snapshot must be a directory")
    paths = sorted(directory.iterdir())
    # Match the production local-assistant inventory limits, before copying bytes.
    if not 2 <= len(paths) <= 64 or not any(path.name == "config.json" for path in paths):
        raise RuntimeError("Assistant requires config.json and at most 63 weight files")
    size = 0
    for path in paths:
        metadata = path.stat()
        if (path.name != "config.json" and not path.name.endswith(".safetensors")
                or not stat.S_ISREG(metadata.st_mode) or metadata.st_size <= 0
                or path.is_symlink() and not allow_symlinks):
            raise RuntimeError("Invalid assistant file: " + str(path))
        if path.name == "config.json" and metadata.st_size > 1 << 20:
            raise RuntimeError("Assistant config exceeds 1 MiB")
        size += metadata.st_size
    if size > 2 << 30:
        raise RuntimeError("Assistant snapshot exceeds 2 GiB")
    if not allow_symlinks and (stat.S_IMODE(directory.stat().st_mode) != 0o500
                              or any(stat.S_IMODE(path.stat().st_mode) != 0o400 for path in paths)):
        raise RuntimeError("Assistant snapshot is not read-only")
    return {path.name: sha(path) for path in paths}


def verify_assistant(source, snapshot, expected):
    if assistant_files(source, allow_symlinks=True) != expected:
        raise RuntimeError("Assistant source changed during qualification")
    if assistant_files(snapshot) != expected:
        raise RuntimeError("Assistant snapshot changed during qualification")


def evidence_path(stem, suffix):
    # Model IDs contain periods; replacing a suffix would collapse distinct
    # task/profile names such as qwen3.6-...-native and qwen3.6-...-balanced.
    return stem.parent / (stem.name + suffix)


def launch(command, output, timeout, environment):
    started = time.monotonic()
    with evidence_path(output, ".json").open("wb") as stdout, evidence_path(output, ".log").open("wb") as stderr:
        try:
            process = subprocess.Popen(command, stdout=stdout, stderr=stderr, env=environment, start_new_session=True)
        except OSError as error:
            stderr.write((str(error) + "\n").encode())
            return "launch_failed", time.monotonic() - started
        try:
            code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            code = "timeout"
    return code, time.monotonic() - started


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--candidate", type=pathlib.Path, required=True)
    parser.add_argument("--config", type=pathlib.Path, required=True)
    parser.add_argument("--inputs", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--models", nargs="+", required=True)
    parser.add_argument("--tasks", nargs="+", default=["retrieval", "arithmetic", "program", "long_retrieval"])
    parser.add_argument("--profiles", nargs="+", default=["native", "balanced"])
    parser.add_argument("--mtp", action="store_true")
    parser.add_argument("--assistant-directory", type=pathlib.Path)
    parser.add_argument("--scores", action="store_true")
    parser.add_argument("--timeout", type=int, default=1200)
    args = parser.parse_args()
    if args.assistant_directory is not None and not args.mtp:
        parser.error("--assistant-directory requires --mtp")
    if args.assistant_directory is not None:
        args.assistant_directory = args.assistant_directory.expanduser()
    prepared = PreparedSuite(args.inputs)
    receipt = json.loads((args.candidate / "source-receipt.json").read_text())
    verify_candidate(args.candidate, receipt)
    args.output.mkdir(parents=True, exist_ok=True)
    if any(args.output.iterdir()):
        raise RuntimeError("Will not overwrite existing qualification evidence: " + str(args.output))
    modes = [task for task in args.tasks if task != "none"] + (["scores"] if args.scores else [])
    if not modes or any(profile not in ("native", "balanced", "k8v4", "k8v8") for profile in args.profiles):
        parser.error("select a task/score mode and canonical KV profiles")
    selections = [prepared.select(model, mode)[0] for model in args.models for mode in modes]
    frozen_inputs = args.output / "inputs"
    frozen_inputs.mkdir()
    names = {"suite.json"} | {entry[key] for entry in selections for key in ("file", "scoreFile")}
    for name in names:
        shutil.copyfile(args.inputs / name, frozen_inputs / name)
    prepared = PreparedSuite(frozen_inputs)
    for expected in selections:
        if prepared.select(expected["modelID"], expected["mode"])[0] != expected:
            raise RuntimeError("Prepared input changed while freezing")
    config_snapshot = args.output / "provider-config.toml"
    shutil.copyfile(args.config, config_snapshot)
    config_digest = sha(config_snapshot)
    # Resolve only the parent, not a symlinked config's target. Relative cache
    # paths keep their anchor, including parent symlinks/..; cwd stays unchanged.
    descriptor, name = tempfile.mkstemp(prefix=".qualification-", suffix=".toml", dir=args.config.parent.resolve())
    active_config = pathlib.Path(name)
    assistant_snapshot = None
    try:
        with os.fdopen(descriptor, "wb") as destination, config_snapshot.open("rb") as source:
            shutil.copyfileobj(source, destination)
            destination.flush()
            os.fchmod(destination.fileno(), 0o400)
        environment = child_environment(os.environ)
        assistant = {"identities": {}} if args.mtp and any(mode != "scores" for mode in modes) else None
        if args.assistant_directory is not None and assistant is not None:
            files = assistant_files(args.assistant_directory, allow_symlinks=True)
            assistant_snapshot = pathlib.Path(tempfile.mkdtemp(prefix=".assistant-", dir=args.output.resolve()))
            for name in files:
                destination = assistant_snapshot / name
                shutil.copyfile(args.assistant_directory / name, destination)
                destination.chmod(0o400)
            assistant_snapshot.chmod(0o500)
            verify_assistant(args.assistant_directory, assistant_snapshot, files)
            assistant.update(sourcePath=str(args.assistant_directory.absolute()), path=str(assistant_snapshot),
                             files=files)
        qualification = {"suiteSHA256": prepared.digest, "configSHA256": config_digest,
                         "configPath": str(args.config.resolve()), "activeConfigPath": str(active_config),
                         "environment": environment_identity(environment),
                         "runnerFiles": {name: sha(pathlib.Path(__file__).with_name(name))
                                          for name in ("run_suite.py", "curate_runs.py", "suite_inputs.py",
                                                       "qualification_environment.py")}}
        if assistant is not None:
            qualification["assistant"] = assistant
        results = []
        manifest = {"schema": 2, "candidateSourceDigest": receipt["source_file_digest"],
                    "candidateArtifacts": receipt["artifacts"], "candidateResources": receipt.get("resources", {}),
                    "qualification": qualification, "results": results}
        manifest_path = args.output / "run.json"
        manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
        for model in args.models:
            safe = model.replace("/", "--")
            for mode in modes:
                for profile in args.profiles:
                    label = f"{safe}-{mode}-{profile}" + ("-mtp" if args.mtp and mode != "scores" else "")
                    stem = args.output / label
                    if evidence_path(stem, ".json").exists() or evidence_path(stem, ".log").exists():
                        raise RuntimeError("Will not overwrite existing evidence: " + label)
                    identity, input_path, score_document = prepared.select(model, mode)
                    if any(sha(path) != config_digest for path in (args.config, config_snapshot, active_config)):
                        raise RuntimeError("Qualification config changed before arm: " + label)
                    command = [str(args.candidate / "darkbloom"), "benchmark", "--config", str(active_config),
                               "--model", model, "--kv-backend", "paged", "--kv-quantization", profile]
                    if mode == "scores":
                        command += ["--teacher-forced-input", str(input_path)]
                    else:
                        command += ["--runtime-generation", "--runtime-prompt-date", identity["renderDate"],
                                    "--runtime-prompt-file", str(input_path),
                                    "--max-tokens", str(identity["maximumGeneratedTokens"])]
                        if args.mtp:
                            command.append("--runtime-mtp")
                            if assistant_snapshot is not None:
                                command += ["--runtime-assistant-directory", assistant["path"]]
                    print(json.dumps({"started": label, "utc": datetime.datetime.now(datetime.timezone.utc).isoformat()}), flush=True)
                    if assistant_snapshot is not None:
                        verify_assistant(args.assistant_directory, assistant_snapshot, assistant["files"])
                    verify_candidate(args.candidate, receipt)
                    code, elapsed = launch(command, stem, args.timeout, environment)
                    entry = {"modelID": model, "mode": mode, "requestedPrecision": profile,
                             "command": command, "exitCode": code, "processSeconds": elapsed,
                             "inputIdentity": identity,
                             "configBeforeSHA256": config_digest}
                    try:
                        verify_candidate(args.candidate, receipt)
                        if assistant_snapshot is not None:
                            verify_assistant(args.assistant_directory, assistant_snapshot, assistant["files"])
                        entry["configAfterSHA256"] = sha(active_config)
                        report = json.loads(evidence_path(stem, ".json").read_text())
                        validate_report_input(report, mode, identity, score_document, profile)
                        execution_artifacts(report, mode, receipt["artifacts"], stem)
                        if (prepared.select(model, mode)[0] != identity
                                or entry["configAfterSHA256"] != config_digest
                                or any(sha(path) != config_digest for path in (args.config, config_snapshot))):
                            raise RuntimeError("Qualification input/config changed during arm")
                        projection = report_projection(report, mode, identity)
                        if assistant is not None and mode != "scores":
                            assistant["identities"][model] = assistant_identity(
                                report, assistant.get("files"), assistant["identities"].get(model))
                        entry.update(projection)
                        entry["reportParsed"] = True
                    except (ValueError, KeyError, RuntimeError, OSError) as error:
                        entry["reportParsed"] = False
                        entry["parseError"] = str(error)
                    entry["jsonSHA256"] = sha(evidence_path(stem, ".json"))
                    entry["logSHA256"] = sha(evidence_path(stem, ".log"))
                    results.append(entry)
                    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
                    print(json.dumps({"finished": label, "exitCode": code, "seconds": round(elapsed, 3),
                                      "taskPassed": entry.get("taskPassed"), "nll": entry.get("meanForcedTokenNLL")}), flush=True)
        if any(item["exitCode"] != 0 or not item["reportParsed"]
               or not item.get("identityPassed")
               or (item["mode"] != "scores" and item.get("taskPassed") is not True)
               for item in results):
            raise SystemExit(1)
    finally:
        try:
            if assistant_snapshot is not None:
                assistant_snapshot.chmod(0o700)
                shutil.rmtree(assistant_snapshot)
        finally:
            active_config.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
