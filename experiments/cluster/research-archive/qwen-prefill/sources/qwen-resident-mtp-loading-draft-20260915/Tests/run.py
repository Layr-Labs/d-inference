#!/usr/bin/env python3
"""Bounded Foundation-only actual-source check; deliberately no MLX target."""
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent


def main():
    output = Path(sys.argv[1]).resolve()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    sources = json.loads((ROOT / "Tests/source-list.json").read_text())
    for item in sources:
        data = Path(item["path"]).read_bytes()
        if len(data) != item["bytes"] or hashlib.sha256(data).hexdigest() != item["sha256"]:
            raise ValueError("Changed source: " + item["path"])
    command = ["xcrun", "swiftc", "-swift-version", "6", "-warnings-as-errors", "-parse-as-library",
               "-target", platform.machine() + "-apple-macos14.0"]
    command += [item["path"] for item in sources] + ["-o", str(output / "check")]
    receipt = {"sources": sources, "compileCommand": command, "scope": "Foundation metadata only; no MLX, GPU or payload reads"}
    for label, args in [("compile", command), ("run", [str(output / "check"), str(ROOT / "Tests/Fixtures")])]:
        start = time.monotonic()
        result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60, check=False)
        (output / (label + ".stdout")).write_bytes(result.stdout)
        (output / (label + ".stderr")).write_bytes(result.stderr)
        receipt[label] = {"exitCode": result.returncode, "elapsedSeconds": time.monotonic() - start,
                          "stdoutSHA256": hashlib.sha256(result.stdout).hexdigest(),
                          "stderrSHA256": hashlib.sha256(result.stderr).hexdigest()}
        (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        if result.returncode:
            return result.returncode
    for item in sources:
        if hashlib.sha256(Path(item["path"]).read_bytes()).hexdigest() != item["sha256"]:
            raise ValueError("Source changed while checking")
    print(result.stdout.decode().strip())
    return 0


if __name__ == "__main__":
    sys.exit(main())
