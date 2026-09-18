#!/usr/bin/env python3
"""Exercise frozen source links with real, isolated Git history."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


CHECKER = Path(__file__).with_name("docs-check.sh")


class HistoricalSourceLinkTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="docs-historical-links-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "repository"
        self.root.mkdir()
        self.env = {
            key: value for key, value in os.environ.items()
            if not key.startswith("GIT_")
        }
        self.env.update({
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_TERMINAL_PROMPT": "0",
        })
        self.git("init", "-q")
        self.git("config", "user.name", "Docs fixture")
        self.git("config", "user.email", "docs-fixture@example.invalid")
        self.before_source = self.commit("Before source exists")
        for name in (
            "coordinator/legacy/example.go",
            "coordinator/legacy/[literal].go",
            "l.go",
            "provider-swift/Source Files/Legacy.swift",
            "provider-swift/README.md",
            "docs/retired.md",
            "assets/retired.bin",
        ):
            self.write(name, "fixture\n")
        self.source_commit = self.commit("Original source paths")
        for old, new in (
            ("coordinator/legacy", "coordinator/current"),
            ("provider-swift/Source Files", "provider-swift/Current Sources"),
            ("provider-swift/README.md", "provider-swift/guide.md"),
            ("docs/retired.md", "docs/current.md"),
            ("assets/retired.bin", "assets/current.bin"),
        ):
            (self.root / old).rename(self.root / new)
        self.rename_commit = self.commit("Move source and documentation")
        self.install_checker(self.root)

    def git(self, *arguments, root=None):
        result = subprocess.run(
            ["git", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
             "-C", str(root or self.root), *arguments],
            env=self.env, text=True, capture_output=True, timeout=15, check=True,
        )
        return result.stdout.strip()

    def commit(self, message):
        self.git("add", "--all")
        self.git("commit", "-q", "--allow-empty", "-m", message)
        return self.git("rev-parse", "HEAD")

    def write(self, name, text, root=None):
        path = (root or self.root) / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def install_checker(self, root):
        (root / "scripts").mkdir(exist_ok=True)
        shutil.copyfile(CHECKER, root / "scripts/docs-check.sh")

    def report(self, target, *, directory="reports", stamp=None, header=None,
               root=None, reference=False):
        name = f"docs/{directory}/record.md"
        if header is None:
            header = "> Last updated: 2026-09-13 · commit `{}`".format(
                self.source_commit if stamp is None else stamp
            )
        link = f"[source][entry]\n\n[entry]: {target}" if reference else f"[source]({target})"
        self.write(name, f"# Record\n\n{header}\n\n{link}\n", root=root)
        return name

    def check(self, name, *, root=None):
        return subprocess.run(
            ["bash", "scripts/docs-check.sh", name], cwd=root or self.root,
            env=self.env, text=True, capture_output=True, timeout=15,
        )

    def assert_passes(self, name, *, root=None):
        result = self.check(name, root=root)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def assert_broken(self, name, *, root=None):
        result = self.check(name, root=root)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("broken link", result.stderr)
        return result

    def test_frozen_source_survives_rename_in_each_record_directory(self):
        for directory in ("reports", "releases", "design"):
            for stamp in (self.source_commit, self.source_commit[:9]):
                with self.subTest(directory=directory, stamp=stamp):
                    self.assert_passes(self.report(
                        "../../coordinator/legacy/example.go", directory=directory,
                        stamp=stamp,
                    ))

    def test_directory_and_reference_links_use_the_stamped_tree(self):
        for target, reference in (
            ("../../coordinator/legacy/", False),
            ("../../coordinator/legacy/example.go", True),
        ):
            with self.subTest(target=target, reference=reference):
                self.assert_passes(self.report(target, reference=reference))

    def test_normalized_paths_spaces_queries_and_fragments(self):
        for target in (
            "../../coordinator/unused/../legacy/./example.go#L1",
            "/coordinator/legacy/example.go?raw=1#L1",
            "../../provider-swift/Source%20Files/Legacy.swift",
        ):
            with self.subTest(target=target):
                self.assert_passes(self.report(target))

    def test_root_escape_is_not_clamped_to_a_real_historical_path(self):
        self.assert_broken(self.report("../../../coordinator/legacy/example.go"))

    def test_path_components_are_literal_even_when_a_glob_would_match(self):
        self.assert_passes(self.report("../../coordinator/legacy/[literal].go"))

    def test_missing_historical_target_fails(self):
        self.assert_broken(self.report("../../coordinator/legacy/missing.go"))

    def test_only_the_exact_stamped_commit_supplies_the_target(self):
        for stamp in (self.before_source, self.rename_commit):
            with self.subTest(stamp=stamp):
                self.assert_broken(self.report(
                    "../../coordinator/legacy/example.go", stamp=stamp,
                ))

    def test_current_documents_do_not_use_history(self):
        self.assert_broken(self.report(
            "../../coordinator/legacy/example.go", directory="architecture",
        ))

    def test_a_frozen_directory_prefix_does_not_hide_a_current_document(self):
        name = self.report("../../coordinator/legacy/example.go", directory="architecture")
        (self.root / "docs/reports").mkdir()
        self.assert_broken(name.replace("docs/architecture/", "docs/reports/../architecture/"))

    def test_missing_documentation_links_remain_broken(self):
        # A report must retain working documentation navigation. Historical
        # source fallback never rescues a moved docs page or a source README.
        for target in ("../retired.md", "../../provider-swift/README.md"):
            with self.subTest(target=target):
                self.assert_broken(self.report(target))

    def test_paths_outside_source_roots_do_not_use_history(self):
        self.assert_broken(self.report("../../assets/retired.bin"))

    def test_missing_and_invalid_stamps_do_not_rescue_a_source_link(self):
        for header in ("", "> Last updated: 2026-09-13 · commit `not-a-sha`"):
            with self.subTest(header=header):
                result = self.assert_broken(self.report(
                    "../../coordinator/legacy/example.go", header=header,
                ))
                self.assertIn("missing freshness stamp", result.stderr)

    def test_stamp_outside_the_first_twelve_lines_is_not_used(self):
        name = self.report("../../coordinator/legacy/example.go")
        path = self.root / name
        path.write_text("\n" * 12 + path.read_text(encoding="utf-8"), encoding="utf-8")
        self.assert_broken(name)

    def test_unknown_and_non_commit_stamps_fail_actionably(self):
        blob = self.git("rev-parse", f"{self.source_commit}:coordinator/legacy/example.go")
        for stamp in ("f" * 40, blob):
            with self.subTest(stamp=stamp):
                result = self.assert_broken(self.report(
                    "../../coordinator/legacy/example.go", stamp=stamp,
                ))
                self.assertIn("cannot resolve historical commit", result.stderr)

    def test_shallow_checkout_requires_the_stamped_commit_object(self):
        shallow = Path(self.temporary.name) / "shallow"
        self.git("clone", "-q", "--depth=1", self.root.as_uri(), str(shallow))
        self.assertEqual(self.git("rev-parse", "--is-shallow-repository", root=shallow), "true")
        self.install_checker(shallow)
        name = self.report("../../coordinator/legacy/example.go", root=shallow)
        result = self.assert_broken(name, root=shallow)
        self.assertIn("cannot resolve historical commit", result.stderr)
        self.assertIn("fetch", result.stderr)
        self.git("fetch", "-q", "--unshallow", "origin", root=shallow)
        self.assert_passes(name, root=shallow)

    def test_existing_worktree_links_keep_their_original_behavior(self):
        # Existing targets need no historical lookup, even in a shallow clone
        # or a current document whose syntactically valid SHA is unavailable.
        for directory in ("reports", "architecture"):
            with self.subTest(directory=directory):
                self.assert_passes(self.report(
                    "../../coordinator/current/example.go", directory=directory,
                    stamp="f" * 40,
                ))


if __name__ == "__main__":
    unittest.main()
