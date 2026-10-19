#!/usr/bin/env python3
"""Refresh a managed skills clone and return one fetched revision's instructions."""

import json
import os
from pathlib import Path
import subprocess
import sys


PACKAGE_ROOT = "automations/nightly-linear"
SKILLS = ("darkbloom-work-history", "darkbloom-linear-nightly")


def refresh(config_path):
    config = json.loads(Path(config_path).read_text())
    source = config["source_repo"]
    repo = Path(source["checkout_path"]).expanduser().resolve()
    branch = source["branch"]
    environment = dict(os.environ, GIT_TERMINAL_PROMPT="0")

    def git(*arguments, optional=False):
        result = subprocess.run(
            ["git", "-C", str(repo), *arguments],
            capture_output=True, text=True, env=environment, timeout=30,
        )
        if result.returncode and not optional:
            # Do not echo remote URLs, credential-bearing diagnostics, or config.
            raise ValueError(
                f"Git {arguments[0]} failed (exit {result.returncode}). "
                "Check repository access and the configured branch; no workflow loaded."
            )
        return result.returncode, result.stdout.strip()

    if not (repo / ".git").is_dir():
        raise ValueError("The configured path must be a dedicated ordinary Git clone.")
    if git("rev-parse", "--show-toplevel")[1] != str(repo):
        raise ValueError("The configured path must be the clone's repository root.")
    if git("config", "--local", "--get", "nightlyLinear.managed", optional=True)[1] != "true":
        raise ValueError("This checkout is not marked as a managed nightly-skills clone.")
    if git("config", "--get", "remote.origin.url")[1] != source["origin_url"]:
        raise ValueError("The clone's origin differs from the saved source repository.")
    if not isinstance(branch, str) or not branch or branch.startswith("-"):
        raise ValueError("The configured branch is invalid.")
    git("check-ref-format", f"refs/heads/{branch}")
    if git("symbolic-ref", "--quiet", "--short", "HEAD")[1] != branch:
        raise ValueError("The managed clone is not on the configured branch.")
    if git("status", "--porcelain", "--untracked-files=all", "--ignored")[1]:
        raise ValueError("The managed clone has local files or edits. Preserve them before updating.")

    # An explicit ref prevents use of a stale tracking ref after a failed fetch.
    git("fetch", "--no-tags", "origin",
        f"refs/heads/{branch}:refs/remotes/origin/{branch}")
    revision = git("rev-parse", f"refs/remotes/origin/{branch}^{{commit}}")[1]
    head = git("rev-parse", "HEAD")[1]
    if git("merge-base", "--is-ancestor", head, revision, optional=True)[0]:
        raise ValueError("The clone has local commits or divergent history. No reset was performed.")

    # Read by object ID, so all returned instructions come from the same commit.
    skills = {}
    for name in SKILLS:
        body = git("show", f"{revision}:{PACKAGE_ROOT}/skills/{name}/SKILL.md")[1]
        if not body.startswith("---\n") or f"\nname: {name}\n" not in body:
            raise ValueError(f"The fetched {name} skill has an invalid identity or frontmatter.")
        skills[name] = body
    playbook = git("show", f"{revision}:{PACKAGE_ROOT}/run.md")[1]
    if not playbook:
        raise ValueError("The fetched nightly playbook is empty.")

    # Keep the installed skill symlinks current without overwriting local work.
    git("merge", "--ff-only", revision)
    if git("rev-parse", "HEAD")[1] != revision:
        raise ValueError("The checkout changed during refresh. Retry before starting Linear work.")
    return {"revision": revision, "playbook": playbook, "skills": skills}


def main():
    if len(sys.argv) != 2:
        print("Usage: refresh.py /absolute/path/config.json", file=sys.stderr)
        return 2
    try:
        result = refresh(sys.argv[1])
    except (OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired) as error:
        print(f"Skill refresh failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
