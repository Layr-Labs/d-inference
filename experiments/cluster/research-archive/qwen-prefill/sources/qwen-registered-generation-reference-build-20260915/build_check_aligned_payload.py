"""Bounded compile and CPU admission checks; never starts a model."""
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
from prepare import ROOT, WORK, PACKAGE, digest, source_members


def verify(pins):
    actual = source_members(WORK)
    if actual != pins:
        raise RuntimeError("Prepared reference source changed")


def main():
    attempt = sys.argv[1]
    if len(sys.argv) != 2 or attempt not in {"build-3", "cpu-check-3"}:
        raise ValueError("Expected a fixed unused check name")
    out = ROOT / attempt
    out.mkdir(mode=0o700)
    pins = json.loads((ROOT / "source-snapshot-3.json").read_text())
    verify(pins)
    package = WORK / PACKAGE
    checkouts = package / ".build/checkouts"
    checkout_pins = source_members(checkouts)
    (out / "dependency-inputs.json").write_text(json.dumps(checkout_pins, indent=2, sort_keys=True) + "\n")
    binary = package / ".build/arm64-apple-macosx/release/cluster-inference"
    if attempt.startswith("build"):
        command = ["swift", "build", "-c", "release", "--jobs", "2", "--disable-automatic-resolution",
                   "--skip-update", "--disable-build-manifest-caching", "--product", "cluster-inference",
                   "--triple", "arm64-apple-macosx26.2", "-Xcc", "-target", "-Xcc", "arm64-apple-macosx26.2"]
        environment = dict(os.environ)
        timeout = 900
    else:
        command = [str(binary), "--mode", "qwen-registered-full-generation-reference-check"]
        environment = dict(os.environ, DARKBLOOM_RETAINED_PROFILE_FIXTURE=str(
            ROOT.parent / "qwen27b-resident-native-adapter-draft-20260915/Tests/retained-inputs.json"))
        timeout = 60
    start = time.monotonic()
    timed_out = False
    interrupted = None
    with (out / "stdout").open("xb") as stdout, (out / "stderr").open("xb") as stderr:
        child = subprocess.Popen(command, cwd=package, env=environment, stdout=stdout, stderr=stderr, start_new_session=True)
        (out / "started.json").write_text(json.dumps({"pid": child.pid, "argv": command, "timeoutSeconds": timeout}) + "\n")
        try:
            child.wait(timeout=timeout)
        except BaseException as error:
            timed_out = isinstance(error, subprocess.TimeoutExpired)
            interrupted = str(error)
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGTERM)
                try:
                    child.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait(timeout=10)
    unchanged = source_members(WORK) == pins and source_members(checkouts) == checkout_pins
    receipt = {"argv": command, "cwd": str(package), "pid": child.pid, "exitCode": child.returncode,
               "elapsedSeconds": time.monotonic() - start, "timedOut": timed_out, "interruption": interrupted,
               "sourceCount": len(pins), "dependencySourceCount": len(checkout_pins), "sourcePinsUnchanged": unchanged,
               "sourceSnapshotSHA256": digest(ROOT / "source-snapshot-3.json"),
               "stdoutSHA256": digest(out / "stdout"), "stderrSHA256": digest(out / "stderr"),
               "modelExecuted": False, "remoteOperations": False}
    if child.returncode == 0 and binary.exists():
        receipt["binarySHA256"] = digest(binary)
    if attempt.startswith("cpu") and child.returncode == 0:
        receipt["result"] = json.loads((out / "stdout").read_text())
    (out / "execution.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, sort_keys=True), flush=True)
    sys.exit(0 if child.returncode == 0 and unchanged and interrupted is None else 1)


if __name__ == "__main__":
    main()
