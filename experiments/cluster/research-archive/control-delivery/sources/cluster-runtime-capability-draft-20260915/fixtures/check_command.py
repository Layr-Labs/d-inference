#!/usr/bin/env python3
"""Actual CPU fixture children only; never launches the native/model worker."""
import base64
import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile
import time


def run(binary, retained, output):
    binary = pathlib.Path(binary).resolve(strict=True)
    retained = pathlib.Path(retained).resolve(strict=True)
    output = pathlib.Path(output)
    output.mkdir()
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    original = retained.read_bytes()
    inputs = json.loads(original)
    records = []
    with tempfile.TemporaryDirectory(prefix="capability-command-") as temporary:
        directory = pathlib.Path(temporary)
        config = directory / "config.json"
        manifest = directory / "manifest.json"
        config.write_bytes(base64.b64decode(inputs["nine"]["configuration"], validate=True))
        manifest.write_bytes(base64.b64decode(inputs["nine"]["manifest"], validate=True))
        link = directory / "config-link"
        link.symlink_to(config)
        argv = [str(binary), "--describe-runtime", "--config", str(config), "--manifest", str(manifest),
                "--expected-executable-sha256", digest]

        def case(name, args, success, contains=None):
            started = time.monotonic()
            result = subprocess.run(args, capture_output=True, timeout=20)
            (output / (name + ".stdout")).write_bytes(result.stdout)
            (output / (name + ".stderr")).write_bytes(result.stderr)
            assert (result.returncode == 0) is success, (name, result.returncode, result.stderr)
            if success:
                assert result.stderr == b""
                value = json.loads(result.stdout)
                assert value["runtimeBinarySHA256"] == digest
                assert value["profile"]["maximumOutputTokens"] == 128
                assert [p["stages"][0]["sourceLayerEnd"] for p in value["partitions"]] == [4, 8, 12, 16]
                assert result.stdout == (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()
            else:
                assert result.stdout == b"", name
                assert contains in result.stderr, (name, result.stderr)
            records.append({"name": name, "argv": args, "returncode": result.returncode,
                            "elapsed_seconds": time.monotonic() - started,
                            "stdout_sha256": hashlib.sha256(result.stdout).hexdigest(),
                            "stderr_sha256": hashlib.sha256(result.stderr).hexdigest()})

        case("actual-fixture-executable-binding", argv, True)
        wrong = list(argv); wrong[-1] = "0" * 64; wrong[3] = str(directory / "does-not-exist")
        case("binary-refusal-precedes-metadata-open", wrong, False, b"Installed executable bytes differ")
        symlink = list(argv); symlink[3] = str(link)
        case("symlink-input-refused", symlink, False, b"Cannot open metadata input")
        case("extra-option-refused", argv + ["--mtp"], False, b"Expected --describe-runtime")
        config.write_bytes(config.read_bytes() + b" ")
        case("changed-config-refused", argv, False, b"exact registered 9B")
        assert retained.read_bytes() == original
        assert hashlib.sha256(binary.read_bytes()).hexdigest() == digest
    receipt = {"schema": "private_capability_cpu_command_checks_v1", "cases": records,
               "fixture_binary_sha256": digest, "retained_metadata_sha256": hashlib.sha256(original).hexdigest(),
               "native_worker_executed": False, "model_or_gpu_execution": False,
               "installed_native_capability_qualified": False}
    (output / "execution.json").write_text(json.dumps(receipt, sort_keys=True, indent=2) + "\n")
    print("PASS: 5 actual CPU fixture child checks")


if __name__ == "__main__":
    run(*sys.argv[1:])
