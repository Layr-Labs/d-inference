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

    def test_balanced_nested_labels_preserve_links_and_clickable_images(self):
        (self.root / "docs/Asset.png").touch()
        for usage in (
            "[Outer [middle [inner]]](Page.md)",
            "[Outer [middle [inner]]][guide]\n\n[guide]: Page.md",
            "[Outer [middle\n [inner]]](Page.md)",
            "[" * 16 + "inner" + "]" * 16 + "(Page.md)",
            "[![Outer [middle [inner]]](Asset.png)](Page.md)",
            "[![Outer [middle [inner]]][asset]][guide]\n\n[asset]: Asset.png\n[guide]: Page.md",
            r"[Outer \[middle \[inner\]\]][guide]" + "\n\n[guide]: Page.md",
            r"[guide][Outer \[middle \[inner\]\]]" + "\n\n"
            + r"[Outer \[middle \[inner\]\]]: Page.md",
        ):
            with self.subTest(usage=usage):
                result = self.check("\n" + usage + "\n")
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_balanced_nested_labels_do_not_hide_missing_targets(self):
        for usage, missing in (
            ("[Outer [middle [inner]]](Missing.md)", "Missing.md"),
            ("[![Outer [middle [inner]]](Missing.png)](Page.md)", "Missing.png"),
        ):
            with self.subTest(usage=usage):
                result = self.check("\n[Page](Page.md)\n" + usage + "\n")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"broken link -> {missing}", result.stderr)
                self.assertNotIn("orphan", result.stderr)

    def test_nested_links_resolve_inner_references_without_promoting_alt_text(self):
        (self.root / "docs/Asset.png").touch()
        for usage, navigates in (
            ("[Outer [middle [inner]]]\n\n[inner]: Page.md", True),
            ("[Outer [middle [inner]]](Page.md)\n\n[inner]: Asset.png", False),
            ("[guide][Outer [middle [inner]]]\n\n[guide]: Page.md", False),
            ("![Outer [middle [inner]]](Page.md)", False),
            ("[![Outer [middle [inner]]](Page.md)](https://example.com)", False),
            ("![alt [inside](Page.md)](Asset.png)", False),
            ("[![alt [inside](Asset.png)](Asset.png)](Page.md)", False),
        ):
            with self.subTest(usage=usage):
                result = self.check("\n" + usage + "\n")
                if navigates:
                    self.assertEqual(result.returncode, 0, result.stderr)
                else:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("Page.md: orphan", result.stderr)
                self.assertNotIn("broken link", result.stderr)
        result = self.check("\n[Page](Page.md)\n![alt [inside](Missing.md)](Asset.png)\n")
        self.assertEqual(result.returncode, 0, result.stderr)

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
                result = self.check("\n" + usage + "\n")
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
                result = self.check("\n" + usage + "\n")
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

    def test_invalid_backtick_fence_info_does_not_hide_links(self):
        for opener, closer, renders_links in (
            ("``` bad`tick", "", True),
            ("``` bad`tick", "```", True),
            ("```` bad`tick", "```", True),
            (r"``` bad\`tick", "", True),
            ("``` markdown", "```", False),
            ("~~~ bad`tick", "~~~", False),
        ):
            with self.subTest(opener=opener, closer=closer):
                result = self.check(f"\n{opener}\n[Page](Page.md)\n[Broken](Missing.md)\n{closer}\n")
                self.assertNotEqual(result.returncode, 0)
                if renders_links:
                    self.assertIn("broken link -> Missing.md", result.stderr)
                    self.assertNotIn("orphan", result.stderr)
                else:
                    self.assertIn("Page.md: orphan", result.stderr)
                    self.assertNotIn("broken link", result.stderr)

    def test_html_blocks_do_not_create_navigation(self):
        for example in (
            "<!-- [guide] -->",
            "<!-- [unused] --> [guide]",
            "<!--\n[guide]\n-->",
            "<!--\n\n[guide]\n-->",
            "<script>\n[guide]\n</script>",
            "<PRE>\n[guide]\n</PRE>",
            "<style>\n[guide]\n</style>",
            "<textarea>\n[guide]\n</textarea>",
            "<?instruction\n[guide]\n?>",
            "<!DOCTYPE\n[guide]\n>",
            "<![CDATA[\n[guide]\n]]>",
            "<div>\n[guide]\n</div>",
            "</DIV>\n[guide]",
            "<span>\n[guide]\n</span>",
            "<custom data-example='text'>\n[guide]\n</custom>",
            "> <!--\n> [guide]\n> -->",
            "- <div>\n  [guide]\n  </div>",
            "<div>\n```\n[guide]\n</div>",
        ):
            with self.subTest(example=example):
                result = self.check("\n" + example + "\n\n[guide]: Page.md\n")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Page.md: orphan", result.stderr)
                self.assertNotIn("broken link", result.stderr)

    def test_inline_html_tokens_do_not_create_navigation(self):
        for example in (
            "Text <!-- [guide] --> text",
            "Text <!--\n[guide]\n--> text",
            '<span title="[guide]">Text</span>',
            "Text <? [guide] ?> text",
            "Text <![CDATA[[guide]]]> text",
            "Text <!EXAMPLE [guide]> text",
            "Text <!-- ` [guide] --> text",
        ):
            with self.subTest(example=example):
                result = self.check("\n" + example + "\n\n[guide]: Page.md\n")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Page.md: orphan", result.stderr)
                self.assertNotIn("broken link", result.stderr)

    def test_html_block_definitions_cannot_resolve_a_reference(self):
        for example in (
            "<!--\n[guide]: Page.md\n-->",
            "<div>\n[guide]: Page.md\n</div>",
            "<script>\n[guide]: Page.md\n</script>",
            "<span>\n[guide]: Page.md\n</span>",
        ):
            with self.subTest(example=example):
                result = self.check("\n" + example + "\n\n[guide]\n")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Page.md: orphan", result.stderr)

    def test_inline_html_comment_definitions_stay_hidden(self):
        result = self.check("\nText <!--\n[guide]: Page.md\n--> text\n\n[guide]\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Page.md: orphan", result.stderr)
        result = self.check("\nText <!--\n[unused]: Missing.md\n--> text\n\n[Page](Page.md)\n")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_deferred_definitions_preserve_label_continuation(self):
        (self.root / "docs/Asset.png").write_bytes(b"fixture")
        result = self.check("\n[Read\n[guide]: Asset.png\nlabel](Page.md)\n")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_unmatched_backtick_runs_do_not_hide_navigation(self):
        for example in ("`` [guide] `", "Text ``` [guide] ``", "Text ```` [guide] ```"):
            with self.subTest(example=example):
                result = self.check("\n" + example + "\n\n[guide]: Page.md\n")
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_hidden_html_links_are_not_checked_as_missing_files(self):
        for example in (
            "<!-- [hidden](Missing.md) -->",
            "Text <!-- [hidden](Missing.md) --> text",
            "<div>\n[hidden](Missing.md)\n[hidden]: Missing.md\n</div>",
            '<span title="[hidden](Missing.md)">Text</span>',
        ):
            with self.subTest(example=example):
                result = self.check("\n" + example + "\n\n[Page](Page.md)\n")
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_markdown_around_inline_html_and_after_blocks_stays_navigation(self):
        for example in (
            "Text <!-- hidden --> [guide]",
            "<span>[guide]</span>",
            "Text\n<span>\n[guide]\n</span>",
            "[gui<!-- hidden -->de](Page.md)",
            "[Read <span>guide</span>](Page.md)",
            "[Read <!-- [hidden] --> guide][guide]",
            "<!-- hidden -->\n[guide]",
            "<script>hidden</script>\n[guide]",
            "<?instruction?>\n[guide]",
            "<!EXAMPLE>\n[guide]",
            "<![CDATA[hidden]]>\n[guide]",
            "<div>\nhidden\n</div>\n\n[guide]",
            "<span>\nhidden\n</span>\n\n[guide]",
            "> <div>\n> hidden\n[guide]",
            "- <div>\n  hidden\n[guide]",
            r"Text \<!-- [guide] -->",
            "`<!--` [guide]",
            "```html\n<!--\n```\n[guide]",
            "<!-->\n[guide]",
            "<!--->\n[guide]",
        ):
            with self.subTest(example=example):
                result = self.check("\n" + example + "\n\n[guide]: Page.md\n")
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_inline_link_and_reference_targets_stay_independent(self):
        result = self.check("[guide](Page.md)\n[guide]: Missing.md\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("broken link -> Missing.md", result.stderr)
        self.assertNotIn("orphan", result.stderr)

    def test_empty_inline_destinations_do_not_use_reference_definitions(self):
        for destination in ("", " ", " \n ", "<>", '<> "title"'):
            with self.subTest(destination=destination):
                result = self.check(f"\n[guide]({destination})\n\n[guide]: Page.md\n")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Page.md: orphan", result.stderr)
                self.assertNotIn("broken link", result.stderr)
        result = self.check("\n[Page](Page.md)\n[empty](<>)\n")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_paragraph_break_prevents_empty_inline_destination(self):
        for spacing in ("\n\n", "\n \t\n"):
            with self.subTest(spacing=spacing):
                result = self.check(f"\n[guide]({spacing})\n\n[guide]: Page.md\n")
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_backslash_runs_preserve_link_and_image_meaning(self):
        for usage, navigates in (
            (r"\[guide]", False),
            (r"\\[guide]", True),
            (r"\\\[guide]", False),
            (r"\\\\[guide]", True),
            (r"![guide]", False),
            (r"\![guide]", True),
            (r"\\![guide]", False),
            (r"\\\![guide]", True),
            (r"\\\\![guide]", False),
            (r"!\[guide]", False),
            (r"!\\[guide]", True),
        ):
            with self.subTest(usage=usage):
                result = self.check("\n" + usage + "\n\n[guide]: Page.md\n")
                if navigates:
                    self.assertEqual(result.returncode, 0, result.stderr)
                else:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("Page.md: orphan", result.stderr)
                self.assertNotIn("broken link", result.stderr)

    def test_indented_code_does_not_create_navigation(self):
        for example in (
            "    [guide]",
            "\t[guide]",
            "    first line\n\n    [guide]",
            "# Heading\n    [guide]",
            "- Text\n\n      [guide]",
            "> Text\n>\n>     [guide]",
            "-\n\n    [guide]",
            "- Text\n```\nexample\n```\n    [guide]",
        ):
            with self.subTest(example=example):
                result = self.check("\n" + example + "\n\n[guide]: Page.md\n")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Page.md: orphan", result.stderr)

    def test_indented_paragraph_and_list_links_remain_navigation(self):
        for example in (
            "   [guide]",
            "Text\n    [guide]",
            "> Text\n    [guide]",
            "- Text\n\n    [guide]",
            "- Outer\n  - Inner\n\n      [guide]",
            "1. Text\n\n     [guide]",
            "===\n    [guide]",
            "Text\n[ordinary]: Page.md\n    [guide]",
        ):
            with self.subTest(example=example):
                result = self.check("\n" + example + "\n\n[guide]: Page.md\n")
                self.assertEqual(result.returncode, 0, result.stderr)

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
