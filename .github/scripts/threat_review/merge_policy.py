"""Conditional merge clearance from trusted live evidence and formal reviews."""
import re
from .client import ReviewUnavailable


def clean(report, head, base):
    if not isinstance(report, dict) or report.get("head") != head or report.get("base") != base:
        return False
    review = report.get("review")
    if not isinstance(review, dict):
        return False
    counts = [review.get(k) for k in ("covered_units", "total_units", "depth_batches_pending")]
    if any(type(v) is not int or v < 0 for v in counts):
        return False
    if counts[0] != counts[1] or counts[2] != 0 or review.get("integration_completed") is not True:
        return False
    if review.get("errors") != [] or review.get("limited_files") != []:
        return False
    findings = review.get("findings")
    if not isinstance(findings, list):
        return False
    return all(isinstance(f, dict) and f.get("severity") == "low" for f in findings)


def manual_override(github, pull):
    """Require a current formal human approval with an explicit SHA and reason.

    Comments or labels alone never waive the review. Current collaborator rights
    and the reviewer's latest decisive review are fetched from GitHub each time.
    """
    reviews = []
    for page in range(1, 11):
        batch = github.call(f"/pulls/{pull['number']}/reviews?per_page=100&page={page}")
        if not isinstance(batch, list):
            raise ReviewUnavailable("Review history unavailable")
        reviews.extend(batch)
        if len(batch) < 100:
            break
    else:
        raise ReviewUnavailable("Review history exceeds verification limit")
    latest = {}
    for review in sorted(reviews, key=lambda r: r["id"]):
        if review.get("state") in ("APPROVED", "CHANGES_REQUESTED", "DISMISSED"):
            latest[review["user"]["id"]] = review
    marker = re.compile(r"(?im)^security override: " + re.escape(pull["head"]["sha"]) + r"\s*$")
    allowed = []
    for review in latest.values():
        user = review["user"]
        if user.get("type") != "User" or user["id"] == pull["user"]["id"]:
            continue
        login = user["login"]
        if not re.fullmatch(r"[A-Za-z0-9-]+", login):
            continue
        permission = github.call(f"/collaborators/{login}/permission")["permission"]
        if permission not in ("admin", "maintain", "write"):
            continue
        if review["state"] == "CHANGES_REQUESTED":
            raise ReviewUnavailable("An independent reviewer still requests changes")
        body = review.get("body") or ""
        if (review["state"] == "APPROVED" and review.get("commit_id") == pull["head"]["sha"]
                and marker.search(body) and re.search(r"(?im)^reason:\s*\S.{9,}", body)):
            allowed.append(login)
    return sorted(allowed)[0] if allowed else None
