#!/usr/bin/env python3
"""Focused tests for the read-only PR activity snapshot."""

from datetime import datetime, timezone
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("pr_activity", Path(__file__).with_name("pr-activity.py"))
monitor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(monitor)


class ActivityTests(unittest.TestCase):
    def setUp(self):
        self.view = {
            "number": 42, "title": "Test PR", "url": "https://github.com/acme/repo/pull/42",
            "state": "OPEN", "isDraft": False, "mergeable": "MERGEABLE",
            "reviewDecision": "REVIEW_REQUIRED", "headRefOid": "abc123", "updatedAt": "2026-09-22T12:00:00Z",
            "statusCheckRollup": [
                {"__typename": "CheckRun", "name": "Build", "workflowName": "CI", "status": "COMPLETED", "conclusion": "SUCCESS", "detailsUrl": "https://example.test/build"},
                {"__typename": "StatusContext", "context": "deploy", "state": "PENDING", "targetUrl": "https://example.test/deploy"},
            ],
        }
        self.issue = {
            "id": 1, "created_at": "2026-09-20T10:00:00Z", "updated_at": "2026-09-22T11:00:00Z",
            "user": {"login": "bot"}, "html_url": "https://example.test/comment", "body": "Updated result",
        }
        self.inline = {
            "id": 7, "created_at": "2026-09-21T10:00:00Z", "updated_at": "2026-09-21T10:00:00Z",
            "user": {"login": "reviewer"}, "html_url": "https://example.test/inline", "body": "Please fix",
            "path": "ci.yml", "line": 10,
        }
        self.review = {
            "id": 8, "submitted_at": "2026-09-22T09:00:00Z", "state": "CHANGES_REQUESTED",
            "user": {"login": "reviewer"}, "html_url": "https://example.test/review", "body": "Needs work",
        }
        self.thread_page = [{"data": {"repository": {"pullRequest": {"reviewThreads": {"nodes": [{
            "id": "thread1", "isResolved": False, "isOutdated": False, "path": "ci.yml", "line": 10,
            "comments": {"nodes": [{"databaseId": 7}]},
        }]}}}}}]

    def test_edited_comment_and_thread_status(self):
        def fake_gh(*args):
            if args[:2] == ("pr", "view"):
                return self.view
            if args[:2] == ("api", "graphql"):
                return self.thread_page
            raise AssertionError(args)

        def fake_pages(endpoint):
            if "/issues/" in endpoint:
                return [self.issue]
            if endpoint.endswith("/reviews?per_page=100"):
                return [self.review]
            return [self.inline]

        with patch.object(monitor, "gh", side_effect=fake_gh), patch.object(monitor, "pages", side_effect=fake_pages):
            snapshot = monitor.collect("42", "acme/repo", datetime(2026, 9, 22, tzinfo=timezone.utc))

        self.assertEqual([a["kind"] for a in snapshot["activities"]], ["review", "comment_edited"])
        self.assertEqual(snapshot["review_threads"][0]["resolved"], False)
        self.assertEqual({c["name"] for c in snapshot["checks"]}, {"Build", "deploy"})
        self.assertEqual(next(c for c in snapshot["checks"] if c["name"] == "deploy")["status"], "PENDING")

    def test_since_is_inclusive(self):
        at = datetime(2026, 9, 22, 11, tzinfo=timezone.utc)
        self.assertGreaterEqual(monitor.parse_time(self.issue["updated_at"]), at)
        self.assertLess(monitor.parse_time(self.review["submitted_at"]), at)

    def test_all_pages_are_flattened(self):
        with patch.object(monitor, "gh", return_value=[[{"id": 1}], [{"id": 2}]]):
            self.assertEqual([x["id"] for x in monitor.pages("endpoint")], [1, 2])


if __name__ == "__main__":
    unittest.main()
