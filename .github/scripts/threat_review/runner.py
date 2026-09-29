"""Trusted-base orchestration. Fetch PR patches as data; never check out PR code."""
import re
from .client import GitHub, ReviewUnavailable, ScanTimeout
from .report import MARKER, LEGACY_MARKER, COMMENT_LIMIT, render, retain_same_head_findings
from .review import review
from .ensemble import configured_models, review_models
from .source import complete_files


def same_revision(pull, head, base_ref):
    # Ordinary target-branch pushes do not trigger another PR review. Keep the
    # pinned context, but suppress output for a new head or a different target.
    return (pull.get("state") == "open" and pull["head"]["sha"] == head
            and pull["base"]["ref"] == base_ref)


def run(event, root, env, github=None, reviewer=review):
    repository = event["repository"]["full_name"]
    pr = event["pull_request"]
    head, base, number = pr["head"]["sha"], pr["base"]["sha"], pr["number"]
    base_ref = pr["base"]["ref"]
    if (not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository)
            or not all(re.fullmatch(r"[0-9a-f]{40}", sha) for sha in (head, base))
            or type(number) is not int or number <= 0):
        raise ReviewUnavailable("Invalid PR event identity")
    models = configured_models(env)
    model = ", ".join(models)
    github = github or GitHub(repository, number, env["GH_TOKEN"])
    if pr.get("draft"):
        return "Skipped: draft PR."
    current = github.pull()
    if not same_revision(current, head, base_ref):
        return "Skipped: PR revision changed or PR closed."
    existing = github.existing_comment((MARKER, LEGACY_MARKER))
    findings, evidence, limits, error = [], {}, [], None
    outcomes = []
    diff_base = base
    try:
        key = env.get("OPENROUTER_API_KEY")
        if not key:
            raise ReviewUnavailable("OPENROUTER_API_KEY is not configured")
        diff_base = github.comparison_base(base, head)
        files = github.files(current["changed_files"])
        files = complete_files(github, files, diff_base, head)
        if files:
            # root is the trusted base checkout, not the PR branch.
            threat_model = (root / "docs/threat-model.yaml").read_text()
            findings, evidence, limits, outcomes = review_models(threat_model, files, key, models, reviewer)
            if any(outcome["status"] != "completed" for outcome in outcomes):
                error = "Scan incomplete: one or more configured reviewers did not finish; completed reviewers' findings are shown below"
    except ScanTimeout:
        error = "Scan incomplete: runtime limit reached; no complete review was produced"
    except ReviewUnavailable:
        error = "Scan incomplete / Review unavailable; check source availability, credentials, service capacity, and response validity"
    except Exception:
        # Exception reprs from libraries can include request data or credentials.
        error = "Unexpected review error; no review was completed"
    current = github.pull()
    if not same_revision(current, head, base_ref):
        return "Skipped: PR revision changed during review; no stale comment published."
    if not error and current["base"]["sha"] != base:
        try:
            # File enumeration uses the live PR API. If a base update actually
            # changes its merge base, we cannot claim coverage of the pinned diff.
            if github.comparison_base(current["base"]["sha"], head) != diff_base:
                error = "Scan incomplete: the target branch changed the PR diff; rerun against the updated target"
        except Exception:
            error = "Scan incomplete: could not verify the diff after the target branch advanced"
    # Clean first scans stay quiet; incomplete scans always notify the author.
    if findings or existing or error or limits:
        body = render(repository, head, base, model, findings, evidence, limits, error, diff_base, outcomes)
        if error or limits or len(body) > COMMENT_LIMIT:
            retained = retain_same_head_findings(existing, repository, head, body)
            if retained is None:
                return ("Scan incomplete (non-blocking): earlier same-head findings remain in the PR comment. "
                        "The retry exceeds the combined comment capacity; its report follows here.\n\n" + body)
            body = retained
        if len(body) > COMMENT_LIMIT:
            error = "Scan incomplete: findings exceed the PR comment capacity; split the PR for complete feedback"
            body = render(repository, head, base, model, [], {}, [], error, diff_base, outcomes)
        github.publish(existing, body)
    if error:
        return f"Review unavailable (non-blocking): {error}."
    if limits:
        return f"Scan incomplete (non-blocking): {len(limits)} file(s) lack complete text source."
    return f"Full PR scan completed: {len(findings)} finding(s); {len(limits)} file(s) with limited coverage; {len(outcomes)} reviewer(s) completed."


def summarize(message, env):
    print(message)
    if env.get("GITHUB_STEP_SUMMARY"):
        with open(env["GITHUB_STEP_SUMMARY"], "a") as summary:
            summary.write("## Threat model review (advisory)\n\n" + message + "\n")
