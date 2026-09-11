"""Validate documentation navigation using tiny, isolated repository fixtures."""

from pathlib import Path
import shutil
import subprocess
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

    def check(self, index, page="Page.md", content="", tracked=True):
        (self.root / "docs/README.md").write_text(STAMP + index)
        (self.root / "docs" / page).write_text(STAMP + content)
        if tracked:
            subprocess.run(["git", "add", "docs"], cwd=self.root, check=True)
        return subprocess.run(["bash", "scripts/docs-check.sh", *([] if tracked else ["--all"])],
                              cwd=self.root, capture_output=True, text=True)

    def test_reference_links_and_encoded_spaces_count_as_navigation(self):
        result = self.check("[Guide][guide]\n\n[guide]: Some%20Page.md#details\n", page="Some Page.md")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_missing_reference_target_is_reported(self):
        result = self.check("[Page](Page.md)\n[broken]: Missing.md\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("broken link -> Missing.md", result.stderr)

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
