#!/usr/bin/env python3
"""Read-only pull request activity snapshot using the authenticated GitHub CLI."""

import argparse
from datetime import datetime
import json
import re
import subprocess
from urllib.parse import urlsplit, urlunsplit


THREADS_QUERY = """
query($owner: String!, $name: String!, $number: Int!, $endCursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      reviewThreads(first: 100, after: $endCursor) {
        nodes {
          id isResolved isOutdated path line
          comments(first: 1) { nodes { databaseId } }
        }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
}
"""


def gh(*args):
    result = subprocess.run(["gh", *map(str, args)], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or f"gh exited {result.returncode}")
    return json.loads(result.stdout)


def pages(endpoint):
    return [item for page in gh("api", "--paginate", "--slurp", endpoint) for item in page]


def parse_time(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def excerpt(body):
    body = re.sub(r"(?m)^\[vc\]:[^\n]*\n?", "", body or "")
    body = re.sub(r"<!--.*?-->", "", body, flags=re.DOTALL)
    return " ".join(body.split())[:180]


def public_url(url):
    if not url:
        return None
    parts = urlsplit(url)
    return urlunsplit((parts.scheme, parts.netloc, parts.path, "", parts.fragment))


def event(kind, item, when, **extra):
    return {
        "kind": kind,
        "id": item["id"],
        "at": when,
        "author": (item.get("user") or {}).get("login"),
        "url": item.get("html_url"),
        "summary": excerpt(item.get("body")),
        **extra,
    }


def normalize_checks(rollup):
    checks = []
    for check in rollup or []:
        if check["__typename"] == "CheckRun":
            checks.append({
                "name": check["name"],
                "workflow": check.get("workflowName") or "",
                "status": check["status"],
                "conclusion": check.get("conclusion") or None,
                "url": public_url(check.get("detailsUrl")),
            })
        elif check["__typename"] == "StatusContext":
            checks.append({
                "name": check["context"],
                "workflow": "",
                "status": check["state"],
                "conclusion": None,
                "url": public_url(check.get("targetUrl")),
            })
    return sorted(checks, key=lambda c: (c["workflow"], c["name"], c["url"] or ""))


def collect(pr, repo, since=None):
    if not repo:
        match = re.fullmatch(r"https://github\.com/([^/]+/[^/]+)/pull/\d+/?", str(pr))
        repo = match.group(1) if match else gh("repo", "view", "--json", "nameWithOwner")["nameWithOwner"]
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
        raise ValueError("--repo must be OWNER/REPO")
    view = gh(
        "pr", "view", pr, "--repo", repo, "--json",
        "number,title,url,state,isDraft,mergeable,headRefOid,statusCheckRollup,"
        "updatedAt,reviewDecision",
    )
    number = view["number"]
    owner, name = repo.split("/")
    base = f"repos/{repo}"
    issue_comments = pages(f"{base}/issues/{number}/comments?per_page=100")
    inline_comments = pages(f"{base}/pulls/{number}/comments?per_page=100")
    reviews = pages(f"{base}/pulls/{number}/reviews?per_page=100")
    thread_pages = gh(
        "api", "graphql", "--paginate", "--slurp", "-F", f"owner={owner}",
        "-F", f"name={name}", "-F", f"number={number}", "-f", f"query={THREADS_QUERY}",
    )
    threads = []
    for page in thread_pages:
        connection = page["data"]["repository"]["pullRequest"]["reviewThreads"]
        threads.extend(connection["nodes"])
    roots = {
        t["comments"]["nodes"][0]["databaseId"]: t
        for t in threads if t["comments"]["nodes"]
    }
    normalized_threads = sorted(
        ({
            "id": t["id"], "root_comment_id": t["comments"]["nodes"][0]["databaseId"],
            "path": t["path"], "line": t["line"], "resolved": t["isResolved"],
            "outdated": t["isOutdated"],
        } for t in threads if t["comments"]["nodes"]),
        key=lambda t: (t["path"], t["root_comment_id"]),
    )
    activities = []
    for comment in issue_comments:
        edited = comment["updated_at"] > comment["created_at"]
        activities.append(event(
            "comment_edited" if edited else "comment", comment,
            comment["updated_at"] if edited else comment["created_at"],
        ))
    for comment in inline_comments:
        root_id = comment.get("in_reply_to_id", comment["id"])
        thread = roots.get(root_id)
        edited = comment["updated_at"] > comment["created_at"]
        activities.append(event(
            "inline_comment_edited" if edited else "inline_comment", comment,
            comment["updated_at"] if edited else comment["created_at"],
            thread_id=thread["id"] if thread else None,
            resolved=thread["isResolved"] if thread else None,
            path=comment.get("path"), line=comment.get("line"),
        ))
    for review in reviews:
        if review.get("submitted_at"):
            activities.append(event(
                "review", review, review["submitted_at"], state=review["state"],
            ))
    if since:
        activities = [a for a in activities if parse_time(a["at"]) >= since]
    activities.sort(key=lambda a: (a["at"], a["kind"], a["id"]))
    return {
        "pr": {
            "number": number, "repo": repo, "title": view["title"], "url": view["url"],
            "state": view["state"], "draft": view["isDraft"],
            "mergeable": view["mergeable"], "review_decision": view["reviewDecision"],
            "head_sha": view["headRefOid"], "updated_at": view["updatedAt"],
        },
        "since": since.isoformat().replace("+00:00", "Z") if since else None,
        "activities": activities,
        "review_threads": normalized_threads,
        "checks": normalize_checks(view["statusCheckRollup"]),
    }


def render(snapshot):
    pr = snapshot["pr"]
    print(f"{pr['url']} — {pr['title']}")
    print(f"{pr['state']} · mergeable={pr['mergeable']} · review={pr['review_decision']} · head={pr['head_sha'][:12]}")
    label = f"since {snapshot['since']}" if snapshot["since"] else "all history"
    print(f"Activity ({label}): {len(snapshot['activities'])}")
    for item in snapshot["activities"]:
        detail = f" {item['path']}" if item.get("path") else ""
        print(f"  {item['at']} {item['kind']} {item['author']}{detail}: {item['summary']} {item['url']}")
    unresolved = [t for t in snapshot["review_threads"] if not t["resolved"]]
    print(f"Review threads: {len(unresolved)} unresolved / {len(snapshot['review_threads'])} total")
    for thread in unresolved:
        print(f"  {thread['path']}:{thread['line'] or '?'} root comment {thread['root_comment_id']}")
    print(f"Checks: {len(snapshot['checks'])}")
    for check in snapshot["checks"]:
        print(f"  {check['workflow']} / {check['name']}: {check['conclusion'] or check['status']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pr", help="PR number or URL")
    parser.add_argument("--repo", help="OWNER/REPO (defaults to current repository)")
    parser.add_argument("--since", help="inclusive RFC3339 timestamp; comments edited after this time appear")
    parser.add_argument("--json", action="store_true", help="machine-readable snapshot")
    args = parser.parse_args()
    try:
        since = parse_time(args.since) if args.since else None
        if since and since.utcoffset() is None:
            raise ValueError("--since must include a timezone, for example 2026-09-22T00:00:00Z")
        snapshot = collect(args.pr, args.repo, since)
    except (ValueError, RuntimeError, KeyError, TypeError, json.JSONDecodeError) as exc:
        parser.exit(1, f"pr-activity: {exc}\n")
    if args.json:
        print(json.dumps(snapshot, indent=2))
    else:
        render(snapshot)


if __name__ == "__main__":
    main()
