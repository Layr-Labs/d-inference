#!/usr/bin/env python3
"""Small Foundation/CryptoKit checks. No SwiftPM, MLX, model or native worker run."""
import hashlib
import json
import pathlib
import platform
import subprocess
import sys
import time


def main(main_repo, output):
    draft = pathlib.Path(__file__).resolve().parent.parent
    main_repo, output = pathlib.Path(main_repo).resolve(strict=True), pathlib.Path(output)
    output.mkdir()
    inputs = json.loads((draft / "source-inputs.json").read_bytes())
    resolved = {}
    for entry in inputs["files"]:
        base = draft if entry["origin"] == "draft" else main_repo
        path = base / entry["path"]
        assert hashlib.sha256(path.read_bytes()).hexdigest() == entry["sha256"], path
        resolved[entry["id"]] = path
    stages = []

    def call(name, argv):
        started = time.monotonic()
        result = subprocess.run(list(map(str, argv)), capture_output=True, timeout=30)
        (output / (name + ".stdout")).write_bytes(result.stdout)
        (output / (name + ".stderr")).write_bytes(result.stderr)
        stages.append({"name": name, "argv": list(map(str, argv)), "returncode": result.returncode,
                       "elapsed_seconds": time.monotonic() - started,
                       "stdout_sha256": hashlib.sha256(result.stdout).hexdigest(),
                       "stderr_sha256": hashlib.sha256(result.stderr).hexdigest()})
        (output / "execution.json").write_text(json.dumps({"stages": stages, "native_or_gpu_execution": False}, sort_keys=True, indent=2) + "\n")
        if result.returncode:
            raise RuntimeError(name + ": " + result.stderr.decode("utf-8", "replace"))

    common = ["xcrun", "swiftc", "-swift-version", "6", "-warnings-as-errors", "-target", platform.machine() + "-apple-macosx14.0"]
    for group, module in [("protocol", "DarkbloomClusterProtocol"), ("metadata", "DarkbloomClusterRuntime")]:
        argv = common + ["-emit-module", "-emit-library", "-module-name", module,
                         "-emit-module-path", output / (module + ".swiftmodule"), "-o", output / ("lib" + module + ".dylib")]
        if group == "metadata":
            argv += ["-I", output, "-L", output, "-lDarkbloomClusterProtocol"]
        call(group, argv + [resolved[key] for key in inputs[group]])
    links = ["-I", output, "-L", output, "-lDarkbloomClusterProtocol", "-lDarkbloomClusterRuntime", "-Xlinker", "-rpath", "-Xlinker", output]
    call("compile-check", common + links + [resolved[key] for key in inputs["fixture"]] + ["-o", output / "check"])
    call("check", [output / "check", resolved["retained-metadata"]])
    call("compile-original-protocol-check", common + ["-parse-as-library"] + links + [resolved["original-protocol-test"], "-o", output / "original-protocol-check"])
    call("original-protocol-check", [output / "original-protocol-check"])
    call("actual-command-check", [sys.executable, draft / "fixtures/check_command.py", output / "check", resolved["retained-metadata"], output / "command-checks"])
    for entry in inputs["files"]:
        assert hashlib.sha256(resolved[entry["id"]].read_bytes()).hexdigest() == entry["sha256"], entry["id"]
    print("PASS: capability 6/67; existing protocol 7 groups; 5 actual CPU metadata children; all source pins stable")


if __name__ == "__main__":
    main(*sys.argv[1:])
