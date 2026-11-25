#!/usr/bin/env python3
"""Hand one lane's debug test products from its build job to the test jobs.

CI builds each lane once, on a large runner, and its test jobs run the
products with `swift test --skip-build`. SwiftPM's products hold absolute
paths (`#filePath`, resource bundle paths, the package graph in
`workspace-state.json`), so every job that builds or reads them works at one
fixed path, FIXED_ROOT; Blacksmith and Darkbloom runners check out to
different paths (.github/workflows/provider-tests.yml).

The archive holds the lane's `.build` directory without what no test step
reads: each target's `<Target>.build` directory (object files and dependency
records), `ModuleCache`, `index` and `Modules`; the host tools (macros and
plugins, which SwiftPM builds with a `-tool` suffix, and their `Modules-tool`;
only the compiler runs them); the `.dSYM` bundles (the coverage report reads
the coverage maps in the binaries, not DWARF); and `repositories`, SwiftPM's
bare clones, which it reads only to check out a dependency whose checkout is
missing or at another revision. It keeps the test bundles, the executables,
the resource bundles, the staged matched `mlx.metallib`, the build database,
and the checkouts and `workspace-state.json`, which load the package graph
without a fetch. The test bundle's copies of `mlx.metallib` cost nearly nothing: zstd's
long-distance mode (LONG_WINDOW) stores each repeat as a reference. A
manifest records the commit and the toolchain; a test job refuses products of
another commit or of another Swift, Xcode or SDK version, and warns when only
the builds of that version differ (the runner images of Blacksmith and
Darkbloom can carry different builds of one Xcode version).

The test jobs do not need their build job: they start beside it, so their
runner, checkout and toolchain are ready when the products are, and `wait`
holds the download until the build job has ended. Its products are those of
the run's latest execution of the build job: a re-run of failed test jobs
reads the earlier attempt's products, a re-run of all jobs its own build's.

Subcommands:
  pack LANE ARCHIVE      archive the lane's products; note the upload start
  uploaded ARCHIVE       print the upload time since `pack`
  wait LANE              wait until the lane's build job of this run ended;
                         fail unless it succeeded
  stamp                  note the download start
  unpack LANE ARCHIVE    check and extract the products; print the download
                         and extraction times
"""

import argparse
import http.client
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request


FIXED_ROOT = Path("/private/tmp/dinf")
LANES = {"provider": "provider-swift", "cluster": "libs/darkbloom-cluster"}
# Directories inside .build/<triple>/<configuration>/ that only the compiler
# reads. `unread` drops `Modules-tool` with the host tools, by their `-tool`
# suffix.
INTERMEDIATES = ("ModuleCache", "index", "Modules")
# zstd's long-distance mode with a 2 GiB window: content repeated far apart
# (the metallib copies, the code that the test bundle and the executables
# share) is stored once. Unpacking needs the same window and about 2 GiB of
# memory. On the provider products of run 42318853015, level 9 with it packs
# 265 MiB, against 400 MiB at level 3 without it, for about 7 s more on 10
# cores; a 1 GiB window packs 282 MiB.
LONG_WINDOW = "--long=31"
COMPRESSION = ("-9", LONG_WINDOW)
MANIFEST = "ci-test-products.json"
STAMP = "CI_TEST_PRODUCTS_STARTED"
# The build job of each lane, by its name in provider-tests.yml. The API names
# a called workflow's job after its caller's job too ("Tests / Build ...").
BUILD_JOBS = {"provider": "Build provider test products", "cluster": "Build cluster test products"}
# A cold provider build took up to 9 minutes on Darkbloom. The wait counts
# against the test job's own 60-minute timeout (provider-tests.yml), so the
# limit ends it with a message first. Each poll is one request of the
# repository's token budget.
WAIT_POLL_SECONDS = 15
WAIT_LIMIT_SECONDS = 50 * 60
# How long GitHub asks a rate-limited client to wait when its answer names no time.
RATE_LIMIT_PAUSE_SECONDS = 60
# GitHub lists the jobs of a called workflow when it starts, before any of
# them runs; a build job still missing after this long will not appear.
WAIT_MISSING_SECONDS = 120


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


def unread(relative):
    """Whether no test step reads .build/<relative> (see the module docstring).

    A test bundle holds its own `.dSYM` (`<Bundle>.xctest/Contents/MacOS/`),
    so a `.dSYM` is unread at any depth of the build tree.
    """
    parts = relative.parts
    if parts == ("repositories",):
        return True
    if len(parts) < 3 or "-apple-" not in parts[0]:
        return False
    name = parts[-1]
    if name.endswith(".dSYM"):
        return True
    return len(parts) == 3 and (name in INTERMEDIATES or name.endswith(".build")
                                or name.removesuffix(".product").endswith("-tool"))


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
            if not unread(path.relative_to(build)):
                paths.append(path.relative_to(directory))
                # os.walk does not descend into links; a linked directory is one entry.
                if not path.is_symlink():
                    kept.append(name)
        directories[:] = kept
        paths.extend((base / name).relative_to(directory) for name in sorted(files)
                     if not unread((base / name).relative_to(build)))
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
    # Regular files only: a link or a directory adds its entry, not its target.
    files = sum(entry.st_size for entry in (os.lstat(directory / path) for path in paths)
                if stat.S_ISREG(entry.st_mode))
    manifest = {"lane": lane, "commit": commit(root), "toolchain": toolchain(), "entries": len(paths)}
    (directory / ".build" / MANIFEST).write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    paths.append(Path(".build") / MANIFEST)
    archive.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("wb", suffix=".list") as listing:
        listing.write(b"".join(os.fsencode(path) + b"\0" for path in paths))
        listing.flush()
        stream(["tar", "--null", "--no-recursion", "-T", listing.name, "-cf", "-"], directory,
               ["zstd", "-T0", *COMPRESSION, "-q", "-f", "-o", str(archive)])
    start_clock()
    print(f"{lane} test products: {len(paths)} entries, {files / 2**20:.1f} MiB of files, "
          f"{mebibytes(archive)} compressed, packed in {time.monotonic() - started:.1f} s")


def uploaded(archive):
    print(f"{archive.name}: {mebibytes(archive)} uploaded in {elapsed()}")


def run_jobs():
    """The latest execution of each job of this workflow run (one page: a run has fewer than 100)."""
    api = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
    try:
        repository, run = os.environ["GITHUB_REPOSITORY"], os.environ["GITHUB_RUN_ID"]
        token = os.environ["GITHUB_TOKEN"]
    except KeyError as missing:
        raise ProductsError(f"{missing.args[0]} is not set; wait runs only in a workflow job")
    request = urllib.request.Request(
        f"{api}/repos/{repository}/actions/runs/{run}/jobs?filter=latest&per_page=100",
        headers={"Accept": "application/vnd.github+json", "Authorization": f"Bearer {token}",
                 "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "ci-test-products"})
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.load(response).get("jobs", [])


def build_job(jobs, lane):
    name = BUILD_JOBS[lane]
    matches = [job for job in jobs if job.get("name") == name or str(job.get("name")).endswith(f" / {name}")]
    if len(matches) > 1:
        raise ProductsError(f"{len(matches)} jobs of this run are named {name!r}")
    return matches[0] if matches else None


def retry_pause(failure, poll):
    """Seconds to wait before retrying a failed request; raise when no retry can pass.

    GitHub refuses a request over a rate limit with 429, or with 403 and
    Retry-After, no request left or a message naming the limit. It asks the
    client to wait Retry-After seconds, or until X-RateLimit-Reset when no
    request is left, or else a minute. Any other 401, 403 or 404 means that
    the token cannot read the run's jobs: the job lacks `actions: read`.
    """
    if not isinstance(failure, urllib.error.HTTPError) or failure.code not in (401, 403, 404, 429):
        return poll
    headers = failure.headers
    retry_after = headers.get("Retry-After")
    exhausted = headers.get("X-RateLimit-Remaining") == "0"
    if not (failure.code == 429
            or (failure.code == 403 and (retry_after or exhausted or names_rate_limit(failure)))):
        raise ProductsError(f"The run's jobs cannot be read ({failure}); "
                            "the job needs the token permission actions: read")
    try:
        if retry_after:
            return max(poll, float(retry_after))
        if exhausted:
            return max(poll, float(headers.get("X-RateLimit-Reset")) - time.time())
    except (TypeError, ValueError):
        pass
    return max(poll, RATE_LIMIT_PAUSE_SECONDS)


def names_rate_limit(failure):
    """Whether an error answer's body names a rate limit; a secondary limit may send no header."""
    try:
        return b"rate limit" in failure.read().lower()
    except (OSError, http.client.HTTPException):
        return False


def wait(lane, poll=WAIT_POLL_SECONDS, limit=WAIT_LIMIT_SECONDS, missing=WAIT_MISSING_SECONDS,
         clock=time.monotonic, sleep=time.sleep):
    """Return once the lane's build job ended successfully; raise when it ended otherwise.

    A failed request is retried until the limit (the products may still
    come), a rate-limited one after the pause GitHub asks for, unless the
    token is refused.
    """
    started = clock()
    last = None
    while True:
        waited = clock() - started
        try:
            job, error, pause = build_job(run_jobs(), lane), None, poll
        # urllib's HTTPError and URLError are OSErrors; a response cut short
        # raises one of http.client's own errors.
        except (OSError, http.client.HTTPException, ValueError) as failure:
            job, error, pause = None, failure, retry_pause(failure, poll)
        if job and job.get("status") == "completed":
            if job.get("conclusion") != "success":
                raise ProductsError(f"{job.get('name')} ended {job.get('conclusion')} after this job had waited "
                                    f"{waited:.0f} s; there are no {lane} products to test")
            print(f"{job.get('name')} succeeded; waited {waited:.0f} s for the {lane} products")
            return
        state = f"request failed: {error}" if error else (job.get("status") if job else "not listed")
        if state != last:
            print(f"{BUILD_JOBS[lane]} at {waited:.0f} s: {state}", flush=True)
            last = state
        if not job and not error and waited >= missing:
            raise ProductsError(f"This run lists no {BUILD_JOBS[lane]!r} job after {waited:.0f} s")
        if waited >= limit:
            raise ProductsError(f"{BUILD_JOBS[lane]} had not ended after {waited:.0f} s ({state})")
        sleep(min(pause, limit - waited))


def unpack(root, lane, archive):
    directory = package(root, lane)
    if not archive.is_file():
        raise ProductsError(f"{archive} is missing; the download did not complete")
    print(f"{lane} test products: {mebibytes(archive)} downloaded in {elapsed()}")
    started = time.monotonic()
    build = directory / ".build"
    if build.exists():
        raise ProductsError(f"{build} already exists; the test job must not build")
    stream(["zstd", "-dc", LONG_WINDOW, "-q", str(archive)], directory, ["tar", "-xpf", "-"])
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
    commands.add_parser("wait").add_argument("lane", choices=sorted(BUILD_JOBS))
    commands.add_parser("stamp")
    args = parser.parse_args(argv)
    try:
        if args.command == "pack":
            pack(args.root, args.lane, args.archive)
        elif args.command == "unpack":
            unpack(args.root, args.lane, args.archive)
        elif args.command == "uploaded":
            uploaded(args.archive)
        elif args.command == "wait":
            wait(args.lane)
        else:
            start_clock()
    except (ProductsError, OSError, ValueError) as error:
        print(f"::error title=Test products::{error}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
