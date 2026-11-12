#!/usr/bin/env python3
"""Read-only source/baseline checks. Does not compile or run Swift fixtures."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True, type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent
    integration = json.loads((root / "integration.json").read_text())
    for item in integration["files"]:
        relative = item["path"]
        assert digest(root / "proposed" / relative) == item["sha256"], relative
        if item["baseSHA256"] is None:
            assert not (args.repo / relative).exists(), relative
        else:
            assert digest(root / "originals" / relative) == item["baseSHA256"], relative
            assert digest(args.repo / relative) == item["baseSHA256"], relative
    inputs = json.loads((root / "source-inputs.json").read_text())
    for item in inputs:
        location = root / "proposed" if item["source"] == "proposed" else args.repo
        assert digest(location / item["path"]) == item["sha256"], item["path"]
    commands = [["git", "apply", "--check", "--whitespace=error-all", str(root / "overlay.patch")]]
    for runner in integration["fixtureRunners"]:
        commands.append(["bash", "-n", str(root / "proposed" / runner)])
    checks = []
    for command in commands:
        result = subprocess.run(command, cwd=args.repo, capture_output=True, text=True, timeout=20)
        assert result.returncode == 0, (command, result.returncode, result.stdout, result.stderr)
        checks.append({"argv": command, "exitCode": result.returncode, "stdout": result.stdout, "stderr": result.stderr})
    print(json.dumps({"passed": True, "proposedFiles": len(integration["files"]),
        "pinnedSourceInputs": len(inputs), "checks": checks,
        "swiftCompiled": False, "swiftFixturesExecuted": False,
        "nativeModelOrRemoteExecution": False, "mainEdited": False}, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
