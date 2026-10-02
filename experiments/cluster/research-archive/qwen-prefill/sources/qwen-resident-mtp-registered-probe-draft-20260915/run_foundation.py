"""Pinned model-free control/cleanup checks. Run only in the granted compiler slot."""
import hashlib
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: run_foundation.py NEW_OUTPUT_DIRECTORY")
    output = Path(sys.argv[1]).absolute()
    output.mkdir(exist_ok=False, parents=True)
    sources = json.loads((ROOT / "foundation-inputs.json").read_bytes())

    def verify():
        for item in sources:
            assert hashlib.sha256(Path(item["path"]).read_bytes()).hexdigest() == item["sha256"], item["path"]

    verify()
    binary = output / "probe-control-check"
    command = ["xcrun", "swiftc", "-swift-version", "6", "-warnings-as-errors"]
    command += [item["path"] for item in sources] + ["-o", str(binary)]
    (output / "command.json").write_text(json.dumps(command, indent=2) + "\n")
    receipt = {"sourceCount": len(sources), "modelOrNativeGPUExecuted": False}
    for label, argv, timeout in [("compile", command, 60), ("check", [str(binary)], 15)]:
        started = time.monotonic()
        process = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        try:
            stdout, stderr = process.communicate(timeout=timeout)
            (output / (label + ".stdout")).write_bytes(stdout)
            (output / (label + ".stderr")).write_bytes(stderr)
            receipt[label] = {"exitCode": process.returncode, "elapsedSeconds": time.monotonic() - started}
            passed = process.returncode == 0
        except subprocess.TimeoutExpired as error:
            (output / (label + ".stdout")).write_bytes(error.stdout or b"")
            (output / (label + ".stderr")).write_bytes(error.stderr or b"")
            cleanup_errors = []
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            except OSError as failure:
                cleanup_errors.append(type(failure).__name__)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                cleanup_errors.append("owned_compiler_or_check_not_reaped")
            receipt[label] = {"timedOut": True, "elapsedSeconds": time.monotonic() - started,
                              "exitCode": process.returncode, "cleanupErrors": cleanup_errors}
            passed = False
        (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        if not passed:
            raise SystemExit(1)
    verify()
    receipt["inputPinsUnchanged"] = True
    receipt["passed"] = True
    (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, sort_keys=True))


if __name__ == "__main__":
    main()
