#!/usr/bin/env python3
"""Repair a linear PR stack after a squash without rewriting branch history.

Default: verify only. Requires git, authenticated gh, and (for --push) working
commit signing and signature verification. Run in the clone with origin pointing
to the PR repository. Fork PRs are not supported. Never merges PRs or checks out
branches. Objects are fetched into temporary storage, not local refs/worktrees.

Keep stack branches and PR metadata unchanged during operation. Nonforce pushes
reject concurrent forward/divergent updates not contained in the proposed tip,
but cannot atomically guard deletion/rewind between tip read and push. GitHub
has no atomic base compare-and-swap: --retarget's fresh checks are best-effort.
"""

import argparse
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile


def run(*args, env=None):
    result = subprocess.run(args, env=env, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(f"{shlex.join(args)} failed:\n{result.stderr.strip()}")
    return result.stdout.strip()


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("prs", nargs="+", type=int, metavar="PR", help="merged parent, open child, then descendants in order")
    parser.add_argument("--repo", help="OWNER/REPO; otherwise discover via gh")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="verify only (default)")
    mode.add_argument("--push", action="store_true", help="create signed commits and atomically push nonforce")
    parser.add_argument("--retarget", action="store_true", help="with --push, retarget only the direct child after fresh checks")
    parser.add_argument("--skip-hook", action="store_true", help="explicitly disable push hooks for this invocation only")
    args = parser.parse_args(argv)
    require(len(args.prs) >= 2 and len(set(args.prs)) == len(args.prs) and min(args.prs) > 0,
            "Supply a parent and at least one child, with distinct positive PR numbers.")
    require(run("git", "rev-parse", "--is-shallow-repository") == "false", "A non-shallow clone is required.")
    require(not os.environ.get("GIT_OBJECT_DIRECTORY") and not os.environ.get("GIT_ALTERNATE_OBJECT_DIRECTORIES"),
            "Unset custom Git object directory variables first.")
    origin = run("git", "remote", "get-url", "origin")
    require(run("git", "remote", "get-url", "--push", "--all", "origin") == origin,
            "Origin must have exactly one identical fetch and push URL.")
    repo = args.repo or json.loads(run("gh", "repo", "view", "--json", "nameWithOwner"))["nameWithOwner"]
    origin_repo = json.loads(run("gh", "repo", "view", origin, "--json", "nameWithOwner"))["nameWithOwner"]
    require(repo.lower() == origin_repo.lower(), "Origin and requested GitHub repository differ.")

    def pr(number):
        return json.loads(run("gh", "pr", "view", str(number), "--repo", repo, "--json",
                              "state,baseRefName,headRefName,headRefOid,mergeCommit,isCrossRepository"))

    def tip(ref):
        rows = run("git", "ls-remote", "--refs", origin, ref).splitlines()
        require(len(rows) == 1, f"Missing or ambiguous remote ref: {ref}")
        oid, name = rows[0].split()
        require(name == ref and re.fullmatch(r"[0-9a-f]{40}", oid), f"Invalid remote ref: {ref}")
        return oid

    parent, *children = [pr(number) for number in args.prs]
    require(parent["state"] == "MERGED", "Parent PR must be MERGED.")
    require(not any(p["isCrossRepository"] for p in [parent, *children]), "Fork PRs are not supported.")
    original = parent["headRefOid"]
    squash = (parent["mergeCommit"] or {}).get("oid", "")
    require(all(re.fullmatch(r"[0-9a-f]{40}", oid) for oid in [original, squash]), "Invalid parent commit OIDs.")
    base = parent["baseRefName"]
    base_ref = f"refs/heads/{base}"
    run("git", "check-ref-format", base_ref)
    snapshots = {base_ref: tip(base_ref)}
    previous = parent
    for number, child in zip(args.prs[1:], children):
        require(child["state"] == "OPEN", f"PR #{number} must be OPEN.")
        require(child["baseRefName"] == previous["headRefName"], f"PR #{number} is not based on the preceding PR branch.")
        ref = f"refs/heads/{child['headRefName']}"
        run("git", "check-ref-format", ref)
        require(ref not in snapshots, "Stack branches must be distinct from each other and the target base.")
        snapshots[ref] = tip(ref)
        require(snapshots[ref] == child["headRefOid"], f"PR #{number} metadata and remote head differ; retry.")
        previous = child

    def unchanged():
        for ref, oid in snapshots.items():
            require(tip(ref) == oid, f"Remote {ref} changed; nothing pushed, rerun verification.")

    with tempfile.TemporaryDirectory(prefix="restack-after-squash-") as temporary:
        objects = Path(temporary) / "objects"
        objects.mkdir()
        env = dict(os.environ, GIT_OBJECT_DIRECTORY=str(objects),
                   GIT_ALTERNATE_OBJECT_DIRECTORIES=run("git", "rev-parse", "--path-format=absolute", "--git-path", "objects"),
                   GIT_NO_REPLACE_OBJECTS="1")

        def git(*command):
            return run("git", *command, env=env)

        def ancestor(older, newer):
            result = subprocess.run(["git", "merge-base", "--is-ancestor", older, newer], env=env, capture_output=True, text=True)
            require(result.returncode in (0, 1), result.stderr)
            return result.returncode == 0

        git("-c", "fetch.writeCommitGraph=false", "fetch", "--no-auto-maintenance", "--no-tags",
            "--no-write-fetch-head", "--recurse-submodules=no", "--refmap=", origin, *snapshots, original, squash)
        unchanged()
        require(ancestor(squash, snapshots[base_ref]), "Parent squash is not in its target base branch.")
        require(len(git("show", "-s", "--format=%P", squash).split()) == 1, "Parent merge commit is not a single-parent squash.")
        require(git("rev-parse", f"{original}^{{tree}}") == git("rev-parse", f"{squash}^{{tree}}"),
                "Squash tree differs from original parent head; content-aware integration is required.")
        previous = original
        for number, child in zip(args.prs[1:], children):
            head = child["headRefOid"]
            require(ancestor(previous, head), f"PR #{number} does not contain the preceding original head.")
            require(not ancestor(squash, head), f"PR #{number} already contains the squash; inspect the stack manually.")
            print(f"PR #{number}: preserve tree {git('rev-parse', head + '^{tree}')} and add preceding repaired ancestry")
            previous = head

        edit = ["gh", "pr", "edit", str(args.prs[1]), "--repo", repo, "--base", base]
        print("After a successful push, retarget only the direct child:", shlex.join(edit))
        print("Keep stack branches/PR metadata unchanged: nonforce is not a deletion/rewind guard; GitHub has no atomic base CAS.")
        print("Push hooks:", "explicitly disabled" if args.skip_hook else "enabled")
        if not args.push:
            print("CHECK ONLY: no commits, pushes, retargeting or local ref/worktree changes. Signing and push permissions untested.")
            return

        updates = []
        previous = squash
        for number, child in zip(args.prs[1:], children):
            head = child["headRefOid"]
            tree = git("rev-parse", head + "^{tree}")
            commit = git("commit-tree", "-S", tree, "-p", head, "-p", previous, "-m",
                         f"Restack PR #{number} after squashed PR #{args.prs[0]} (tree unchanged)")
            git("verify-commit", commit)
            require(git("rev-parse", commit + "^{tree}") == tree and
                    git("show", "-s", "--format=%P", commit) == f"{head} {previous}", "Unexpected bridge tree or parents.")
            updates.append((f"refs/heads/{child['headRefName']}", commit))
            previous = commit
        unchanged()
        config = ["-c", "core.hooksPath=/dev/null"] if args.skip_hook else []
        git(*config, "push", "--atomic", "--no-follow-tags", "--recurse-submodules=no", origin,
            *(f"{oid}:{ref}" for ref, oid in updates))
        for ref, oid in updates:
            require(tip(ref) == oid, f"Push completed but {ref} moved again; inspect before proceeding.")
        print("Signed ancestry repair pushed; no PR was merged.")
        if args.retarget:
            fresh = pr(args.prs[1])
            require(fresh["state"] == "OPEN" and fresh["headRefOid"] == updates[0][1] and
                    fresh["baseRefName"] == children[0]["baseRefName"],
                    "Repair pushed, but child state/head/base changed; refusing retarget. Inspect manually.")
            run(*edit)
            print("Direct child retargeted; descendant bases unchanged.")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, KeyError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
