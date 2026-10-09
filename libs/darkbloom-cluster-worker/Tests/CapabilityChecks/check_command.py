#!/usr/bin/env python3
"""Run the compiled CPU fixture, never the native/model worker."""
import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile


def main(binary, fixtures):
    binary, fixtures = pathlib.Path(binary).resolve(strict=True), pathlib.Path(fixtures).resolve(strict=True)
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    names = ["registered-qwen35-9b.configuration.json", "registered-qwen35-9b.manifest.json"]
    originals = [(fixtures / name).read_bytes() for name in names]
    cases = []
    with tempfile.TemporaryDirectory(prefix="capability-command-") as temporary:
        directory = pathlib.Path(temporary)
        config, manifest = directory / "config.json", directory / "manifest.json"
        config.write_bytes(originals[0]); manifest.write_bytes(originals[1])
        link = directory / "config-link"; link.symlink_to(config)
        argv = [str(binary), "--describe-runtime", "--config", str(config), "--manifest", str(manifest),
                "--expected-executable-sha256", digest]

        def case(name, args, success, contains=None):
            result = subprocess.run(args, capture_output=True, timeout=20)
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
            cases.append(name)

        case("actual-fixture-executable-binding", argv, True)
        wrong = list(argv); wrong[-1] = "0" * 64; wrong[3] = str(directory / "does-not-exist")
        case("binary-refusal-precedes-metadata-open", wrong, False, b"Installed executable bytes differ")
        symlink = list(argv); symlink[3] = str(link)
        case("symlink-input-refused", symlink, False, b"Cannot open metadata input")
        case("extra-option-refused", argv + ["--mtp"], False, b"Expected --describe-runtime")
        config.write_bytes(config.read_bytes() + b" ")
        case("changed-config-refused", argv, False, b"exact registered 9B")
    assert [(fixtures / name).read_bytes() for name in names] == originals
    assert hashlib.sha256(binary.read_bytes()).hexdigest() == digest
    print(json.dumps({"passed": True, "actualCPUChildren": len(cases), "cases": cases,
                      "nativeWorkerExecuted": False, "modelOrGPUExecution": False}, sort_keys=True))


if __name__ == "__main__":
    main(*sys.argv[1:])
