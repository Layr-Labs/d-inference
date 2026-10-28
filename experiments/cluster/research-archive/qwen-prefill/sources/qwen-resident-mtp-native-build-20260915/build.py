#!/usr/bin/env python3
"""Run only after the parent releases the local native compiler slot."""
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent
PACKAGE = ROOT / "workspace/libs/darkbloom-cluster-worker"
SCRATCH = PACKAGE / ".build-native-worker"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    output = ROOT / sys.argv[1]
    output.mkdir(mode=0o700, exist_ok=False)
    sources = json.loads((ROOT / "records/build-source-snapshot.json").read_text())
    for item in sources["members"]:
        if sha(ROOT / "workspace" / item["path"]) != item["sha256"]:
            raise ValueError("Changed build source: " + item["path"])
    resolved_before = json.loads((PACKAGE / "Package.resolved").read_text())
    receipt = {"scope": "Isolated native build plus tiny CPU factory checks; no generation/remote work",
               "sourceSnapshotSHA256": sha(ROOT / "records/build-source-snapshot.json"), "steps": []}

    def run(label, command, timeout=900):
        start = time.monotonic()
        with (output / (label + ".stdout")).open("wb") as stdout, (output / (label + ".stderr")).open("wb") as stderr:
            process = subprocess.Popen(command, stdout=stdout, stderr=stderr, start_new_session=True)
            try:
                exit_code = process.wait(timeout=timeout)
            except BaseException:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                finally:
                    process.wait()
                raise
        step = {"name": label, "command": command, "exitCode": exit_code,
                "elapsedSeconds": time.monotonic() - start,
                "stdoutSHA256": sha(output / (label + ".stdout")), "stderrSHA256": sha(output / (label + ".stderr"))}
        receipt["steps"].append(step)
        (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        print(label, "exit", exit_code, "seconds", round(step["elapsedSeconds"], 3), flush=True)
        if exit_code:
            raise SystemExit(exit_code)

    run("memory-before", ["/usr/bin/vm_stat"], 10)
    metal = json.loads((ROOT / "records/metallib.json").read_text())
    run("worker-build", ["/bin/bash", str(PACKAGE / "build-native-worker.sh"), str(PACKAGE),
                         str(ROOT / metal["destination"]), metal["sha256"]])
    command = ["swift", "build", "--package-path", str(PACKAGE), "--scratch-path", str(SCRATCH),
               "-c", "release", "--jobs", "2", "--disable-automatic-resolution", "--skip-update",
               "--disable-build-manifest-caching", "--triple", "arm64-apple-macosx26.2",
               "-Xcc", "-target", "-Xcc", "arm64-apple-macosx26.2", "--product", "MTPFactoryCheck"]
    run("fixture-build", command)
    binary = SCRATCH / "arm64-apple-macosx/release/MTPFactoryCheck"
    fixture = ROOT.parent / "qwen-resident-mtp-loading-draft-20260915/Tests/Fixtures/additional-tensors.json"
    run("factory-check", [str(binary), str(fixture)], 60)
    changed = []
    for item in sources["members"]:
        p = ROOT / "workspace" / item["path"]
        if sha(p) != item["sha256"]:
            changed.append(item["path"])
    if changed and changed != ["libs/darkbloom-cluster-worker/Package.resolved"]:
        raise ValueError("Build source changed: " + repr(changed))
    resolved_after = json.loads((PACKAGE / "Package.resolved").read_text())
    if resolved_after.get("pins") != resolved_before.get("pins"):
        raise ValueError("Resolved dependency revisions changed")
    receipt["unchangedDependencyPins"] = True
    receipt["sourceChanges"] = changed
    receipt["workerSHA256"] = sha(SCRATCH / "arm64-apple-macosx/release/darkbloom-cluster-worker")
    receipt["fixtureSHA256"] = sha(binary)
    receipt["status"] = "passed"
    (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
