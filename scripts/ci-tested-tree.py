#!/usr/bin/env python3
"""Find a successful CI run of this workflow that already tested a source tree.

CI tests each change once. A run that passes records the tree it tested as an
artifact named `ci-tested-tree-<tree>` (the Provider Tests gate uploads it).
Before testing, every run looks for that artifact: when a completed,
successful run of the same workflow file, from this repository, recorded the
same tree, the run skips its tests and cites that run. The common case is a
push of a merge commit whose tree equals the pull request's test merge tree.

Any doubt runs the tests: a missing, expired or foreign artifact, a run of
another workflow or repository, an unfinished or failed run, or an API error.

Usage: ci-tested-tree.py lookup --repository OWNER/REPO --workflow-ref REF
       --tree TREE --run-id ID [--output GITHUB_OUTPUT]
REF is github.workflow_ref (`OWNER/REPO/.github/workflows/<file>@<ref>`).
Reads GITHUB_TOKEN (actions: read) from the environment.
"""

import argparse
import json
import os
import re
import sys
import urllib.request

API = "https://api.github.com"
ARTIFACT_PREFIX = "ci-tested-tree-"


def github_get(path):
    request = urllib.request.Request(API + path, headers={
        "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28",
        "Authorization": f"Bearer {os.environ['GITHUB_TOKEN']}", "User-Agent": "ci-tested-tree/1"})
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.load(response)


def workflow_path(workflow_ref, repository):
    """`.github/workflows/<file>` from github.workflow_ref, or ValueError."""
    match = re.fullmatch(re.escape(repository) + r"/(\.github/workflows/[A-Za-z0-9._-]+\.ya?ml)@.+", workflow_ref)
    if not match:
        raise ValueError(f"Unexpected workflow ref: {workflow_ref!r}")
    return match.group(1)


def tested_run(repository, path, tree, run_id, get=github_get):
    """The URL of a successful run of `path` that recorded `tree`, or None."""
    if not re.fullmatch(r"[0-9a-f]{40}", tree):
        raise ValueError(f"Expected a full tree SHA, got {tree!r}")
    listing = get(f"/repos/{repository}/actions/artifacts?name={ARTIFACT_PREFIX}{tree}&per_page=100")
    for artifact in listing.get("artifacts", []):
        source = artifact.get("workflow_run") or {}
        if artifact.get("name") != ARTIFACT_PREFIX + tree or artifact.get("expired"):
            continue
        if not isinstance(source.get("id"), int) or source["id"] == run_id:
            continue
        run = get(f"/repos/{repository}/actions/runs/{source['id']}")
        if (run.get("status") == "completed" and run.get("conclusion") == "success"
                and run.get("path") == path
                and (run.get("repository") or {}).get("full_name") == repository
                and (run.get("head_repository") or {}).get("full_name") == repository):
            return run.get("html_url") or f"https://github.com/{repository}/actions/runs/{source['id']}"
    return None


def decide(repository, workflow_ref, tree, run_id, get=github_get):
    """Return (skip, run_url, note). Every failure runs the tests."""
    try:
        url = tested_run(repository, workflow_path(workflow_ref, repository), tree, run_id, get)
    except Exception as error:  # noqa: BLE001 - any doubt means test
        return False, "", f"Tree lookup failed ({type(error).__name__}: {error}); testing."
    if url:
        return True, url, f"Tree {tree} already passed in {url}; this run skips its tests."
    return False, "", f"No successful run of this workflow tested tree {tree}; testing."


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    lookup = commands.add_parser("lookup")
    lookup.add_argument("--repository", required=True)
    lookup.add_argument("--workflow-ref", required=True)
    lookup.add_argument("--tree", required=True)
    lookup.add_argument("--run-id", type=int, required=True)
    lookup.add_argument("--output", default=os.environ.get("GITHUB_OUTPUT"))
    args = parser.parse_args()
    skip, url, note = decide(args.repository, args.workflow_ref, args.tree, args.run_id)
    print(note)
    lines = f"skip={str(skip).lower()}\ntested_run={url}\n"
    if args.output:
        with open(args.output, "a") as output:
            output.write(lines)
    else:
        sys.stdout.write(lines)
    return 0


if __name__ == "__main__":
    sys.exit(main())
