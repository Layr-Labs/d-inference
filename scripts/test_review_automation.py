"""Check review-diff selection with synthetic patches and no model/API calls."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import types
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location(
    "threat_review", ROOT / ".github/scripts/threat-model-review.py")
REVIEW = importlib.util.module_from_spec(SPEC)
with patch.dict(sys.modules, {name: types.ModuleType(name) for name in ("anthropic", "yaml")}):
    SPEC.loader.exec_module(REVIEW)


class ReviewAutomationTests(unittest.TestCase):
    def test_pr_metadata_round_trips_multiline_text(self):
        workflow = (ROOT / ".github/workflows/codex.yml").read_text()
        step = workflow.split("      - name: Get PR metadata\n", 1)[1]
        script = textwrap.dedent(step.split("        run: |\n", 1)[1]
                                .split("\n      - name:", 1)[0])
        # A normal fenced shell example can contain the old fixed delimiter.
        body = 'Before\n```bash\ncat <<EOF\nexample\nEOF\n```\nAfter "quotes" \\ and $(literal)\n'
        metadata = dict(head={"sha": "a" * 40}, base={"sha": "b" * 40, "ref": "master"},
                        title='Review "quoted" input', body=body)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            payload = root / "pr.json"
            payload.write_text(json.dumps(metadata))
            gh = root / "gh"
            gh.write_text('#!/bin/sh\ncat "$TEST_PR_JSON"\n')
            gh.chmod(0o700)
            output = root / "output"
            subprocess.run(["bash", "-euo", "pipefail", "-c", script], check=True,
                           env={**os.environ, "PATH": f"{root}:{os.environ['PATH']}",
                                "REPO": "fixture/repository", "PR_NUMBER": "1",
                                "TEST_PR_JSON": str(payload), "GITHUB_OUTPUT": str(output)})
            values = {}
            lines = iter(output.read_text().splitlines())
            for line in lines:
                if "<<" in line and ("=" not in line or line.index("<<") < line.index("=")):
                    name, delimiter = line.split("<<", 1)
                    content = []
                    for part in lines:
                        if part == delimiter:
                            break
                        content.append(part)
                    values[name] = "\n".join(content)
                else:
                    name, value = line.split("=", 1)
                    values[name] = value
        actual = json.loads(values["metadata"]) if "metadata" in values else values
        self.assertEqual(actual["body"], body)
        self.assertEqual(actual["title"], metadata["title"])
        self.assertEqual(actual["head_sha"], metadata["head"]["sha"])
        self.assertEqual(actual["base_sha"], metadata["base"]["sha"])
        self.assertEqual(actual["base_ref"], metadata["base"]["ref"])

    def test_deleted_security_file_is_included_in_threat_review(self):
        diff = """diff --git a/coordinator/auth/check.go b/coordinator/auth/check.go
deleted file mode 100644
index 1234567..0000000
--- a/coordinator/auth/check.go
+++ /dev/null
@@ -1 +0,0 @@
-requireAuthorization()
"""
        files = REVIEW.parse_diff_by_file(diff)
        self.assertEqual(files, {"coordinator/auth/check.go": diff})
        covered, uncovered = REVIEW.build_focused_diff(files, [
            {"id": "T-fixture", "affected_files": ["coordinator/auth/*"]}])
        self.assertEqual(uncovered, [])
        self.assertIn("-requireAuthorization()", covered["coordinator/auth/check.go"][1])

    def test_patch_content_cannot_change_the_file_identity(self):
        diff = """diff --git a/coordinator/auth/check.go b/coordinator/auth/check.go
--- a/coordinator/auth/check.go
+++ b/coordinator/auth/check.go
@@ -1 +1,2 @@
-old()
+++ b/unrelated.md
+new()
diff --git a/new.go b/new.go
new file mode 100644
--- /dev/null
+++ b/new.go
@@ -0,0 +1 @@
+newFile()
"""
        files = REVIEW.parse_diff_by_file(diff)
        self.assertEqual(list(files), ["coordinator/auth/check.go", "new.go"])
        self.assertIn("+++ b/unrelated.md", files["coordinator/auth/check.go"])
        self.assertNotIn("newFile()", files["coordinator/auth/check.go"])

    def test_total_excerpt_budget_includes_truncation_markers(self):
        files = {f"file-{i}.go": "x" * 200 for i in range(4)}
        threats = [{"id": "T-fixture", "affected_files": ["*.go"]}]
        with patch.object(REVIEW, "MAX_FILE_DIFF_CHARS", 100), \
             patch.object(REVIEW, "MAX_TOTAL_DIFF_CHARS", 150):
            covered, uncovered = REVIEW.build_focused_diff(files, threats)
        self.assertEqual(list(covered), list(files))
        self.assertEqual(uncovered, [])
        self.assertLessEqual(sum(len(snippet) for _, snippet in covered.values()), 150)
        self.assertTrue(all(len(snippet) <= 100 for _, snippet in covered.values()))
        self.assertIn("budget exhausted", REVIEW.build_user_message(covered, uncovered))

    def test_metadata_only_changes_keep_destination_paths(self):
        patches = {
            "coordinator/auth/mode.go": "diff --git a/coordinator/auth/mode.go b/coordinator/auth/mode.go\nold mode 100644\nnew mode 100755\n",
            "coordinator/auth/space b/name.go": "diff --git a/coordinator/auth/space b/name.go b/coordinator/auth/space b/name.go\nold mode 100644\nnew mode 100755\n",
            "coordinator/auth/renamed.go": "diff --git a/old.go b/coordinator/auth/renamed.go\nsimilarity index 100%\nrename from old.go\nrename to coordinator/auth/renamed.go\n",
            "coordinator/auth/café.bin": 'diff --git "a/coordinator/auth/caf\\303\\251.bin" "b/coordinator/auth/caf\\303\\251.bin"\nBinary files differ\n',
        }
        parsed = REVIEW.parse_diff_by_file("".join(patches.values()))
        self.assertEqual(parsed, patches)


if __name__ == "__main__":
    unittest.main()
