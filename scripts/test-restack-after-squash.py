#!/usr/bin/env python3
"""Local Git integration tests; GitHub and signing are the only mocked boundaries."""

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("restack", Path(__file__).with_name("restack-after-squash.py"))
restack = importlib.util.module_from_spec(spec)
spec.loader.exec_module(restack)
REAL_RUN = restack.run


class RestackTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="test-restack-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.old_cwd = os.getcwd()
        self.addCleanup(os.chdir, self.old_cwd)
        self.env_patch = patch.dict(os.environ, {
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.test",
            "GIT_COMMITTER_NAME": "Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.test",
        })
        self.env_patch.start()
        self.addCleanup(self.env_patch.stop)
        self.remote = self.root / "remote.git"
        REAL_RUN("git", "init", "--bare", str(self.remote))
        self.work = self.root / "work"
        REAL_RUN("git", "init", "-b", "main", str(self.work))
        os.chdir(self.work)
        self.git("remote", "add", "origin", str(self.remote))
        self.commit("base")
        self.git("checkout", "-b", "parent")
        parent = self.commit("parent")
        self.git("checkout", "-b", "child")
        child = self.commit("child")
        self.git("checkout", "-b", "descendant")
        descendant = self.commit("descendant")
        self.git("checkout", "main")
        self.git("merge", "--squash", "parent")
        self.git("commit", "-m", "squash parent")
        self.squash = self.git("rev-parse", "HEAD")
        self.git("push", "origin", "main", "parent", "child", "descendant")
        self.prs = {
            1: self.metadata("MERGED", "main", "parent", parent, self.squash),
            2: self.metadata("OPEN", "parent", "child", child),
            3: self.metadata("OPEN", "child", "descendant", descendant),
        }
        self.calls = []
        self.mutate_before_push = None
        self.mutate_before_edit = None
        self.views = {}

    def git(self, *args):
        return REAL_RUN("git", *args)

    def commit(self, content):
        Path("content").write_text(content + "\n")
        self.git("add", "content")
        self.git("commit", "-m", content)
        return self.git("rev-parse", "HEAD")

    @staticmethod
    def metadata(state, base, branch, head, squash=None):
        return dict(state=state, baseRefName=base, headRefName=branch, headRefOid=head,
                    mergeCommit={"oid": squash} if squash else None, isCrossRepository=False)

    def boundary(self, *args, env=None):
        self.calls.append(args)
        if args[0] == "gh":
            if args[1:3] == ("repo", "view"):
                return json.dumps({"nameWithOwner": "fixture/repo"})
            number = int(args[3])
            if args[2] == "edit":
                self.prs[number]["baseRefName"] = args[-1]
                return ""
            self.views[number] = self.views.get(number, 0) + 1
            if self.views[number] > 1 and self.mutate_before_edit:
                self.mutate_before_edit(self.prs[number])
            return json.dumps(self.prs[number])
        if args[1] == "commit-tree":
            self.assertIn("-S", args)
            return REAL_RUN(*(a for a in args if a != "-S"), env=env)
        if args[1] == "verify-commit":
            return ""
        if "push" in args:
            if self.mutate_before_push:
                self.mutate_before_push()
            result = REAL_RUN(*args, env=env)
            for record in self.prs.values():
                record["headRefOid"] = self.git("--git-dir", str(self.remote), "rev-parse", record["headRefName"])
            return result
        return REAL_RUN(*args, env=env)

    def invoke(self, *args):
        with patch.object(restack, "run", side_effect=self.boundary), contextlib.redirect_stdout(io.StringIO()):
            restack.main(list(args))

    def remote_head(self, branch):
        return self.git("--git-dir", str(self.remote), "rev-parse", branch)

    def test_default_check_leaves_refs_worktree_and_remote_unchanged(self):
        before = self.git("show-ref")
        remote = self.git("ls-remote", "origin")
        self.invoke("1", "2", "3")
        self.assertEqual(before, self.git("show-ref"))
        self.assertEqual(remote, self.git("ls-remote", "origin"))
        self.assertEqual("", self.git("status", "--porcelain"))
        self.assertFalse(any("commit-tree" in call or "push" in call for call in self.calls))

    def test_sequential_squashes_preserve_content_and_merge_without_conflicts(self):
        original_child = self.prs[2]["headRefOid"]
        original_desc = self.prs[3]["headRefOid"]
        self.invoke("--push", "--retarget", "1", "2", "3")
        self.git("fetch", "origin")
        repaired_child = self.remote_head("child")
        repaired_desc = self.remote_head("descendant")
        for old, new in [(original_child, repaired_child), (original_desc, repaired_desc)]:
            self.assertEqual(self.git("rev-parse", old + "^{tree}"), self.git("rev-parse", new + "^{tree}"))
        self.assertEqual(f"{original_child} {self.squash}", self.git("show", "-s", "--format=%P", repaired_child))
        self.assertEqual(f"{original_desc} {repaired_child}", self.git("show", "-s", "--format=%P", repaired_desc))
        self.assertEqual("main", self.prs[2]["baseRefName"])
        self.assertEqual("child", self.prs[3]["baseRefName"])
        self.git("merge", "--squash", repaired_child)
        self.git("commit", "-m", "squash child")
        second_squash = self.git("rev-parse", "HEAD")
        self.git("push", "origin", "main")
        self.prs[2].update(state="MERGED", mergeCommit={"oid": second_squash})
        self.invoke("--push", "2", "3")
        self.git("fetch", "origin")
        final_desc = self.remote_head("descendant")
        self.git("merge", "--squash", final_desc)
        self.assertEqual(self.git("write-tree"), self.git("rev-parse", original_desc + "^{tree}"))
        pushes = [call for call in self.calls if "push" in call]
        self.assertTrue(all("--atomic" in call and not any("force" in arg for arg in call) for call in pushes))
        self.assertTrue(all("core.hooksPath=/dev/null" not in call for call in pushes))

    def test_rejects_unmerged_parent_wrong_base_missing_ancestry_and_tree_mismatch(self):
        cases = [(1, "state", "OPEN", "MERGED"), (2, "baseRefName", "main", "preceding PR"),
                 (1, "headRefOid", self.prs[3]["headRefOid"], "Squash tree differs")]
        for number, key, value, message in cases:
            old = self.prs[number][key]
            self.prs[number][key] = value
            with self.assertRaisesRegex(RuntimeError, message):
                self.invoke("--push", "1", "2", "3")
            self.prs[number][key] = old
        self.git("--git-dir", str(self.remote), "update-ref", "refs/heads/child", self.squash)
        self.prs[2]["headRefOid"] = self.squash
        with self.assertRaisesRegex(RuntimeError, "preceding original head"):
            self.invoke("--push", "1", "2", "3")

    def test_atomic_push_rejects_concurrent_forward_update(self):
        old_child = self.remote_head("child")
        old_desc = self.remote_head("descendant")
        concurrent = self.git("--git-dir", str(self.remote), "commit-tree", self.git("rev-parse", old_desc + "^{tree}"), "-p", old_desc, "-m", "concurrent")
        self.mutate_before_push = lambda: self.git("--git-dir", str(self.remote), "update-ref", "refs/heads/descendant", concurrent)
        with self.assertRaisesRegex(RuntimeError, "failed"):
            self.invoke("--push", "1", "2", "3")
        self.assertEqual(old_child, self.remote_head("child"))
        self.assertEqual(concurrent, self.remote_head("descendant"))

    def test_retarget_refuses_fresh_metadata_changes(self):
        self.mutate_before_edit = lambda record: record.update(baseRefName="unexpected")
        with self.assertRaisesRegex(RuntimeError, "refusing retarget"):
            self.invoke("--push", "--retarget", "1", "2", "3")
        self.assertFalse(any(call[:3] == ("gh", "pr", "edit") for call in self.calls))

    def test_skip_hook_is_explicit_and_push_local(self):
        hook = Path(".git/hooks/pre-push")
        hook.write_text("#!/bin/sh\nexit 1\n")
        hook.chmod(0o755)
        before = self.remote_head("child")
        with self.assertRaisesRegex(RuntimeError, "failed"):
            self.invoke("--push", "1", "2", "3")
        self.assertEqual(before, self.remote_head("child"))
        self.calls.clear()
        self.invoke("--push", "--skip-hook", "1", "2", "3")
        pushes = [call for call in self.calls if "push" in call]
        self.assertEqual(1, len(pushes))
        self.assertIn("core.hooksPath=/dev/null", pushes[0])
        self.assertFalse(any(call[:3] == ("gh", "pr", "edit") for call in self.calls))

    def test_signature_verification_failure_never_pushes(self):
        def failed_verifier(*args, env=None):
            if args[:2] == ("git", "verify-commit"):
                raise RuntimeError("signature verification failed")
            return self.boundary(*args, env=env)

        before = self.remote_head("child")
        with patch.object(restack, "run", side_effect=failed_verifier), contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(RuntimeError, "signature verification failed"):
                restack.main(["--push", "1", "2", "3"])
        self.assertEqual(before, self.remote_head("child"))
        self.assertFalse(any("push" in call for call in self.calls))


if __name__ == "__main__":
    unittest.main()
