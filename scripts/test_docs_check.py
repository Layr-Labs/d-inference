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
            r"[Guide \] details][guide]" + "\n\n[guide]: Page.md",
            r"[guide\]][]" + "\n\n" + r"[guide\]]: Page.md",
            r"[guide\]]" + "\n\n" + r"[guide\]]: Page.md",
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
        result = self.check("\n[unused]: Page.md\n")
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

    def test_container_definitions_resolve_links_and_check_unused_targets(self):
        for container in (
            "> {}", "- {}", "1. {}", "> - {}", "- > {}", "- - {}", "> > {}",
            "- Parent\n\n  {}", "> - Parent\n>\n>   {}",
            "- > Paragraph text\n  >\n  > {}", "> - > Paragraph text\n>   >\n>   > {}",
            "- > Paragraph text\n  > - {}",
        ):
            with self.subTest(container=container):
                result = self.check("\n" + container.format("[guide]: Page.md") + "\n\n[guide]\n")
                self.assertEqual(result.returncode, 0, result.stderr)
                result = self.check("\n[Page](Page.md)\n\n" + container.format("[unused]: Missing.md") + "\n")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("broken link -> Missing.md", result.stderr)
                self.assertNotIn("orphan", result.stderr)

    def test_definition_continuation_titles_are_not_visible_links(self):
        for definition in (
            '[guide]: Page.md\n  "title [fake](Missing.md)"',
            "[guide]: Page.md\n  'title [fake](Missing.md)'",
            '[guide]: Page.md\n  (title [fake][missing])',
            '[guide]: Page.md "title\n [fake](Missing.md)\nend"',
            '[guide]: Page.md\n    "title [fake](Missing.md)"',
            r'[guide]: Page.md "escaped \" [fake](Missing.md)"',
            '> [guide]: Page.md\n> "title [fake](Missing.md)"',
            '- [guide]: Page.md\n  "title [fake](Missing.md)"',
            '- > [guide]: Page.md\n  > "title [fake](Missing.md)"',
            '> [guide]: Page.md\n"lazy title [fake](Missing.md)"',
        ):
            with self.subTest(definition=definition):
                result = self.check("\n" + definition + "\n\n[guide]\n")
                self.assertEqual(result.returncode, 0, result.stderr)
        result = self.check('\n[unused]: https://example.com\n  "title [fake](Page.md)"\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Page.md: orphan", result.stderr)
        self.assertNotIn("broken link", result.stderr)

    def test_definition_labels_and_destinations_can_continue(self):
        for definition, usage in (
            ("[guide]:\n  Page.md", "[guide]"),
            ("[guide]:\n    Page.md", "[guide]"),
            ('[guide]:\n  <Page.md>\n  "title"', "[guide]"),
            ("[some\n guide]: Page.md", "[some guide]"),
            ("> [some\n> guide]:\n> Page.md", "[some guide]"),
            ("- [guide]:\n  Page.md", "[guide]"),
            ("> [guide]:\nPage.md", "[guide]"),
            ("- [guide]:\nPage.md", "[guide]"),
        ):
            with self.subTest(definition=definition):
                result = self.check("\n" + definition + "\n\n" + usage + "\n")
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_definition_shaped_paragraph_text_does_not_define_a_link(self):
        for paragraph in (
            "Paragraph text\n[guide]: Page.md",
            "> Paragraph text\n> [guide]: Page.md",
            "> Paragraph text\n[guide]: Page.md",
            "- Paragraph text\n  [guide]: Page.md",
            "- Paragraph text\n[guide]: Page.md",
            "- > Paragraph text\n  > [guide]: Page.md",
            "> - > Paragraph text\n>   > [guide]: Page.md",
            "[incomplete\n[guide]: Page.md",
        ):
            with self.subTest(paragraph=paragraph):
                result = self.check("\n" + paragraph + "\n\n[guide]\n")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Page.md: orphan", result.stderr)
                self.assertNotIn("broken link", result.stderr)
        result = self.check("\n[Page](Page.md)\n[not-a-definition]: Missing.md\n")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_definition_blocks_stop_before_visible_paragraph_content(self):
        for block in (
            '[unused]: https://example.com\n\n"visible [Page](Page.md)"',
            '[unused]: https://example.com\n"visible [Page](Page.md)" suffix',
            '[unused]: https://example.com\n"unterminated [Page](Page.md)',
            '[unused]: https://example.com\n- "visible [Page](Page.md)"',
            '> [unused]: https://example.com\n> > "visible [Page](Page.md)"',
            '[unused]: https://example.com\n[Page](Page.md)',
        ):
            with self.subTest(block=block):
                result = self.check("\n" + block + "\n")
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_malformed_definition_suffixes_remain_paragraph_text(self):
        for definition in (
            "[guide]: Page.md suffix",
            '[guide]: Page.md "title" suffix',
            '[guide]: Page.md "unterminated',
            '[guide]: Page.md "title\n\nend"',
            '[guide]: Page.md "title\n# Heading"',
            "[guide]:\n\nPage.md",
        ):
            with self.subTest(definition=definition):
                result = self.check("\n" + definition + "\n\n[guide]\n")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Page.md: orphan", result.stderr)
                self.assertNotIn("broken link", result.stderr)

    def test_code_examples_do_not_create_navigation_edges(self):
        examples = (
            "```markdown\n[Page](Page.md)\n```\n",
            "~~~markdown\n[Page][guide]\n~~~\n[guide]: Page.md\n",
            "````markdown\n```\n[Page](Page.md)\n````\n",
            "`[guide]`\n\n[guide]: Page.md\n",
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

    def test_fences_in_containers_preserve_following_navigation_and_errors(self):
        for block in (
            "- ```\n  [hidden](Hidden.md)\n  ```",
            "1. ```go\n   [hidden](Hidden.md)\n   ```",
            "> ```\n> [hidden](Hidden.md)\n> ```",
            "> - ```\n>   [hidden](Hidden.md)\n>   ```",
            "- - ```\n    [hidden](Hidden.md)\n    ```",
            "- > ```\n  > [hidden](Hidden.md)\n  > ```",
            "- item\n\n  ```\n  [hidden](Hidden.md)\n  ```",
            "- ````\n  ```\n  [hidden](Hidden.md)\n  ````",
            "- ~~~ bad`tick\n  [hidden](Hidden.md)\n  ~~~",
            "- ```\n\n  [hidden](Hidden.md)\n  ```",
            "  > ```\n> [hidden](Hidden.md)\n> ```",
        ):
            for missing in (False, True):
                with self.subTest(block=block, missing=missing):
                    after = "[Page](Page.md)\n" + ("[Broken](Missing.md)\n" if missing else "")
                    result = self.check("\n" + block + "\n\n" + after)
                    self.assertNotIn("orphan", result.stderr)
                    self.assertNotIn("broken link -> Hidden.md", result.stderr)
                    if missing:
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn("broken link -> Missing.md", result.stderr)
                    else:
                        self.assertEqual(result.returncode, 0, result.stderr)

    def test_fences_end_with_their_containers_and_keep_content_literal(self):
        for example in (
            "- ```\n  [hidden](Hidden.md)\n\n[Page](Page.md)",
            "> ```\n> [hidden](Hidden.md)\n\n[Page](Page.md)",
            "> - ```\n>   [hidden](Hidden.md)\n>\n> [Page](Page.md)",
            "- ```\n  [hidden](Hidden.md)\n- [Page](Page.md)",
            "- > ```\n  > [hidden](Hidden.md)\n\n[Page](Page.md)",
            "- item\n\n  > ```\n  > [hidden](Hidden.md)\n> [Page](Page.md)",
            "> - item\n>\n>   > ```\n>   > [hidden](Hidden.md)\n> > [Page](Page.md)",
            "- item\n\n  > ```\n  > first\n  > ```\n  > ```\n  > [hidden](Hidden.md)\n> [Page](Page.md)",
            "```\n> ```\n[hidden](Hidden.md)\n```\n\n[Page](Page.md)",
            "> ```\n> > ```\n> [hidden](Hidden.md)\n> ```\n\n[Page](Page.md)",
            "- ```\n  - ```\n  [hidden](Hidden.md)\n  ```\n\n[Page](Page.md)",
            "- ``` bad`tick\n  [Page](Page.md)",
        ):
            with self.subTest(example=example):
                result = self.check("\n" + example + "\n")
                self.assertEqual(result.returncode, 0, result.stderr)

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

    def test_nested_html_blocks_hide_links_and_missing_targets(self):
        for prefix, continuation in (
            ("- > ", "  > "), ("> - > ", ">   > "),
            ("- > - ", "  >   "), ("> - > - ", ">   >   "),
        ):
            for opening, closing in (
                ("<!--", "-->"), ("<script>", "</script>"),
                ("<?instruction", "?>"), ("<!DOCTYPE", ">"),
                ("<![CDATA[", "]]>"), ("<div>", "</div>"),
                ("<custom>", "</custom>"),
            ):
                with self.subTest(prefix=prefix, opening=opening):
                    block = f"{prefix}{opening}\n{continuation}[hidden](Page.md)\n{continuation}{closing}\n"
                    result = self.check("\n" + block)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("Page.md: orphan", result.stderr)
                    self.assertNotIn("broken link", result.stderr)
                    result = self.check("\n[Page](Page.md)\n\n" + block.replace("Page.md", "Missing.md"))
                    self.assertEqual(result.returncode, 0, result.stderr)
        result = self.check("\n- > <!--\n  > [hidden](Page.md)\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Page.md: orphan", result.stderr)

    def test_nested_html_continuations_keep_markdown_opaque(self):
        for body in (
            "- > <!--\n  >\n  > [guide]: Page.md\n  > -->",
            "> - > <!--\n>   > ```\n>   > [guide]: Page.md\n>   > -->",
            "- > <script>\n  > # heading\n  > [guide]: Page.md\n  > </script>",
        ):
            with self.subTest(body=body):
                result = self.check("\n" + body + "\n\n[guide]\n")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Page.md: orphan", result.stderr)
                self.assertNotIn("broken link", result.stderr)

    def test_nested_indented_code_hides_links_and_definitions(self):
        for prefix, continuation in (
            ("- > ", "  > "), ("> - > ", ">   > "),
            ("- > - ", "  >   "), ("> - > - ", ">   >   "),
        ):
            for content in ("[hidden](Page.md)", "> [hidden](Page.md)", "- [hidden](Page.md)"):
                with self.subTest(prefix=prefix, content=content):
                    block = f"{prefix}    {content}\n{continuation}\n{continuation}    [guide]: Page.md\n"
                    result = self.check("\n" + block + "\n[guide]\n")
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("Page.md: orphan", result.stderr)
                    self.assertNotIn("broken link", result.stderr)
                    result = self.check("\n[Page](Page.md)\n\n" + block.replace("Page.md", "Missing.md"))
                    self.assertEqual(result.returncode, 0, result.stderr)

    def test_nested_paragraph_indentation_and_inline_html_remain_visible(self):
        for prefix, continuation in (
            ("- > ", "  > "), ("> - > ", ">   > "),
            ("- > - ", "  >   "), ("> - > - ", ">   >   "),
        ):
            for body in (
                f"{prefix}Paragraph text\n{continuation}    [Page](Page.md)",
                f"{prefix}   [Page](Page.md)",
                f"{prefix}Text <span>[Page](Page.md)</span>",
                f"{prefix}Text\n{continuation}<span>\n{continuation}[Page](Page.md)\n{continuation}</span>",
            ):
                with self.subTest(body=body):
                    result = self.check("\n" + body + "\n")
                    self.assertEqual(result.returncode, 0, result.stderr)

    def test_nested_literal_blocks_end_before_visible_navigation(self):
        for body in (
            "- > <!--\n  > [hidden](Missing.md)\n  > -->\n  > [Page](Page.md)",
            "> - > <script>\n>   > [hidden](Missing.md)\n>   > </script>\n>   > [Page](Page.md)",
            "- > <div>\n  > [hidden](Missing.md)\n  > </div>\n\n[Page](Page.md)",
            "- > <div>\n  > [hidden](Missing.md)\n  >\n  > [Page](Page.md)",
            "- >     [hidden](Missing.md)\n  >\n  > [Page](Page.md)",
            "> - >     [hidden](Missing.md)\n\n[Page](Page.md)",
            "- > -     [hidden](Missing.md)\n  >   [Page](Page.md)",
            "- >     [hidden](Missing.md)\n- [Page](Page.md)",
            "- >     [hidden](Missing.md)\n  > [guide]\n\n[guide]: Page.md",
        ):
            with self.subTest(body=body):
                result = self.check("\n" + body + "\n")
                self.assertEqual(result.returncode, 0, result.stderr)

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
        result = self.check("[guide](Page.md)\n\n[guide]: Missing.md\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("broken link -> Missing.md", result.stderr)
        self.assertNotIn("orphan", result.stderr)

    def test_link_titles_do_not_create_navigation(self):
        (self.root / "docs/Home.md").write_text(STAMP)
        for usage in (
            '[Home](Home.md "title ) [guide]")',
            "[Home](Home.md 'title ) [guide]')",
            r'[Home](Home.md "title \" ) [guide]")',
            '[Home](Home.md "title )\n[guide]")',
            '[Home](<Home.md> "title ) [guide]")',
            r'[Home](Home.md (title \) [guide]))',
            '[Home](Home.md)\n![diagram](Home.md "title ) [guide]")',
        ):
            with self.subTest(usage=usage):
                result = self.check("\n" + usage + "\n\n[guide]: Page.md\n")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Page.md: orphan", result.stderr)
                self.assertNotIn("Home.md: orphan", result.stderr)
                self.assertNotIn("broken link", result.stderr)

    def test_title_delimiters_preserve_real_links_and_missing_targets(self):
        (self.root / "docs/Home.md").write_text(STAMP)
        for usage in (
            '[Home](Home.md "title ) [unused]") [guide]',
            "[Home](Home.md 'title ) [unused]')[guide]",
            '[Home](Home.md)\n[bad](Home.md "unterminated ) [guide]',
            '[Home](Home.md)\n[bad](Home.md "title )\n\n[guide]\")',
        ):
            with self.subTest(usage=usage):
                result = self.check("\n" + usage + "\n\n[guide]: Page.md\n")
                self.assertEqual(result.returncode, 0, result.stderr)
        result = self.check('\n[Home](Home.md)\n[Page](Page.md)\n[bad](Missing.md "title ) [guide]")\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("broken link -> Missing.md", result.stderr)
        self.assertNotIn("orphan", result.stderr)

    def test_parenthesized_destinations_preserve_navigation(self):
        (self.root / "docs/Image(old).svg").write_text("<svg/>")
        for usage, target in (
            ("[guide](Page(old).md)", "Page(old).md"),
            ("[guide](<Page(old).md>)", "Page(old).md"),
            (r"[guide](Page\(old\).md)", "Page(old).md"),
            ('[guide](Page(old).md "title ) [fake]")', "Page(old).md"),
            ("[guide](Page(one(two)).md)", "Page(one(two)).md"),
            ("[guide](Page" + "(" * 16 + "old" + ")" * 16 + ".md)",
             "Page" + "(" * 16 + "old" + ")" * 16 + ".md"),
            ("[![plot](Image(old).svg)](Page(old).md)", "Page(old).md"),
        ):
            with self.subTest(usage=usage):
                result = self.check("\n" + usage + "\n", page=target)
                # Each case owns one Markdown page; do not let a prior target
                # become an unrelated orphan when the filename changes.
                (self.root / "docs" / target).unlink()
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_parenthesized_destinations_check_complete_missing_targets(self):
        for usage, target in (
            ("[missing](Missing(old).md)", "Missing(old).md"),
            ("[missing](<Missing(old).md>)", "Missing(old).md"),
            (r"[missing](Missing\(old\).md)", "Missing(old).md"),
            ('[missing](Missing(one(two)).md "title")', "Missing(one(two)).md"),
            ("![plot](Missing(old).svg)", "Missing(old).svg"),
            ("[missing](Missing(old).md))", "Missing(old).md"),
        ):
            with self.subTest(usage=usage):
                result = self.check("\n[Page](Page.md)\n" + usage + "\n")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"broken link -> {target}", result.stderr)
                self.assertNotIn("orphan", result.stderr)

    def test_inline_destination_nesting_matches_rendered_boundary(self):
        for depth, renders in ((31, True), (32, True), (33, False)):
            target = "Page" + "(" * depth + "old" + ")" * depth + ".md"
            with self.subTest(depth=depth, target="present"):
                result = self.check(f"\n[guide]({target})\n", page=target)
                (self.root / "docs" / target).unlink()
                if renders:
                    self.assertEqual(result.returncode, 0, result.stderr)
                else:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(f"{target}: orphan", result.stderr)
                    self.assertNotIn("broken link", result.stderr)

            with self.subTest(depth=depth, target="missing"):
                missing = target.replace("Page", "Missing", 1)
                result = self.check(f"\n[Page](Page.md)\n[missing]({missing})\n")
                (self.root / "docs/Page.md").unlink()
                if renders:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(f"broken link -> {missing}", result.stderr)
                    self.assertNotIn("orphan", result.stderr)
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)

    def test_destination_nesting_limit_preserves_literal_and_reference_forms(self):
        target = "Page" + "(" * 33 + "old" + ")" * 33 + ".md"
        escaped = target.replace("(", r"\(").replace(")", r"\)")
        for usage in (
            f"[guide](<{target}>)",
            f"[guide]({escaped})",
            f"[guide]\n\n[guide]: {target}",
        ):
            with self.subTest(usage=usage):
                result = self.check("\n" + usage + "\n", page=target)
                (self.root / "docs" / target).unlink()
                self.assertEqual(result.returncode, 0, result.stderr)

                missing = usage.replace("Page", "Missing", 1)
                result = self.check("\n[Page](Page.md)\n" + missing + "\n")
                (self.root / "docs/Page.md").unlink()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"broken link -> {target.replace('Page', 'Missing', 1)}", result.stderr)
                self.assertNotIn("orphan", result.stderr)

        missing = target.replace("Page", "Missing", 1)
        result = self.check(f"\n[Page](Page.md)\n\n[unused]: {missing}\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f"broken link -> {missing}", result.stderr)
        self.assertNotIn("orphan", result.stderr)

    def test_unbalanced_destinations_do_not_invent_links(self):
        for usage in (
            "[fake](Missing(open.md)",
            "[fake](Missing(open).md",
            "[fake](Missing(open) suffix)",
            r"[fake](Missing(open\).md)",
            "[fake](<Missing(old).md)",
        ):
            with self.subTest(usage=usage):
                result = self.check("\n[Page](Page.md)\n" + usage + "\n")
                self.assertEqual(result.returncode, 0, result.stderr)

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
        result = self.check("[Page](Page.md)\n\n[broken]: Missing.md\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("broken link -> Missing.md", result.stderr)

    def test_broken_inline_image_target_is_still_checked(self):
        result = self.check("[Page](Page.md)\n![diagram](Missing.svg)\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("broken link -> Missing.svg", result.stderr)

    def test_images_do_not_create_navigation_edges(self):
        for usage in ("![diagram][guide]", "![guide][]", "![guide]", "![diagram](Page.md)"):
            with self.subTest(usage=usage):
                result = self.check(usage + "\n\n[guide]: Page.md\n")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Page.md: orphan", result.stderr)
                self.assertNotIn("broken link", result.stderr)

    def test_broken_reference_images_are_still_checked(self):
        result = self.check("[Page](Page.md)\n![diagram][image]\n\n[image]: Missing.svg\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("broken link -> Missing.svg", result.stderr)
        self.assertNotIn("orphan", result.stderr)

    def test_escaped_bang_before_reference_is_a_link(self):
        result = self.check(r"\![guide]" + "\n\n[guide]: Page.md\n")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_clickable_images_preserve_outer_navigation(self):
        (self.root / "docs/asset.svg").write_text("<svg/>")
        for usage in (
            "[![diagram](asset.svg)](Page.md)",
            "[![diagram\n label](asset.svg)](Page.md)",
            "[![diagram][image]][guide]\n\n[image]: asset.svg\n[guide]: Page.md",
            "[![image][]][guide]\n\n[image]: asset.svg\n[guide]: Page.md",
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

    def test_reachability_rejects_self_links_and_disconnected_cycles(self):
        for pages in (
            {"Page.md": "[Self](Page.md)\n"},
            {"Page.md": "[Other](Other.md)\n", "Other.md": "[Back](Page.md)\n"},
        ):
            with self.subTest(pages=pages):
                for filename, content in pages.items():
                    (self.root / "docs" / filename).write_text(STAMP + content)
                result = self.check("", content=pages["Page.md"])
                self.assertNotEqual(result.returncode, 0)
                for filename in pages:
                    self.assertIn(f"docs/{filename}: orphan", result.stderr)
                self.assertNotIn("broken link", result.stderr)

    def test_reachability_follows_transitive_navigation_and_cycles(self):
        # Reverse alphabetical traversal makes one pass over git's file list
        # insufficient; the return edge also requires cycle termination.
        for filename, target in (("Z.md", "M.md"), ("M.md", "A.md"), ("A.md", "Page.md")):
            (self.root / "docs" / filename).write_text(STAMP + f"[Next]({target})\n")
        result = self.check("[Start](Z.md)\n", content="[Back](M.md)\n")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_reachability_preserves_documentation_entry_points(self):
        for entry in ("README.md", "CONTRIBUTING.md", "AGENTS.md", "docs/AGENTS.md"):
            with self.subTest(entry=entry):
                target = "Page.md" if entry.startswith("docs/") else "docs/Page.md"
                path = self.root / entry
                path.write_text(STAMP + f"[Page]({target})\n")
                try:
                    result = self.check("")
                    self.assertEqual(result.returncode, 0, result.stderr)
                finally:
                    path.unlink()
                    subprocess.run(["git", "add", "-u"], cwd=self.root, check=True)

    def test_reachability_requires_a_route_to_nested_indexes(self):
        (self.root / "docs/guide").mkdir()
        (self.root / "docs/guide/README.md").write_text(STAMP + "[Page](../Page.md)\n")
        for index, reachable in (("", False), ("[Guide](guide/README.md)\n", True)):
            with self.subTest(reachable=reachable):
                result = self.check(index, content="[Self](Page.md)\n")
                if reachable:
                    self.assertEqual(result.returncode, 0, result.stderr)
                else:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("docs/Page.md: orphan", result.stderr)
                    self.assertIn("docs/guide/README.md: orphan", result.stderr)
                    self.assertNotIn("broken link", result.stderr)

    def test_reachability_private_pages_are_exempt_without_becoming_roots(self):
        (self.root / "docs/.private").mkdir()
        (self.root / "docs/.private/notes.md").write_text("[Page](../Page.md)\n")
        for index, reachable in (("", False), ("[Notes](.private/notes.md)\n", True)):
            with self.subTest(reachable=reachable):
                result = self.check(index)
                if reachable:
                    self.assertEqual(result.returncode, 0, result.stderr)
                else:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("docs/Page.md: orphan", result.stderr)
                    self.assertNotIn("docs/.private/notes.md:", result.stderr)

    def test_reachability_uses_only_rendered_navigation_edges(self):
        (self.root / "docs/Other.md").write_text(STAMP + "[Back](Page.md)\n")
        (self.root / "docs/asset.svg").write_text("<svg/>")
        for index, reachable in (
            ("![Page](Page.md)\n", False),
            ("[unused]: Page.md\n", False),
            ("[Guide][page]\n\n[page]: Page.md\n", True),
            ("[![Diagram](asset.svg)](Page.md)\n", True),
        ):
            with self.subTest(index=index):
                result = self.check("\n" + index, content="[Other](Other.md)\n")
                if reachable:
                    self.assertEqual(result.returncode, 0, result.stderr)
                else:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("docs/Page.md: orphan", result.stderr)
                    self.assertIn("docs/Other.md: orphan", result.stderr)
                self.assertNotIn("broken link", result.stderr)

    def test_reachability_preserves_normalized_paths_and_untracked_mode(self):
        (self.root / "docs/Z Guides").mkdir()
        (self.root / "docs/Z Guides/README.md").write_text(
            STAMP + "[Next](../A%20Page.md?view=full#topic)\n")
        (self.root / "docs/A Page.md").write_text(STAMP + "[Next](./Page.md)\n")
        for tracked in (False, True):
            with self.subTest(tracked=tracked):
                result = self.check("[Start](Z%20Guides/README.md)\n",
                                    content="[Back](/docs/Z%20Guides/README.md#back)\n", tracked=tracked)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_explicit_file_mode_still_skips_graph_reachability(self):
        (self.root / "docs/Page.md").write_text(STAMP + "[Self](Page.md)\n")
        result = subprocess.run(["bash", "scripts/docs-check.sh", "docs/Page.md"],
                                cwd=self.root, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)

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
