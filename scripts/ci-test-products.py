#!/usr/bin/env python3
"""Hand one lane's debug test products from its build job to the test jobs.

CI builds each lane once, on a large runner, and its test jobs run the
products with `swift test --skip-build`. SwiftPM's products hold absolute
paths (`#filePath`, resource bundle paths, the package graph in
`workspace-state.json`), so every job that builds or reads them works at one
fixed path, FIXED_ROOT; Blacksmith and Darkbloom runners check out to
different paths (.github/workflows/provider-tests.yml).

The archive holds the lane's `.build` directory without the compile
intermediates that no test step reads: each target's `<Target>.build`
directory (object files and dependency records), `ModuleCache`, `index` and
`Modules`. It keeps the test bundles, the executables, the resource bundles,
the staged matched `mlx.metallib`, and the checkouts, repositories and
`workspace-state.json` that load the package graph without a fetch. A
manifest records the commit and the toolchain; a test job refuses products of
another commit or of another Swift, Xcode or SDK version, and warns when only
the builds of that version differ (the runner images of Blacksmith and
Darkbloom can carry different builds of one Xcode version).

Subcommands:
  pack LANE ARCHIVE      archive the lane's products; note the upload start
  uploaded ARCHIVE       print the upload time since `pack`
  stamp                  note the download start
  unpack LANE ARCHIVE    check and extract the products; print the download
                         and extraction times
"""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time


FIXED_ROOT = Path("/private/tmp/dinf")
LANES = {"provider": "provider-swift", "cluster": "libs/darkbloom-cluster"}
# Directories inside .build/<triple>/<configuration>/ that only the compiler reads.
INTERMEDIATES = ("ModuleCache", "index", "Modules")
MANIFEST = "ci-test-products.json"
STAMP = "CI_TEST_PRODUCTS_STARTED"


class ProductsError(Exception):
    pass


def command(*argv, cwd=None):
    result = subprocess.run(argv, cwd=cwd, capture_output=True, text=True)
    if result.returncode:
        raise ProductsError(f"{' '.join(argv)} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def toolchain():
    """The versions and the builds of the Swift compiler, Xcode and the SDK.

    Only the compiler line of `swift --version` counts: its `Target:` line
    names the host's macOS version, which does not change the products.
    """
    swift = command("swift", "--version").partition("\n")[0]
    version = re.search(r"Swift version (\S+)", swift)
    xcode = command("xcodebuild", "-version").splitlines() or [""]
    return {
        "versions": {"swift": version.group(1) if version else swift, "xcode": xcode[0],
                     "sdk": command("xcrun", "--sdk", "macosx", "--show-sdk-version")},
        "builds": {"swift": swift, "xcode": " ".join(xcode[1:]),
                   "sdk": command("xcrun", "--sdk", "macosx", "--show-sdk-build-version")},
    }


def package(root, lane):
    """The lane's package directory, which must resolve inside the fixed path."""
    if lane not in LANES:
        raise ProductsError(f"Unknown lane {lane!r}; expected one of {sorted(LANES)}")
    directory = (root / LANES[lane]).resolve()
    if not directory.is_relative_to(FIXED_ROOT):
        raise ProductsError(f"{directory} is not under {FIXED_ROOT}; the products hold absolute paths "
                            "and run only at the fixed build path")
    return directory


def intermediate(relative):
    """Whether .build/<relative> is a compile intermediate directory."""
    parts = relative.parts
    return (len(parts) == 3 and "-apple-" in parts[0]
            and (parts[2].endswith(".build") or parts[2] in INTERMEDIATES))


def product_paths(directory):
    """Every path under directory/.build to archive, relative to directory, in order."""
    build = directory / ".build"
    if not build.is_dir():
        raise ProductsError(f"{build} does not exist; the lane did not build")
    paths = [Path(".build")]
    for current, directories, files in os.walk(build):
        base = Path(current)
        kept = []
        for name in sorted(directories):
            path = base / name
            if not intermediate(path.relative_to(build)):
                paths.append(path.relative_to(directory))
                # os.walk does not descend into links; a linked directory is one entry.
                if not path.is_symlink():
                    kept.append(name)
        directories[:] = kept
        paths.extend((base / name).relative_to(directory) for name in sorted(files))
    return paths


def commit(root):
    return command("git", "rev-parse", "HEAD", cwd=root)


def mebibytes(path):
    return f"{path.stat().st_size / 2**20:.1f} MiB"


def start_clock():
    """Note the start of an upload or a download for the later steps of the job."""
    environment = os.environ.get("GITHUB_ENV")
    if environment:
        with open(environment, "a") as handle:
            handle.write(f"{STAMP}={time.time():.3f}\n")


def elapsed():
    """The time since `start_clock` in an earlier step of the job."""
    started = os.environ.get(STAMP)
    try:
        return f"{time.time() - float(started):.1f} s"
    except (TypeError, ValueError):
        return "unknown (no start time)"


def stream(producer, cwd, consumer):
    """Run producer | consumer; fail if either fails."""
    first = subprocess.Popen(producer, cwd=cwd, stdout=subprocess.PIPE)
    second = subprocess.run(consumer, cwd=cwd, stdin=first.stdout)
    first.stdout.close()
    if first.wait() or second.returncode:
        raise ProductsError(f"{' '.join(producer)} | {' '.join(consumer)} failed "
                            f"(exit {first.returncode} and {second.returncode})")


def pack(root, lane, archive):
    directory = package(root, lane)
    started = time.monotonic()
    paths = product_paths(directory)
    manifest = {"lane": lane, "commit": commit(root), "toolchain": toolchain(), "entries": len(paths)}
    (directory / ".build" / MANIFEST).write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    paths.append(Path(".build") / MANIFEST)
    archive.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("wb", suffix=".list") as listing:
        listing.write(b"".join(os.fsencode(path) + b"\0" for path in paths))
        listing.flush()
        stream(["tar", "--null", "--no-recursion", "-T", listing.name, "-cf", "-"], directory,
               ["zstd", "-T0", "-3", "-q", "-f", "-o", str(archive)])
    start_clock()
    print(f"{lane} test products: {len(paths)} entries, {mebibytes(archive)} compressed, "
          f"packed in {time.monotonic() - started:.1f} s")


def uploaded(archive):
    print(f"{archive.name}: {mebibytes(archive)} uploaded in {elapsed()}")


def unpack(root, lane, archive):
    directory = package(root, lane)
    if not archive.is_file():
        raise ProductsError(f"{archive} is missing; the download did not complete")
    print(f"{lane} test products: {mebibytes(archive)} downloaded in {elapsed()}")
    started = time.monotonic()
    build = directory / ".build"
    if build.exists():
        raise ProductsError(f"{build} already exists; the test job must not build")
    stream(["zstd", "-dc", "-q", str(archive)], directory, ["tar", "-xpf", "-"])
    manifest = json.loads((build / MANIFEST).read_text())
    current = toolchain()
    built = manifest.get("toolchain") or {}
    expected = {"lane": lane, "commit": commit(root), "toolchain versions": current["versions"]}
    found = {"lane": manifest.get("lane"), "commit": manifest.get("commit"),
             "toolchain versions": built.get("versions")}
    for key, value in expected.items():
        if found[key] != value:
            raise ProductsError(f"The {lane} products were built with {key} {found[key]!r}; "
                                f"this job has {value!r}. Build and test runners must use one toolchain.")
    if built.get("builds") != current["builds"]:
        print(f"::warning title=Test products::The {lane} products were built with toolchain builds "
              f"{built.get('builds')!r}; this job has {current['builds']!r}. The versions are equal.")
    print(f"{lane} test products: {manifest.get('entries')} entries extracted in {time.monotonic() - started:.1f} s")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=Path.cwd())
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("pack", "unpack"):
        subcommand = commands.add_parser(name)
        subcommand.add_argument("lane")
        subcommand.add_argument("archive", type=Path)
    commands.add_parser("uploaded").add_argument("archive", type=Path)
    commands.add_parser("stamp")
    args = parser.parse_args(argv)
    try:
        if args.command == "pack":
            pack(args.root, args.lane, args.archive)
        elif args.command == "unpack":
            unpack(args.root, args.lane, args.archive)
        elif args.command == "uploaded":
            uploaded(args.archive)
        else:
            start_clock()
    except (ProductsError, OSError, ValueError) as error:
        print(f"::error title=Test products::{error}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
