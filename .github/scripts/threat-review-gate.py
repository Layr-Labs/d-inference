#!/usr/bin/env python3
"""Evaluate the conditional merge policy using trusted checkout and GitHub data."""
import json
import os
from pathlib import Path
import sys

from threat_review.client import GitHub
from threat_review.merge_policy import clean, manual_override
from threat_review.runner import same_revision, verify_diff


def main():
    env = os.environ
    if env.get("THREAT_REVIEW_REQUIRE_CLEARANCE") != "true":
        return 0
    event = json.loads(Path(env.get("THREAT_REVIEW_EVENT_PATH", env["GITHUB_EVENT_PATH"])).read_text())
    expected = event["pull_request"]
    github = GitHub(env["GITHUB_REPOSITORY"], expected["number"], env["GH_TOKEN"])
    pull = github.pull()
    if not same_revision(pull, expected["head"]["sha"], expected["base"]["ref"]) or pull.get("draft"):
        return 1
    reviewer = manual_override(github, pull)
    if sys.argv[1] == "before":
        if reviewer:
            with open(env["GITHUB_OUTPUT"], "a") as stream:
                stream.write("overridden=true\n")
        return 0
    if reviewer:
        print(f"Manual security override approved by {reviewer} for {pull['head']['sha']}. Findings remain in the PR.")
        return 0
    report = json.loads(Path(env["THREAT_REVIEW_RESULT_FILE"]).read_text())
    if report.get("repository") != env["GITHUB_REPOSITORY"]:
        return 1
    verify_diff(github, pull, expected["base"]["sha"], expected["head"]["sha"], report["diff_base"])
    if not clean(report, expected["head"]["sha"], expected["base"]["sha"]):
        print("Review clearance pending: substantial findings or incomplete coverage require an independent manual security override.")
        return 1
    # Changes to the gate, credentials, CI or its threat definitions require a
    # human even if a model overlooks their effect on future auto-merge safety.
    sensitive = (".github/", ".agents/", "scripts/", "infra/")
    if any(f["filename"].startswith(sensitive) or f["filename"] in ("docs/threat-model.yaml", "AGENTS.md")
           or f.get("previous_filename", "").startswith(sensitive)
           or f.get("previous_filename") in ("docs/threat-model.yaml", "AGENTS.md")
           for f in github.files(pull["changed_files"])):
        print("Review-control changes require an independent manual security override.")
        return 1
    print("Complete current-revision scan has no medium/high findings; normal CI requirements still apply.")
    return 0


if __name__ == "__main__":
    try:
        status = main()
    except Exception:
        print("Review clearance unavailable; no automatic approval was issued.")
        status = 1
    raise SystemExit(status)
