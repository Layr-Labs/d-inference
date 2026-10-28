#!/usr/bin/env python3
"""Private bounded owner-only Foundation relink; never launches a model or network."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent
BASE = ROOT.parent / "owner-retirement-controls-build-20260915"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def run(command, directory, timeout):
    directory.mkdir()
    began = time.monotonic()
    interrupted = None
    with (directory / "stdout").open("wb") as out, (directory / "stderr").open("wb") as err:
        child = subprocess.Popen(command, stdout=out, stderr=err, start_new_session=True)
        try:
            child.wait(timeout=timeout)
        except BaseException as error:
            interrupted = type(error).__name__
            # wait() may reap before rethrowing KeyboardInterrupt. Do not poll first.
            if child.returncode is None:
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                child.wait(timeout=10)
    receipt = {"command": command, "pid": child.pid, "exitCode": child.returncode,
               "elapsedSeconds": time.monotonic() - began, "interruption": interrupted,
               "stdoutSHA256": sha(directory / "stdout"), "stderrSHA256": sha(directory / "stderr")}
    write(directory / "execution.json", receipt)
    if child.returncode != 0 or interrupted:
        raise RuntimeError("bounded operation failed: " + str(directory))
    return receipt


def main():
    build = ROOT / sys.argv[1]
    build.mkdir()
    artifacts = build / "artifacts"
    artifacts.mkdir()
    inputs = sorted((ROOT / "Sources").glob("*.swift")) + sorted((ROOT / "Tests").glob("*.swift"))
    inputs += sorted((ROOT / "Dependencies").iterdir()) + [Path(__file__).resolve()]
    pins = {str(p.relative_to(ROOT)): {"sha256": sha(p), "bytes": p.stat().st_size} for p in inputs}
    for p in sorted((ROOT / "Dependencies").iterdir()):
        assert p.read_bytes() == (BASE / "build-1/artifacts" / p.name).read_bytes(), p.name
    write(build / "source-pins.json", pins)
    for p in (ROOT / "Dependencies").glob("*.dylib"):
        shutil.copy2(p, artifacts / p.name)
    common = ["xcrun", "swiftc", "-j", "2", "-swift-version", "6", "-warnings-as-errors",
              "-target", "arm64-apple-macos14.0", "-I", str(ROOT / "Dependencies"),
              "-L", str(ROOT / "Dependencies"), "-lDarkbloomClusterProtocol", "-lDarkbloomClusterProcess",
              "-lDarkbloomClusterRemote", "-lDarkbloomClusterBootstrap", "-Xlinker", "-rpath", "-Xlinker", "@executable_path"]
    receipts = []
    receipts.append(run(common + [str(p) for p in sorted((ROOT / "Sources").glob("*.swift"))]
                        + ["-o", str(artifacts / "darkbloom-owner-qualification")], build / "owner-build", 90))
    receipts.append(run(common + ["-parse-as-library", str(ROOT / "Sources/OwnerNativeDiagnostics.swift"),
                        str(ROOT / "Tests/DiagnosticsCheck.swift"), "-o", str(artifacts / "diagnostics-check")],
                        build / "fixture-build", 90))
    receipts.append(run([str(artifacts / "diagnostics-check")], build / "fixture-run", 20))
    after = {str(p.relative_to(ROOT)): {"sha256": sha(p), "bytes": p.stat().st_size} for p in inputs}
    assert after == pins, "source changed during build/check"
    write(build / "result.json", {"passed": True, "sourcePinsUnchanged": True, "inputCount": len(pins),
          "operations": receipts, "modelOrNetworkExecuted": False, "moduleLibrariesRebuilt": False,
          "nativeWorkerOrControllerChanged": False})
    print(json.dumps({"passed": True, "build": str(build), "operations": len(receipts)}, sort_keys=True))


if __name__ == "__main__":
    main()
