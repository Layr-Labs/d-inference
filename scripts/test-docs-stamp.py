#!/usr/bin/env python3
"""Exercise date-only stamping against isolated files and real Git history."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


STAMPER = Path(__file__).with_name("docs-stamp.sh")


class DocsStampTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="docs-stamp-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "scripts").mkdir()
        shutil.copyfile(STAMPER, self.root / "scripts/docs-stamp.sh")
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith("GIT_") and not key.startswith("DOCS_STAMP_")}
        self.env.update({
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_TERMINAL_PROMPT": "0",
            "DOCS_STAMP_DATE": "2030-01-02",
        })
        self.git("init", "-q")
        self.git("config", "user.name", "Docs fixture")
        self.git("config", "user.email", "docs-fixture@example.invalid")

    def git(self, *arguments, date="2026-01-03T12:00:00Z"):
        env = dict(self.env, GIT_AUTHOR_DATE=date, GIT_COMMITTER_DATE=date)
        return subprocess.run(
            ["git", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
             *arguments], cwd=self.root, env=env,
            text=True, capture_output=True, check=True, timeout=15,
        ).stdout.strip()

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path

    def stamp(self, *arguments, env=None):
        result = subprocess.run(
            ["bash", "scripts/docs-stamp.sh", *arguments], cwd=self.root,
            env=env or self.env, text=True, capture_output=True, timeout=15,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_migration_preserves_date_and_all_body_evidence(self):
        legacy = "> Last updated: 2026-03-04 · commit `123456789`"
        body = (
            "\nPin: `a" + "b" * 39 + "`\n"
            "[source](https://github.com/org/repo/blob/123456789/source.swift)\n"
            "```text\n> Last updated: 1999-01-01 · commit `abcdef123`\n```\n"
        )
        path = self.write("docs/reports/frozen.md", f"# Frozen\n\n{legacy}\n{body}")
        self.stamp("--from-git", "docs/reports/frozen.md")
        expected = f"# Frozen\n\n> Last updated: 2026-03-04\n{body}"
        self.assertEqual(path.read_text(), expected)
        before = path.stat().st_mtime_ns
        self.assertEqual(self.stamp("--from-git", "docs/reports/frozen.md").stdout, "")
        self.assertEqual(path.read_text(), expected)
        self.assertEqual(path.stat().st_mtime_ns, before)

    def test_default_refresh_uses_override_and_is_idempotent(self):
        path = self.write("docs/current.md", "# Current\n\n> Last updated: 2020-01-01\n\nBody.\n")
        self.stamp("docs/current.md")
        expected = "# Current\n\n> Last updated: 2030-01-02\n\nBody.\n"
        self.assertEqual(path.read_text(), expected)
        self.assertEqual(self.stamp("docs/current.md").stdout, "")
        self.assertEqual(path.read_text(), expected)

    def test_migration_preserves_header_annotations_and_evidence_commits(self):
        for note in (
            "(immutable source below): [source](https://example.invalid/blob/abcdef123/file) commit `abcdef123`",
            "commit `abcdef123` is separate source evidence",
        ):
            with self.subTest(note=note):
                path = self.write("docs/record.md", "# Record\n\n> Last updated: 2020-01-01"
                                  f" · commit `123456789` {note}\n\nBody.\n")
                self.stamp("--from-git", "docs/record.md")
                expected = f"# Record\n\n> Last updated: 2020-01-01\n\n{note}\n\nBody.\n"
                self.assertEqual(path.read_text(), expected)
                self.assertEqual(self.stamp("--from-git", "docs/record.md").stdout, "")
                self.assertEqual(path.read_text(), expected)

    def test_from_git_keeps_stamp_date_over_newer_content_history(self):
        path = self.write("docs/record.md", "# Record\n\n> Last updated: 2020-01-01\n\nBody.\n")
        self.git("add", "docs/record.md")
        self.git("commit", "-qm", "Newer commit")
        self.stamp("--from-git", "docs/record.md")
        self.assertIn("> Last updated: 2020-01-01\n", path.read_text())

    def test_from_git_without_stamp_uses_content_date_not_rename_date(self):
        self.write("docs/original.md", "# Original\n\nBody.\n")
        self.git("add", "docs/original.md")
        self.git("commit", "-qm", "Create record")
        self.git("mv", "docs/original.md", "docs/renamed.md")
        self.git("commit", "-qm", "Rename record", date="2026-08-09T12:00:00Z")
        self.stamp("--from-git", "docs/renamed.md")
        self.assertEqual((self.root / "docs/renamed.md").read_text(),
                         "# Original\n\n> Last updated: 2026-01-03\n\nBody.\n")

    def test_untracked_record_without_stamp_uses_override(self):
        path = self.write("docs/new.md", "# New\n\nBody.\n")
        self.stamp("--from-git", "docs/new.md")
        self.assertIn("> Last updated: 2030-01-02\n", path.read_text())

    def test_insertion_without_existing_stamp_handles_heading_and_no_heading(self):
        for text, expected in (
            ("# Heading\nBody.\n", "# Heading\n\n> Last updated: 2030-01-02\n\nBody.\n"),
            ("Body.\n", "> Last updated: 2030-01-02\n\nBody.\n"),
        ):
            with self.subTest(text=text):
                path = self.write("docs/new.md", text)
                self.stamp("docs/new.md")
                self.assertEqual(path.read_text(), expected)
                self.assertEqual(self.stamp("docs/new.md").stdout, "")

    def test_bulk_migration_only_touches_tracked_docs(self):
        one = self.write("docs/one.md", "# One\n\n> Last updated: 2021-01-01 · commit `123456789`\n")
        two = self.write("docs/reports/two.md", "# Two\n\n> Last updated: 2022-02-02 · commit `abcdef123`\n")
        draft = self.write("docs/draft.md", "# Draft\n")
        other = self.write("README.md", "# Other\n")
        self.git("add", "docs/one.md", "docs/reports/two.md", "README.md")
        self.stamp("--from-git")
        self.assertEqual(one.read_text(), "# One\n\n> Last updated: 2021-01-01\n")
        self.assertEqual(two.read_text(), "# Two\n\n> Last updated: 2022-02-02\n")
        self.assertEqual(draft.read_text(), "# Draft\n")
        self.assertEqual(other.read_text(), "# Other\n")

    def test_invalid_date_override_does_not_modify_document(self):
        path = self.write("docs/new.md", "# New\n")
        env = dict(self.env, DOCS_STAMP_DATE="2030-01-02 · commit `123456789`")
        result = subprocess.run(
            ["bash", "scripts/docs-stamp.sh", "docs/new.md"], cwd=self.root,
            env=env, text=True, capture_output=True, timeout=15,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must be YYYY-MM-DD", result.stderr)
        self.assertEqual(path.read_text(), "# New\n")


if __name__ == "__main__":
    unittest.main()
