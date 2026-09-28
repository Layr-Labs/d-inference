"""Trusted-base review with private-only findings and fixed public status text."""
import re
from .client import GitHub, PrivateAdvisories
from .report import render
from .review import DEFAULT_MODEL, review

COMPLETED = "Advisory review completed. Any findings are restricted to authorized security collaborators."
UNAVAILABLE = "Advisory review unavailable (non-blocking); verify private-reporting credentials and service availability."
SKIPPED = "Advisory review skipped (non-blocking)."


def same_revision(pull, head, base):
    return pull.get("state") == "open" and pull["head"]["sha"] == head and pull["base"]["sha"] == base


def run(event, root, env, github=None, reviewer=review, advisories=None):
    # Public Actions output must not contain model responses, finding counts,
    # private advisory identifiers, or exception text (including API responses).
    try:
        repository = event["repository"]["full_name"]
        pr = event["pull_request"]
        head, base, number = pr["head"]["sha"], pr["base"]["sha"], pr["number"]
        if (not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository)
                or not all(re.fullmatch(r"[0-9a-f]{40}", sha) for sha in (head, base))
                or type(number) is not int or number <= 0):
            return UNAVAILABLE
        model = env.get("THREAT_REVIEW_MODEL") or DEFAULT_MODEL
        if not re.fullmatch(r"[A-Za-z0-9_.:/-]{1,150}", model):
            return UNAVAILABLE
        if pr.get("draft"):
            return SKIPPED
        key, advisory_token = env.get("OPENROUTER_API_KEY"), env.get("THREAT_REVIEW_ADVISORY_TOKEN")
        if not key or not advisory_token:
            return UNAVAILABLE
        github = github or GitHub(repository, number, env["GH_TOKEN"])
        advisories = advisories or PrivateAdvisories(repository, advisory_token)
        current = github.pull()
        if not same_revision(current, head, base):
            return SKIPPED
        diff_base = github.comparison_base(base, head)
        files = github.files(current["changed_files"])
        findings, evidence, limits = [], {}, []
        if files:
            # root is the trusted base checkout, not the PR branch.
            threat_model = (root / "docs/threat-model.yaml").read_text()
            findings, evidence, limits = reviewer(threat_model, files, key, model)
        if not same_revision(github.pull(), head, base):
            return SKIPPED
        if findings:
            advisories.create(number, head, render(repository, head, base, model,
                                                  findings, evidence, limits, diff_base=diff_base))
        return COMPLETED
    except Exception:
        # Never fall back to a public comment, artifact, annotation or detailed log.
        return UNAVAILABLE


def summarize(message, env):
    message = message if message in (COMPLETED, UNAVAILABLE, SKIPPED) else UNAVAILABLE
    print(message)
    if env.get("GITHUB_STEP_SUMMARY"):
        with open(env["GITHUB_STEP_SUMMARY"], "a") as summary:
            summary.write("## Threat model review (advisory)\n\n" + message + "\n")
