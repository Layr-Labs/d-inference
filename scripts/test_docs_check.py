"""Validate documentation navigation using tiny, isolated repository fixtures."""

from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().with_name("docs-check.sh")
STAMP = "> Last updated: 2026-09-11 · commit `ef7b5a9aa`\n"


class DocsCheckTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        (self.root / "scripts").mkdir()
        (self.root / "docs").mkdir()
        shutil.copy2(SCRIPT, self.root / "scripts/docs-check.sh")
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)

    def check(self, index, page="Page.md", content="", tracked=True, env=None):
        (self.root / "docs/README.md").write_text(STAMP + index)
        (self.root / "docs" / page).write_text(STAMP + content)
        if tracked:
            subprocess.run(["git", "add", "docs"], cwd=self.root, check=True)
        return subprocess.run(["bash", "scripts/docs-check.sh", *([] if tracked else ["--all"])],
                              cwd=self.root, capture_output=True, text=True, env=env)

    def test_all_documents_share_one_parser_process(self):
        launcher = self.root / "bin"
        launcher.mkdir()
        wrapper = launcher / "python3"
        wrapper.write_text('#!/bin/sh\nprintf "invoked\\n" >> "$DOCS_CHECK_PYTHON_TRACE"\n'
                           'exec "$DOCS_CHECK_PYTHON" "$@"\n')
        wrapper.chmod(0o755)
        trace = self.root / "python-invocations"
        environment = dict(os.environ, PATH=str(launcher) + os.pathsep + os.environ["PATH"],
                           DOCS_CHECK_PYTHON=sys.executable, DOCS_CHECK_PYTHON_TRACE=str(trace))
        links = ["[Page](Page.md)"]
        for index in range(20):
            page = f"extra-{index}.md"
            (self.root / "docs" / page).write_text(STAMP)
            links.append(f"[Extra]({page})")
        result = self.check("\n".join(links), env=environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(trace.read_text().splitlines(), ["invoked"])

    def test_escaped_brackets_in_link_labels_preserve_navigation(self):
        for usage in (
            r"[Guide \] details](Page.md)",
            r"[Guide \[ details](Page.md)",
            r"[Guide \\](Page.md)",
            r"[Guide \] details][guide]" + "\n[guide]: Page.md",
            r"[guide\]][]" + "\n" + r"[guide\]]: Page.md",
            r"[guide\]]" + "\n" + r"[guide\]]: Page.md",
        ):
            with self.subTest(usage=usage):
                result = self.check(usage + "\n")
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_escaped_label_does_not_hide_a_missing_target(self):
        result = self.check("[Page](Page.md)\n" + r"[Guide \] details](Missing.md)" + "\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("broken link -> Missing.md", result.stderr)

    def test_soft_line_breaks_in_link_labels_preserve_navigation(self):
        for usage in (
            "[Read the\n guide](Page.md)",
            "[Read the\n guide][some guide]\n\n[some guide]: Page.md",
            "[Read][some\n guide]\n\n[some guide]: Page.md",
            "[some\n guide][]\n\n[some guide]: Page.md",
            "[some\n guide]\n\n[some guide]: Page.md",
            "[Read\n#not-heading](Page.md)",
            "[Read\n-not-list](Page.md)",
            "[Read\n2. guide](Page.md)",
            "[Read\n===suffix](Page.md)",
            "[Read\n***suffix](Page.md)",
            "[Read\n<span>guide</span>](Page.md)",
            "[Read\n<custom>guide</custom>](Page.md)",
        ):
            with self.subTest(usage=usage):
                result = self.check(usage + "\n")
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_wrapped_labels_do_not_hide_missing_link_or_image_targets(self):
        for usage in ("[Read the\n guide](Missing.md)", "![Read the\n guide](Missing.md)"):
            with self.subTest(usage=usage):
                result = self.check("[Page](Page.md)\n" + usage + "\n")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("broken link -> Missing.md", result.stderr)

    def test_block_boundaries_do_not_join_link_labels(self):
        for usage in (
            "[Read\n\n guide](Page.md)",
            "[Read\n \t\n guide](Page.md)",
            "`[Read\n guide](Page.md)`",
            "~~~markdown\n[Read\n guide](Page.md)\n~~~",
            "[Read\n~~~\nexample\n~~~\n guide](Page.md)",
            "[Read\n# Heading\n guide](Page.md)",
            "[Read\n- list entry\n guide](Page.md)",
            "[Read\n> quoted\n guide](Page.md)",
            "[Read\n1. list entry\n guide](Page.md)",
            "# [Read\n guide](Page.md)",
            "[Read\n===\n guide](Page.md)",
            "[Read\n***\n guide](Page.md)",
            "[Wrapped\n<div>\nlabel](Page.md)",
            "[Wrapped\n</DIV>\nlabel](Page.md)",
            "[Wrapped\n<script>\nlabel](Page.md)",
            "[Wrapped\n<!-- comment -->\nlabel](Page.md)",
        ):
            with self.subTest(usage=usage):
                result = self.check(usage + "\n")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Page.md: orphan", result.stderr)

    def test_reference_links_and_encoded_spaces_count_as_navigation(self):
        result = self.check("[Guide][guide]\n\n[guide]: Some%20Page.md#details\n", page="Some Page.md")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_unused_definition_does_not_hide_an_orphan(self):
        result = self.check("[unused]: Page.md\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Page.md: orphan", result.stderr)

    def test_reference_use_variants_create_navigation_edges(self):
        for usage in ("[Read the guide][guide]", "[guide][]", "[guide]", "[GUIDE]"):
            with self.subTest(usage=usage):
                result = self.check(usage + "\n\n[guide]: Page.md\n")
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_reference_labels_normalize_whitespace(self):
        result = self.check("[Read][Some   Guide]\n\n[some guide]: Page.md\n")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_code_examples_do_not_create_navigation_edges(self):
        examples = (
            "```markdown\n[Page](Page.md)\n```\n",
            "~~~markdown\n[Page][guide]\n~~~\n[guide]: Page.md\n",
            "````markdown\n```\n[Page](Page.md)\n````\n",
            "`[guide]`\n[guide]: Page.md\n",
        )
        for example in examples:
            with self.subTest(example=example):
                result = self.check(example)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Page.md: orphan", result.stderr)

    def test_code_fence_definition_cannot_resolve_a_reference(self):
        result = self.check("[guide]\n```\n[guide]: Page.md\n```\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Page.md: orphan", result.stderr)

    def test_inline_link_and_reference_targets_stay_independent(self):
        result = self.check("[guide](Page.md)\n[guide]: Missing.md\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("broken link -> Missing.md", result.stderr)
        self.assertNotIn("orphan", result.stderr)

    def test_missing_reference_target_is_reported(self):
        result = self.check("[Page](Page.md)\n[broken]: Missing.md\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("broken link -> Missing.md", result.stderr)

    def test_broken_inline_image_target_is_still_checked(self):
        result = self.check("[Page](Page.md)\n![diagram](Missing.svg)\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("broken link -> Missing.svg", result.stderr)

    def test_images_do_not_create_navigation_edges(self):
        for usage in ("![diagram][guide]", "![guide][]", "![guide]", "![diagram](Page.md)"):
            with self.subTest(usage=usage):
                result = self.check(usage + "\n[guide]: Page.md\n")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Page.md: orphan", result.stderr)
                self.assertNotIn("broken link", result.stderr)

    def test_broken_reference_images_are_still_checked(self):
        result = self.check("[Page](Page.md)\n![diagram][image]\n[image]: Missing.svg\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("broken link -> Missing.svg", result.stderr)
        self.assertNotIn("orphan", result.stderr)

    def test_escaped_bang_before_reference_is_a_link(self):
        result = self.check(r"\![guide]" + "\n[guide]: Page.md\n")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_clickable_images_preserve_outer_navigation(self):
        (self.root / "docs/asset.svg").write_text("<svg/>")
        for usage in (
            "[![diagram](asset.svg)](Page.md)",
            "[![diagram\n label](asset.svg)](Page.md)",
            "[![diagram][image]][guide]\n[image]: asset.svg\n[guide]: Page.md",
            "[![image][]][guide]\n[image]: asset.svg\n[guide]: Page.md",
        ):
            with self.subTest(usage=usage):
                result = self.check(usage + "\n")
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_clickable_image_checks_missing_outer_target(self):
        (self.root / "docs/asset.svg").write_text("<svg/>")
        result = self.check("[![diagram](asset.svg)](Missing.md)\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("broken link -> Missing.md", result.stderr)

    def test_clickable_image_checks_missing_image_target(self):
        result = self.check("[![diagram](Missing.svg)](Page.md)\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("broken link -> Missing.svg", result.stderr)
        self.assertNotIn("orphan", result.stderr)

    def test_orphans_and_missing_citations_are_independent_errors(self):
        result = self.check("", content="`coordinator/missing.go`\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("orphan", result.stderr)
        self.assertIn("cites missing path", result.stderr)

    def test_untracked_option_and_code_fence_citation_exemption(self):
        result = self.check("[Page](Page.md)\n", content="```\n`coordinator/example.go`\n```\n", tracked=False)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
