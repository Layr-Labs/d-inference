"""Bounded JSON transport for fixed GitHub and OpenRouter API endpoints."""
import json
import re
from urllib.error import HTTPError, URLError
from urllib.request import Request, build_opener, HTTPRedirectHandler

MAX_FILE_LIST_BYTES = 8_000_000


class ReviewUnavailable(Exception):
    """Safe, credential-free failure suitable for an Actions summary."""


class SourceBudgetExceeded(ReviewUnavailable):
    """Stop collection before aggregate source data grows further."""


class ScanTimeout(Exception):
    """Whole-scan deadline; must bypass per-file API error recovery."""


class NoRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def request_json(url, token, payload=None, method=None, timeout=90):
    request = Request(url, data=None if payload is None else json.dumps(payload).encode(),
                      method=method, headers={"Authorization": f"Bearer {token}",
                      "Accept": "application/vnd.github+json" if url.startswith("https://api.github.com/") else "application/json",
                      "Content-Type": "application/json", "User-Agent": "darkbloom-threat-review"})
    try:
        with build_opener(NoRedirects()).open(request, timeout=timeout) as response:
            data = response.read(4_000_001)
            if len(data) > 4_000_000:
                raise ReviewUnavailable("API response exceeded the review size limit")
            return json.loads(data)
    except HTTPError as error:
        # Do not print provider error bodies, prompts, tokens, or response headers.
        raise ReviewUnavailable(f"API returned HTTP {error.code}") from None
    except (URLError, TimeoutError, OSError, ValueError):
        raise ReviewUnavailable("API unavailable or returned invalid JSON") from None


class GitHub:
    def __init__(self, repository, number, token, transport=request_json):
        self.root = f"https://api.github.com/repos/{repository}"
        self.number, self.token, self.transport = number, token, transport

    def call(self, path, payload=None, method=None):
        return self.transport(self.root + path, self.token, payload, method)

    def pull(self):
        return self.call(f"/pulls/{self.number}")

    def comparison_base(self, base, head):
        comparison = self.call(f"/compare/{base}...{head}?per_page=1")
        sha = comparison.get("merge_base_commit", {}).get("sha", "")
        if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{40}", sha):
            raise ReviewUnavailable("GitHub did not provide a valid diff merge base")
        return sha

    def files(self, count):
        if count > 3000:
            raise ReviewUnavailable("GitHub cannot enumerate more than 3000 PR files; scan incomplete")
        files, size = [], 0
        for page in range(1, 31):
            batch = self.call(f"/pulls/{self.number}/files?per_page=100&page={page}")
            # Patches remain available as fallback when a blob cannot be read.
            # Bound their total before extending the retained file inventory.
            size += len(json.dumps(batch).encode("utf-8"))
            if size > MAX_FILE_LIST_BYTES:
                raise SourceBudgetExceeded("Aggregate PR file-list budget exceeded; scan incomplete")
            files.extend(batch)
            if len(batch) < 100:
                break
        if len(files) != count:
            raise ReviewUnavailable("PR changed during file collection or file list is incomplete")
        return files

    def existing_comment(self, marker):
        # Paginate instead of only inspecting the first 100 PR comments.
        markers = (marker,) if isinstance(marker, str) else marker
        matches = {}
        for page in range(1, 31):
            comments = self.call(f"/issues/{self.number}/comments?per_page=100&page={page}")
            for comment in comments:
                if (comment.get("user", {}).get("login") == "github-actions[bot]"
                        and comment.get("body", "").startswith(markers)):
                    matches[comment["id"]] = comment
            if len(comments) < 100:
                break
        else:
            raise ReviewUnavailable("Comment history exceeds the pagination limit")
        # Prefer the canonical marker even when an older legacy report appears
        # first. Within a marker, keep the most recently created bot report.
        ordered = sorted(matches.values(), key=lambda comment: comment["id"], reverse=True)
        for prefix in markers:
            for comment in ordered:
                if comment["body"].startswith(prefix):
                    return dict(comment, duplicate_ids=[id for id in matches if id != comment["id"]])
        return None

    def publish(self, existing, body):
        if existing:
            result = self.call(f"/issues/comments/{existing['id']}", {"body": body}, "PATCH")
            url = self.root.replace("https://api.github.com/repos/", "https://github.com/")
            url += f"/pull/{self.number}#issuecomment-{existing['id']}"
            for id in existing.get("duplicate_ids", []):
                self.call(f"/issues/comments/{id}", {"body":
                    f"This earlier advisory report is superseded by [the current review]({url}). "
                    "Use that report for current findings and coverage."}, "PATCH")
            return result
        return self.call(f"/issues/{self.number}/comments", {"body": body}, "POST")
