"""Exercise the real pre-push hook with local Git history and stub check tools."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


HOOK = Path(__file__).resolve().parents[1] / ".githooks/pre-push"
ZERO = "0" * 40


class PrePushTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.calls = self.root / "checks.log"
        self.git("init", "-q")
        self.git("config", "user.name", "Hook fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        self.git("config", "core.hooksPath", "/dev/null")
        (self.root / "coordinator").mkdir()
        (self.root / "console-ui").mkdir()
        for directory in ("coordinator", "console-ui"):
            (self.root / directory / ".keep").touch()
        self.git("add", "coordinator", "console-ui")
        self.base = self.commit("README.md", "base")
        self.git("update-ref", "refs/remotes/origin/master", self.base)
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        for name in ("gofmt", "go", "npx", "npm"):
            script = bin_dir / name
            script.write_text('#!/bin/sh\nprintf "%s %s\\n" "' + name + '" "$*" >> "$HOOK_CALLS"\nexit "${HOOK_CHECK_STATUS:-0}"\n')
            script.chmod(0o755)
        self.env = {**os.environ, "PATH": str(bin_dir) + os.pathsep + os.environ["PATH"],
                    "HOOK_CALLS": str(self.calls)}

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.root, text=True).strip()

    def commit(self, path, contents):
        (self.root / path).write_text(contents)
        self.git("add", path)
        self.git("commit", "-qm", path)
        return self.git("rev-parse", "HEAD")

    def run_hook(self, *refs, status="0"):
        lines = "".join(f"refs/heads/branch{i} {local} refs/heads/branch{i} {remote}\n"
                        for i, (local, remote) in enumerate(refs))
        result = subprocess.run(["bash", str(HOOK), "origin", "unused"], cwd=self.root,
                                env={**self.env, "HOOK_CHECK_STATUS": status},
                                input=lines, capture_output=True, text=True)
        calls = self.calls.read_text() if self.calls.exists() else ""
        return result, calls

    def test_new_branch_checks_committed_changes_with_clean_worktree(self):
        head = self.commit("coordinator/main.go", "package main\n")
        result, calls = self.run_hook((head, ZERO))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("go test ./...", calls)
        self.assertNotIn("npm", calls)

    def test_multiple_refs_and_trailing_deletion_keep_both_components(self):
        go_head = self.commit("coordinator/main.go", "package main\n")
        self.git("checkout", "-q", self.base)
        web_head = self.commit("console-ui/page.ts", "export {}\n")
        result, calls = self.run_hook((go_head, self.base), (web_head, self.base), (ZERO, self.base))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("go test ./...", calls)
        self.assertIn("npx eslint --quiet src/", calls)
        self.assertIn("npm run build", calls)

    def test_new_ref_for_existing_remote_commit_needs_no_checks(self):
        result, calls = self.run_hook((self.base, ZERO))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, "")

    def test_unknown_remote_commit_fails_instead_of_guessing_a_range(self):
        result, calls = self.run_hook((self.base, "1" * 40))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, "")

    def test_check_failure_blocks_push(self):
        head = self.commit("coordinator/main.go", "package main\n")
        result, calls = self.run_hook((head, self.base), status="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("go test ./...", calls)

    def test_staged_go_bytes_are_checked_even_if_worktree_is_formatted(self):
        source = self.root / "coordinator/file with spaces.go"
        source.write_text("package main\nfunc main(){println(1)}\n")
        self.git("add", str(source))
        source.write_text("package main\n\nfunc main() { println(1) }\n")
        # Stub the formatter to inspect its stdin, without depending on Go installation.
        formatter = self.root / "bin/gofmt"
        formatter.write_text('#!/bin/sh\ncontent=$(cat)\ncase "$content" in *"main(){"*) echo diff;; esac\n')
        formatter.chmod(0o755)
        result = subprocess.run(["bash", str(HOOK.with_name("pre-commit"))], cwd=self.root,
                                env=self.env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("file with spaces.go", result.stderr)
        self.git("add", str(source))
        result = subprocess.run(["bash", str(HOOK.with_name("pre-commit"))], cwd=self.root,
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
