#!/usr/bin/env python3
"""Check out a CI checkout's submodules at their recorded commits, fetching them in parallel.

actions/checkout's `submodules: recursive` runs `git submodule sync --recursive`
and `git submodule update --init --force --depth=1 --recursive`. For each
submodule, one after another, git clones the default branch at depth 1 and
then, unless that tip is the recorded commit, fetches the recorded commit.
Each of these round trips took about 4 s on Darkbloom, so the five submodules
took 36 s of the provider build's checkout (run 44873769645).

This script first fetches the recorded commit of each submodule that has no
git directory yet, at depth 1 and all at once. Inside a submodule it does the
same as soon as that submodule is checked out. `git submodule absorbgitdirs`
then moves the new git directories to `.git/modules`, where git's own clone
puts them. The same sync and update as actions/checkout's follow; they find
every fetched submodule at its commit and only check it out. They also handle
a submodule whose git directory already exists (a restored `.git`) or whose
URL is relative, which this script does not fetch. A failed fetch fails the
script. Every git command rewrites `git@github.com:` URLs to HTTPS, as
actions/checkout does for submodules.

Run in the checkout: python3 scripts/ci-checkout-submodules.py
"""

from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import subprocess
import sys
import time


GIT = ("git", "-c", "protocol.version=2", "-c", "url.https://github.com/.insteadOf=git@github.com:")


def git(directory, *arguments):
    """Run git in directory; return its output, raise with its error output when it fails."""
    result = subprocess.run([*GIT, "-C", str(directory), *arguments], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f"git {' '.join(arguments)} in {directory} failed: {result.stderr.strip()}")
    return result.stdout


def submodules(directory):
    """(name, path, recorded commit, URL) of each gitlink in the index of the repository at directory."""
    records = [record for record in git(directory, "ls-files", "--stage", "-z").split("\0")
               if record.startswith("160000 ")]
    if not records:
        return []
    names = {}
    for line in git(directory, "config", "--file", ".gitmodules", "--get-regexp", r"^submodule\..*\.path$").splitlines():
        key, path = line.split(" ", 1)
        names[path] = key[len("submodule."):-len(".path")]
    found = []
    for record in records:
        metadata, path = record.split("\t", 1)
        if path not in names:
            raise RuntimeError(f"{directory / path} is a gitlink that .gitmodules does not name")
        name = names[path]
        url = git(directory, "config", "--file", ".gitmodules", f"submodule.{name}.url").strip()
        found.append((name, path, metadata.split()[1], url))
    return found


def fetch(directory, url, commit):
    """Fetch one commit at depth 1 into a new repository at directory and check it out.

    The remote has no fetch refspec. When a later run restores this .git and a
    pin has moved, the update's first `git fetch --depth=1` then takes only the
    remote's HEAD, as in the single-branch repository git's own clone makes,
    instead of every branch.
    """
    directory.mkdir(exist_ok=True)
    git(directory, "init", "-q")
    git(directory, "config", "remote.origin.url", url)
    git(directory, "fetch", "-q", "--depth=1", "--no-tags", "origin", commit)
    git(directory, "checkout", "-q", "--detach", commit)


def prefetch(directory):
    """Fetch every submodule of the repository at directory that has no git directory, recursively, in parallel.

    Returns the paths fetched, relative to directory.
    """
    git_dir = Path(git(directory, "rev-parse", "--absolute-git-dir").strip())
    missing = [(path, url, commit) for name, path, commit, url in submodules(directory)
               if not (directory / path / ".git").exists() and not (git_dir / "modules" / name).exists()
               and not url.startswith(("./", "../"))]

    def fetch_tree(path, url, commit):
        fetch(directory / path, url, commit)
        return [path] + [f"{path}/{inner}" for inner in prefetch(directory / path)]

    with ThreadPoolExecutor(max_workers=max(1, len(missing))) as pool:
        futures = [pool.submit(fetch_tree, *submodule) for submodule in missing]
        return [path for future in futures for path in future.result()]


def main():
    root = Path.cwd()
    started = time.monotonic()
    try:
        fetched = prefetch(root)
        if fetched:
            git(root, "submodule", "absorbgitdirs")
    except RuntimeError as error:
        print(f"::error title=Submodules::{error}")
        return 1
    print(f"Fetched {len(fetched)} submodules at their recorded commits in {time.monotonic() - started:.1f} s: "
          f"{', '.join(fetched) or 'none'}", flush=True)
    updated = time.monotonic()
    for arguments in (("submodule", "sync", "--recursive"),
                      ("submodule", "update", "--init", "--force", "--depth=1", "--recursive"),
                      ("submodule", "foreach", "--recursive", "git config --local gc.auto 0")):
        if subprocess.run([*GIT, *arguments]).returncode:
            return 1
    print(f"Synced, updated and checked the submodules in {time.monotonic() - updated:.1f} s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
