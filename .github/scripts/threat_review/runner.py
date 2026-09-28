"""Trusted-base orchestration. Fetch PR patches as data; never check out PR code."""
import re
from .client import GitHub, ReviewUnavailable
from .report import MARKER, LEGACY_MARKER, render
from .review import DEFAULT_MODEL, review


def same_revision(pull, head, base):
    return pull.get("state") == "open" and pull["head"]["sha"] == head and pull["base"]["sha"] == base


def run(event, root, env, github=None, reviewer=review):
    repository = event["repository"]["full_name"]
    pr = event["pull_request"]
    head, base, number = pr["head"]["sha"], pr["base"]["sha"], pr["number"]
    if (not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository)
            or not all(re.fullmatch(r"[0-9a-f]{40}", sha) for sha in (head, base))
            or type(number) is not int or number <= 0):
        raise ReviewUnavailable("Invalid PR event identity")
    model = env.get("THREAT_REVIEW_MODEL") or DEFAULT_MODEL
    if not re.fullmatch(r"[A-Za-z0-9_.:/-]{1,150}", model):
        raise ReviewUnavailable("Invalid configured model identifier")
    github = github or GitHub(repository, number, env["GH_TOKEN"])
    if pr.get("draft"):
        return "Skipped: draft PR."
    current = github.pull()
    if not same_revision(current, head, base):
        return "Skipped: PR revision changed or PR closed."
    existing = github.existing_comment((MARKER, LEGACY_MARKER))
    findings, evidence, limits, error = [], {}, [], None
    diff_base = base
    try:
        key = env.get("OPENROUTER_API_KEY")
        if not key:
            raise ReviewUnavailable("OPENROUTER_API_KEY is not configured")
        diff_base = github.comparison_base(base, head)
        files = github.files(current["changed_files"])
        if files:
            # root is the trusted base checkout, not the PR branch.
            threat_model = (root / "docs/threat-model.yaml").read_text()
            findings, evidence, limits = reviewer(threat_model, files, key, model)
    except ReviewUnavailable as failure:
        error = str(failure)
    except Exception:
        # Exception reprs from libraries can include request data or credentials.
        error = "Unexpected review error; no review was completed"
    if not same_revision(github.pull(), head, base):
        return "Skipped: PR revision changed during review; no stale comment published."
    # Quiet when clean/unavailable unless an earlier finding needs superseding.
    if findings or existing:
        github.publish(existing, render(repository, head, base, model, findings, evidence, limits, error, diff_base))
    if error:
        return f"Review unavailable (non-blocking): {error}."
    return f"Advisory review completed: {len(findings)} finding(s); {len(limits)} file(s) with limited coverage."


def summarize(message, env):
    print(message)
    if env.get("GITHUB_STEP_SUMMARY"):
        with open(env["GITHUB_STEP_SUMMARY"], "a") as summary:
            summary.write("## Threat model review (advisory)\n\n" + message + "\n")
