#!/usr/bin/env python3
"""Find a successful CI run of this workflow that already tested the same change.

CI tests each change once. A passing run's gate uploads an empty record, an
artifact named

    ci-tested-<tree>-<base>-<head>-p<0|1>c<0|1>m<0|1>

<tree> is the tree the run tested. A pull request run names the base and head
commits GitHub merged for its test (`github.event.pull_request.base.sha`,
`.head.sha`); a push run names `push` and its commit. The p, c and m flags
say which components ran: provider, cluster, MiMo audio.

Before testing, a run looks for a record that binds to its own change and
covers every component it would run:

- a pull request: `<tree>-<base>-<head>` of its own event;
- a push of commit S: `<tree(S)>-<first parent>-<second parent>` (the pull
  request whose head S merges, tested against S's first parent), and
  `<tree(S)>-push-<S>` (an earlier run of this push).

A dispatched run (the hourly full run of dev) never skips: it reads no
record.

It accepts a record only from a completed, successful run of the same
workflow file in this repository (not a fork), of the matching event, whose
head commit is the record's head. Any doubt runs the tests: no record, an
expired or foreign one, a failed or unfinished run, or an API error.

A same-repository pull request runs its own workflow file, so a record is as
trustworthy as the reviewed workflow at that head; the binding keeps a
record of one change from standing in for another.

Usage: ci-tested-tree.py lookup --repository OWNER/REPO --workflow-ref REF
       --event NAME --sha SHA --tree TREE [--base SHA --head SHA]
       --components provider=B,cluster=B,mimo_audio=B --run-id ID
       [--output GITHUB_OUTPUT]
       ci-tested-tree.py name --tree TREE --base SHA|push --head SHA
       --components ...
Reads GITHUB_TOKEN (actions: read, contents: read) from the environment.
"""

import argparse
import itertools
import json
import os
import re
import sys
import urllib.request

API = "https://api.github.com"
COMPONENTS = ("provider", "cluster", "mimo_audio")
FLAGS = dict(zip(COMPONENTS, "pcm"))
SHA = re.compile(r"[0-9a-f]{40}")


def github_get(path):
    request = urllib.request.Request(API + path, headers={
        "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28",
        "Authorization": f"Bearer {os.environ['GITHUB_TOKEN']}", "User-Agent": "ci-tested-tree/2"})
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.load(response)


def sha(value, what):
    if not isinstance(value, str) or not SHA.fullmatch(value):
        raise ValueError(f"Expected a full {what} SHA, got {value!r}")
    return value


def components(text):
    """`provider=true,cluster=false,mimo_audio=false` -> {name: bool}, every name once."""
    pairs = dict(item.split("=", 1) for item in text.split(",") if item)
    if set(pairs) != set(COMPONENTS) or not set(pairs.values()) <= {"true", "false"}:
        raise ValueError(f"Expected each of {COMPONENTS} as true or false, got {text!r}")
    return {name: pairs[name] == "true" for name in COMPONENTS}


def flags(selected):
    return "".join(f"{FLAGS[name]}{int(selected[name])}" for name in COMPONENTS)


def record_name(tree, base, head, selected):
    return f"ci-tested-{sha(tree, 'tree')}-{base if base == 'push' else sha(base, 'base')}-{sha(head, 'head')}-{flags(selected)}"


def supersets(selected):
    """Every component set that covers `selected`, `selected` itself first."""
    choices = [[True] if selected[name] else [False, True] for name in COMPONENTS]
    return [dict(zip(COMPONENTS, values)) for values in itertools.product(*choices)]


def workflow_path(workflow_ref, repository):
    """`.github/workflows/<file>` from github.workflow_ref, or ValueError."""
    match = re.fullmatch(re.escape(repository) + r"/(\.github/workflows/[A-Za-z0-9._-]+\.ya?ml)@.+", workflow_ref)
    if not match:
        raise ValueError(f"Unexpected workflow ref: {workflow_ref!r}")
    return match.group(1)


def candidates(repository, event, commit, tree, base, head, get):
    """[(base, head, event of the recording run)] that may stand in for this run."""
    if event == "pull_request":
        return [(sha(base, "base"), sha(head, "head"), "pull_request")]
    if event != "push":
        raise ValueError(f"Unsupported event: {event!r}")
    found = get(f"/repos/{repository}/git/commits/{commit}")
    if found.get("tree", {}).get("sha") != tree:
        raise ValueError("The pushed commit's tree is not the tree under test")
    parents = [parent.get("sha") for parent in found.get("parents", [])]
    result = [("push", commit, "push")]
    if len(parents) == 2 and all(isinstance(parent, str) and SHA.fullmatch(parent) for parent in parents):
        result.insert(0, (parents[0], parents[1], "pull_request"))
    return result


def tested_run(repository, path, event, commit, tree, base, head, selected, run_id, get=github_get):
    """The URL of a successful run that recorded this change with a superset, or None."""
    sha(tree, "tree")
    sha(commit, "commit")
    for record_base, record_head, record_event in candidates(repository, event, commit, tree, base, head, get):
        for covering in supersets(selected):
            name = record_name(tree, record_base, record_head, covering)
            listing = get(f"/repos/{repository}/actions/artifacts?name={name}&per_page=100")
            for artifact in listing.get("artifacts", []):
                source = artifact.get("workflow_run") or {}
                if artifact.get("name") != name or artifact.get("expired"):
                    continue
                if not isinstance(source.get("id"), int) or source["id"] == run_id:
                    continue
                run = get(f"/repos/{repository}/actions/runs/{source['id']}")
                if (run.get("status") == "completed" and run.get("conclusion") == "success"
                        and run.get("path") == path and run.get("event") == record_event
                        and run.get("head_sha") == record_head
                        and (run.get("repository") or {}).get("full_name") == repository
                        and (run.get("head_repository") or {}).get("full_name") == repository):
                    return run.get("html_url") or f"https://github.com/{repository}/actions/runs/{source['id']}"
    return None


def decide(repository, workflow_ref, event, commit, tree, base, head, selected, run_id, get=github_get):
    """Return (skip, run_url, note). Every failure runs the tests."""
    if not any(selected.values()):
        return False, "", "No component is selected; there is nothing to test or skip."
    if event == "workflow_dispatch":
        return False, "", "A dispatched run (the hourly full run) tests every component and never skips."
    try:
        url = tested_run(repository, workflow_path(workflow_ref, repository), event, commit, tree,
                         base, head, selected, run_id, get)
    except Exception as error:  # noqa: BLE001 - any doubt means test
        return False, "", f"Tree lookup failed ({type(error).__name__}: {error}); testing."
    if url:
        return True, url, f"This change ({tree}, {flags(selected)}) already passed in {url}; this run skips its tests."
    return False, "", f"No successful run of this workflow tested this change ({tree}, {flags(selected)}); testing."


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    lookup = commands.add_parser("lookup")
    for option in ("--repository", "--workflow-ref", "--event", "--sha", "--tree", "--components"):
        lookup.add_argument(option, required=True)
    lookup.add_argument("--base", default="")
    lookup.add_argument("--head", default="")
    lookup.add_argument("--run-id", type=int, required=True)
    lookup.add_argument("--output", default=os.environ.get("GITHUB_OUTPUT"))
    name = commands.add_parser("name")
    for option in ("--tree", "--base", "--head", "--components"):
        name.add_argument(option, required=True)
    args = parser.parse_args()
    if args.command == "name":
        print(record_name(args.tree, args.base, args.head, components(args.components)))
        return 0
    try:
        selected = components(args.components)
    except ValueError as error:
        print(f"Tree lookup failed ({error}); testing.")
        selected = None
    if selected is None:
        skip, url = False, ""
    else:
        skip, url, note = decide(args.repository, args.workflow_ref, args.event, args.sha, args.tree,
                                 args.base, args.head, selected, args.run_id)
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
