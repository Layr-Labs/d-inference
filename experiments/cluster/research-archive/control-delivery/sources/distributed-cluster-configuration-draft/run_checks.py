#!/usr/bin/env python3
"""Small Swift/Foundation checks only; no SwiftPM, model, native GPU or network."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import time


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    here = Path(__file__).resolve().parent
    output = args.output.resolve()
    output.mkdir(mode=0o700, parents=False, exist_ok=False)
    listing = json.loads((here / "fixture-source-list.json").read_text())
    sources = {}
    for group, records in listing["groups"].items():
        paths = []
        for record in records:
            path = Path(record["path"])
            if not path.is_absolute():
                path = here / path
            if digest(path) != record["sha256"]:
                raise ValueError("Fixture source pin changed: " + str(path))
            paths.append(str(path))
        sources[group] = paths
    results = []

    def run(name, command):
        began = time.monotonic()
        with (output / (name + ".stdout")).open("xb") as stdout, (output / (name + ".stderr")).open("xb") as stderr:
            result = subprocess.run(command, cwd=output, stdout=stdout, stderr=stderr, timeout=60)
        row = {"name": name, "exitCode": result.returncode, "seconds": time.monotonic() - began,
               "stdoutSHA256": digest(output / (name + ".stdout")), "stderrSHA256": digest(output / (name + ".stderr"))}
        results.append(row)
        (output / "checks.json").write_text(json.dumps({"checks": results, "fixtureOnly": True,
            "providerAndCLITestsExecuted": False, "nativeOrNetworkExecuted": False}, indent=2) + "\n")
        if result.returncode or (output / (name + ".stderr")).stat().st_size:
            raise RuntimeError("Check failed: " + name)

    base = ["swiftc", "-swift-version", "6", "-warnings-as-errors"]
    run("protocol-compile", base + ["-emit-library", "-emit-module", "-module-name", "DarkbloomClusterProtocol"]
        + sources["protocol"] + ["-emit-module-path", str(output / "DarkbloomClusterProtocol.swiftmodule"),
        "-o", str(output / "libDarkbloomClusterProtocol.dylib"), "-Xlinker", "-install_name", "-Xlinker", "@rpath/libDarkbloomClusterProtocol.dylib"])
    run("files-compile", base + sources["files"] + ["-o", str(output / "files-check")])
    run("files-test", [str(output / "files-check")])
    run("configuration-compile", base + ["-I", str(output), "-L", str(output), "-lDarkbloomClusterProtocol",
        "-Xlinker", "-rpath", "-Xlinker", str(output)] + sources["configuration"] + ["-o", str(output / "configuration-check")])
    run("configuration-test", [str(output / "configuration-check")])
    run("integration-syntax", ["swiftc", "-frontend", "-parse"] + sources["integrationSyntax"])
    print("PASS: 9 actual-file groups; 10 schema/store groups; integration syntax only")


if __name__ == "__main__":
    main()
