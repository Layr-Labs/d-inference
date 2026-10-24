#!/usr/bin/env python3
"""Exercise read-only changelog tooling against real temporary repositories."""

import contextlib
import io
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

import changelog


class ChangelogTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="changelog-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "changelog.d").mkdir()
        self.write("CHANGELOG.md", "# Changelog\n\n## v1.0.0 - 2026-01-01\n\nHistory.\n")
        self.write("changelog.d/README.md", "Not a fragment.\n")

    def write(self, name, text):
        path = self.root / name
        path.write_text(text, encoding="utf-8")
        return path

    def fragment(self, name="example.md", text="### Example\n\n- A change.\n"):
        return self.write(f"changelog.d/{name}", text)

    def command(self, *args):
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            status = changelog.main(list(args), self.root)
        return status, stdout.getvalue(), stderr.getvalue()

    def test_empty_pending_set(self):
        self.assertEqual(self.command("check"), (0, "changelog: 0 valid fragment(s)\n", ""))
        self.assertEqual(self.command("preview"), (0, "## Unreleased\n", ""))
        status, output, error = self.command("render", "--version", "1.1.0", "--date", "2026-10-08")
        self.assertEqual((status, output), (1, ""))
        self.assertIn("no pending", error)

    def test_nested_and_fenced_markdown_preserves_body(self):
        text = ("### Detailed topic\n\nFirst paragraph.\n\n"
                "- Parent\n  - Nested item with `inline code`.\n\n"
                "#### Details\n\n````markdown\n# Not a section\n"
                "```\n## Still code\n````\n\n"
                "~~~text\n### Also code\n~~~\n\n"
                "    # Indented code\n\n```Inline code span```\n\nLast paragraph.\n")
        self.fragment(text="\n \n" + text + "\n")
        self.assertEqual(changelog.preview(self.root), "## Unreleased\n\n" + text)

    def test_independent_fragments_combine_in_filename_order(self):
        later = "### Zeta change\n\n- Independently added second change.\n"
        earlier = "### Alpha change\n\n- Independently added first change.\n"
        self.fragment("zeta-change.md", later)
        self.fragment("alpha-change.md", earlier)
        self.assertEqual(changelog.preview(self.root),
                         "## Unreleased\n\n" + earlier + "\n" + later)
        self.assertEqual(changelog.render(self.root, "1.1.0", "2026-10-08"),
                         "## v1.1.0 - 2026-10-08\n\n" + earlier + "\n" + later)

    def test_subset_is_sorted_and_leaves_other_fragments_pending(self):
        for name in ("alpha", "beta", "later"):
            self.fragment(f"{name}.md", f"### {name}\n\n{name} body.\n")
        status, output, error = self.command(
            "render", "--version", "1.1.0", "--date", "2028-02-29", "beta.md", "alpha.md")
        self.assertEqual((status, error), (0, ""))
        self.assertEqual(output, "## v1.1.0 - 2028-02-29\n\n"
                         "### alpha\n\nalpha body.\n\n### beta\n\nbeta body.\n")
        self.assertIn("later.md", changelog.load_fragments(self.root))

    def test_malformed_fragments(self):
        cases = (
            ("", "blank"), (" \n\t\n", "blank"),
            ("## Topic\n\nBody.", "first nonempty"),
            ("#### Topic\n\nBody.", "first nonempty"),
            ("###\n\nBody.", "first nonempty"),
            ("### ###\n\nBody.", "topic must not be empty"),
            ("### Topic\nBody.", "blank line"),
            ("### Topic\n\n", "blank line"),
            ("### Topic\n\n# Extra\n", "extra level 1"),
            ("### Topic\n\n  ## Extra\n", "extra level 2"),
            ("### Topic\n\n### Extra\n", "extra level 3"),
            ("### Topic\n\nExtra\n===\n", "extra level 1"),
            ("### Topic\n\nExtra\n---\n", "extra level 2"),
            ("### Topic\n\n```text\nBody.\n", "unclosed fenced"),
        )
        for text, message in cases:
            with self.subTest(text=text):
                self.fragment(text=text)
                with self.assertRaisesRegex(ValueError, message):
                    changelog.preview(self.root)
        self.fragment(text="\n\n### Topic\n\nBody.\n\n## Extra\n")
        with self.assertRaisesRegex(ValueError, "example.md:7: extra level 2"):
            changelog.preview(self.root)

    def test_invalid_filenames(self):
        for name in ("Upper.md", "two_words.md", "two--words.md", "-topic.md",
                     "topic-.md", "topic.txt", ".hidden.md", "topic.MD", "two words.md"):
            with self.subTest(name=name):
                path = self.fragment(name)
                with self.assertRaisesRegex(ValueError, "kebab-case"):
                    changelog.load_fragments(self.root)
                path.unlink()

    def test_invalid_utf8_and_nonregular_files(self):
        path = self.root / "changelog.d/example.md"
        path.write_bytes(b"### Invalid\n\n\xff\n")
        self.assertEqual(self.command("check"),
                         (1, "", "changelog: changelog.d/example.md: invalid UTF-8\n"))
        path.unlink()
        path.mkdir()
        with self.assertRaisesRegex(ValueError, "regular file"):
            changelog.load_fragments(self.root)
        path.rmdir()
        os.mkfifo(path)
        with self.assertRaisesRegex(ValueError, "regular file"):
            changelog.load_fragments(self.root)

    def test_symlinks_and_linked_fragment_directory(self):
        target = self.write("outside.md", "### Outside\n\nDo not follow.\n")
        path = self.root / "changelog.d/example.md"
        path.symlink_to(target)
        with self.assertRaisesRegex(ValueError, "symlink"):
            changelog.load_fragments(self.root)
        path.unlink()
        path.symlink_to(self.root / "missing.md")
        with self.assertRaisesRegex(ValueError, "symlink"):
            changelog.load_fragments(self.root)
        path.unlink()
        (self.root / "changelog.d/README.md").unlink()
        (self.root / "changelog.d").rmdir()
        (self.root / "changelog.d").symlink_to(self.root, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "regular directory"):
            changelog.load_fragments(self.root)

    def test_duplicate_topics(self):
        self.fragment("alpha.md", "### Shared topic\n\nOne.\n")
        self.fragment("beta.md", "### SHARED  topic ###\n\nTwo.\n")
        with self.assertRaisesRegex(ValueError, "duplicate topic heading.*alpha.md"):
            changelog.preview(self.root)

    def test_merge_markers_even_in_code(self):
        for marker in ("<<<<<<< HEAD", "=======", ">>>>>>> feature", "||||||| base"):
            with self.subTest(marker=marker):
                self.fragment(text=f"### Topic\n\n```text\n{marker}\n```\n")
                with self.assertRaisesRegex(ValueError, "merge conflict marker"):
                    changelog.load_fragments(self.root)

    def test_bad_selections_and_unselected_invalid_fragment(self):
        self.fragment()
        for names in (("../outside.md",), ("/tmp/outside.md",), ("changelog.d/example.md",),
                      ("missing.md",), ("README.md",), ("example.md", "example.md")):
            with self.subTest(names=names), self.assertRaises(ValueError):
                changelog.render(self.root, "1.1.0", "2026-10-08", names)
        self.fragment("other.md", "Invalid fragment.\n")
        with self.assertRaisesRegex(ValueError, "other.md"):
            changelog.render(self.root, "1.1.0", "2026-10-08", ["example.md"])

    def test_invalid_version_and_date(self):
        self.fragment()
        for version in ("v1.2.3", "1.2", "1.2.3.4", "01.2.3", "1.02.3", "1.2.03",
                        "1.2.3-rc.1", "1.2.3+build", "-1.2.3", "1.2.3\n"):
            with self.subTest(version=version), self.assertRaisesRegex(ValueError, "version must"):
                changelog.render(self.root, version, "2026-10-08")
        for day in ("2026-02-29", "2026-04-31", "2026-13-01", "2026-1-01",
                    "20261008", "0000-01-01", "2026-10-08T00:00:00", "2026-10-08\n"):
            with self.subTest(day=day), self.assertRaisesRegex(ValueError, "calendar date"):
                changelog.render(self.root, "1.1.0", day)

    def test_existing_version_and_similar_versions(self):
        self.fragment()
        for heading in ("## v1.2.3", "## v1.2.3 - 2026-01-01",
                        "## 1.2.3 (2026-01-01)", "## 1.2.3 - prepared candidate"):
            with self.subTest(heading=heading):
                self.write("CHANGELOG.md", f"# Changelog\n\n{heading}\n\nHistory.\n")
                with self.assertRaisesRegex(ValueError, "already appears"):
                    changelog.render(self.root, "1.2.3", "2026-10-08")
        self.write("CHANGELOG.md", "# Changelog\n\n## v1.2.30\n\nHistory.\n\n"
                   "```text\n## v1.2.3\n```\n")
        self.assertTrue(changelog.render(self.root, "1.2.3", "2026-10-08").startswith("## v1.2.3 -"))

    def test_cli_root_and_all_operations_are_read_only(self):
        (self.root / "scripts").mkdir()
        script = self.root / "scripts/changelog.py"
        shutil.copyfile(Path(changelog.__file__), script)
        self.fragment()

        def snapshot():
            return {str(path.relative_to(self.root)): (path.read_bytes(), path.stat().st_mtime_ns)
                    for path in self.root.rglob("*") if path.is_file()}

        before = snapshot()
        for args in (("check",), ("preview",),
                     ("render", "--version", "1.1.0", "--date", "2026-10-08"),
                     ("render", "--version", "1.0.0", "--date", "2026-10-08")):
            result = subprocess.run([sys.executable, "-B", str(script), *args], cwd=self.root.parent,
                                    text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 1 if "1.0.0" in args else 0, result.stderr)
            self.assertEqual(snapshot(), before)


if __name__ == "__main__":
    unittest.main()
