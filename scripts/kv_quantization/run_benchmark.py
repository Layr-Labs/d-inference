#!/usr/bin/env python3
"""Preserve one benchmark command, raw output, and runtime file identities."""

import argparse
import hashlib
import json
import platform
import subprocess
import time
from pathlib import Path


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--name", required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command or Path(args.name).name != args.name:
        parser.error("A command and a plain output name are required")
    directory = args.directory.resolve()
    directory.mkdir(parents=True, exist_ok=True)
    executable = Path(command[0]).resolve(strict=True)
    command[0] = str(executable)
    runtime_files = [executable, executable.parent / "mlx.metallib",
                     executable.parent / "mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal"]
    for flag in ("--config", "--kv-quality-input", "--teacher-forced-input"):
        if flag in command:
            runtime_files.append(Path(command[command.index(flag) + 1]).resolve(strict=True))
    paths = {suffix: directory / f"{args.name}.{suffix}"
             for suffix in ("command.json", "json", "stderr", "runtime.json")}
    if any(path.exists() for path in paths.values()):
        parser.error("Output already exists; choose a new attempt name")
    before = {str(path): digest(path) for path in runtime_files}
    receipt = {"schema": 1, "platform": platform.platform(),
               "startedUnixSeconds": time.time(), "runtimeBeforeSHA256": before}
    paths["command.json"].write_text(json.dumps(command, indent=2) + "\n")
    paths["runtime.json"].write_text(json.dumps(receipt, indent=2) + "\n")
    with paths["json"].open("x") as output, paths["stderr"].open("x") as errors:
        result = subprocess.run(command, cwd=directory, stdout=output, stderr=errors)
    after = {str(path): digest(path) for path in runtime_files}
    receipt.update(finishedUnixSeconds=time.time(), exitCode=result.returncode,
                   runtimeAfterSHA256=after, runtimeUnchanged=before == after)
    paths["runtime.json"].write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps({"name": args.name, "exitCode": result.returncode,
                      "runtimeUnchanged": before == after}), flush=True)
    raise SystemExit(result.returncode if before == after else 1)


if __name__ == "__main__":
    main()
