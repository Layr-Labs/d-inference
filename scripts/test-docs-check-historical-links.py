#!/usr/bin/env python3
"""Exercise frozen source links with real, isolated Git history."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


CHECKER = Path(__file__).with_name("docs-check.sh")
GUIDANCE = CHECKER.parent.parent / "docs/developer/historical-references.md"


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
        for directory in ("reports", "releases", "design"):
            name = self.report(
                "../../coordinator/legacy/example.go", directory=directory,
                header=self.legacy_stamp(self.source_commit),
            )
            path = self.root / name
            path.write_text(path.read_text() + "\n"
                            "[directory](../../coordinator/legacy/)\n"
                            "[literal](../../coordinator/legacy/[literal].go)\n"
                            "[spaces](../../provider-swift/Source%20Files/Legacy.swift)\n")
            self.report("../../coordinator/legacy/example.go", directory=directory,
                        filename="dated.md")
        self.report("../../coordinator/legacy/example.go", directory="architecture")
        for filename, target in (("documentation.md", "../retired.md"),
                                 ("markdown.md", "../../provider-swift/README.md"),
                                 ("asset.md", "../../assets/retired.bin")):
            self.report(target, filename=filename)
        self.commit("Record source references")
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
        shutil.copyfile(CHECKER.with_name("docs-historical-source.py"),
                        root / "scripts/docs-historical-source.py")

    def legacy_stamp(self, commit):
        return f"> Last updated: 2026-09-13 · commit `{commit}`"

    def report(self, target, *, directory="reports", header=None,
               root=None, reference=False, filename="record.md"):
        name = f"docs/{directory}/{filename}"
        if header is None:
            header = "> Last updated: 2026-09-13"
        link = f"[source][entry]\n\n[entry]: {target}" if reference else f"[source]({target})"
        self.write(name, f"# Record\n\n{header}\n\n{link}\n", root=root)
        return name

    def recorded_legacy_stamp(self, stamp):
        self.report("../../coordinator/legacy/example.go", header=self.legacy_stamp(stamp))
        self.commit("Record legacy verification provenance")
        return self.report("../../coordinator/legacy/example.go")

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
            for filename in ("record.md", "dated.md"):
                with self.subTest(directory=directory, filename=filename):
                    self.assert_passes(self.report(
                        "../../coordinator/legacy/example.go", directory=directory,
                        filename=filename,
                    ))

    def test_directory_and_reference_links_use_the_legacy_tree(self):
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

    def test_only_the_exact_legacy_commit_supplies_the_target(self):
        for stamp in (self.before_source, self.rename_commit):
            with self.subTest(stamp=stamp):
                self.assert_broken(self.recorded_legacy_stamp(stamp))

    def test_current_documents_do_not_use_history(self):
        self.assert_broken(self.report(
            "../../coordinator/legacy/example.go", directory="architecture",
        ))

    def test_a_frozen_directory_prefix_does_not_hide_a_current_document(self):
        name = self.report("../../coordinator/legacy/example.go", directory="architecture")
        self.assert_broken(name.replace("docs/architecture/", "docs/reports/../architecture/"))

    def test_missing_documentation_links_remain_broken(self):
        # A report must retain working documentation navigation. Historical
        # source fallback never rescues a moved docs page or a source README.
        for target in ("../retired.md", "../../provider-swift/README.md"):
            with self.subTest(target=target):
                filename = "documentation.md" if target == "../retired.md" else "markdown.md"
                self.assert_broken(self.report(target, filename=filename))

    def test_paths_outside_source_roots_do_not_use_history(self):
        self.assert_broken(self.report("../../assets/retired.bin", filename="asset.md"))

    def test_exclusion_fixtures_have_valid_committed_provenance(self):
        # Without the shell exclusions these must pass, so each exclusion test
        # fails for its policy rather than an unrelated missing history entry.
        for name, path, target in (
            ("docs/architecture/record.md", "coordinator/legacy/example.go",
             "../../coordinator/legacy/example.go"),
            ("docs/reports/documentation.md", "docs/retired.md", "../retired.md"),
            ("docs/reports/markdown.md", "provider-swift/README.md", "../../provider-swift/README.md"),
            ("docs/reports/asset.md", "assets/retired.bin", "../../assets/retired.bin"),
        ):
            with self.subTest(name=name):
                result = subprocess.run(
                    ["python3", "scripts/docs-historical-source.py", name, path, target],
                    cwd=self.root, env=self.env, text=True, capture_output=True, timeout=15,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_missing_and_invalid_stamps_do_not_rescue_a_source_link(self):
        for header in ("", "> Last updated: 2026-09-13 · commit `not-a-sha`",
                       self.legacy_stamp(self.source_commit),
                       "> Last updated: 2026-09-13 extra"):
            with self.subTest(header=header):
                result = self.check(self.report(
                    "../../coordinator/legacy/example.go", header=header,
                ))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("missing date-only freshness stamp", result.stderr)

    def test_stamp_outside_the_first_twelve_lines_is_not_used(self):
        name = self.report("../../coordinator/legacy/example.go")
        path = self.root / name
        path.write_text("\n" * 12 + path.read_text(encoding="utf-8"), encoding="utf-8")
        result = self.check(name)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing date-only freshness stamp", result.stderr)

    def test_unknown_non_commit_and_malformed_legacy_stamps_fail_actionably(self):
        blob = self.git("rev-parse", f"{self.source_commit}:coordinator/legacy/example.go")
        for stamp in ("f" * 40, blob, "not-a-sha"):
            with self.subTest(stamp=stamp):
                result = self.assert_broken(self.recorded_legacy_stamp(stamp))
                self.assertIn("cannot resolve historical commit", result.stderr)

    def test_shallow_checkout_requires_history_even_when_source_commit_is_present(self):
        shallow = Path(self.temporary.name) / "shallow"
        self.git("clone", "-q", "--depth=1", self.root.as_uri(), str(shallow))
        self.git("fetch", "-q", "--depth=1", "origin", self.source_commit, root=shallow)
        self.assertEqual(self.git("cat-file", "-t", self.source_commit, root=shallow), "commit")
        self.assertEqual(self.git("rev-parse", "--is-shallow-repository", root=shallow), "true")
        self.install_checker(shallow)
        name = self.report("../../coordinator/legacy/example.go", root=shallow)
        result = self.assert_broken(name, root=shallow)
        self.assertIn("requires complete Git history", result.stderr)
        self.assertIn("fetch", result.stderr)
        self.git("fetch", "-q", "--unshallow", "origin", root=shallow)
        self.assert_passes(name, root=shallow)

    def test_existing_worktree_links_keep_their_original_behavior(self):
        # Existing targets need no historical lookup, even in a shallow clone
        # or an untracked current document.
        for directory in ("reports", "architecture"):
            with self.subTest(directory=directory):
                self.assert_passes(self.report(
                    "../../coordinator/current/example.go", directory=directory,
                ))

    def test_short_legacy_commit_is_recovered_after_migration_and_record_rename(self):
        self.recorded_legacy_stamp(self.source_commit[:9])
        self.commit("Migrate to date-only stamps")
        (self.root / "docs/reports/record.md").rename(self.root / "docs/reports/renamed.md")
        self.commit("Rename frozen record")
        self.assert_passes("docs/reports/renamed.md")

    def test_date_only_link_provenance_survives_later_edits_and_record_rename(self):
        name = "docs/reports/dated.md"
        path = self.root / name
        path.write_text(path.read_text() + "\nUnrelated later note.\n")
        self.commit("Unrelated record update after source removal")
        path.rename(path.with_name("renamed.md"))
        self.commit("Rename date-only record")
        self.assert_passes("docs/reports/renamed.md")

    def test_adjusted_relative_links_preserve_provenance_across_record_depths(self):
        self.git("checkout", "--detach", self.source_commit)
        for filename, reference, header in (
            ("legacy.md", False, self.legacy_stamp(self.source_commit)),
            ("dated.md", True, None),
        ):
            name = self.report("../../../coordinator/legacy/example.go", directory="reports/deep",
                               filename=filename, reference=reference, header=header)
            path = self.root / name
            path.write_text(path.read_text() + f"\nUnique {filename} evidence.\n" * 20)
        self.commit("Record source links in a deeper directory")
        path = self.root / "docs/reports/deep/legacy.md"
        path.write_text(path.read_text().replace(self.legacy_stamp(self.source_commit),
                                                "> Last updated: 2026-09-13"))
        self.commit("Migrate the deeper legacy record")
        shutil.rmtree(self.root / "coordinator/legacy")
        self.commit("Delete source before moving records")
        for filename in ("legacy.md", "dated.md"):
            old = self.root / "docs/reports/deep" / filename
            new = self.root / "docs/reports" / filename
            old.rename(new)
            new.write_text(new.read_text().replace("../../../coordinator/", "../../coordinator/"))
        revision = self.commit("Move records and preserve link destinations")
        changes = self.git("diff-tree", "--no-commit-id", "--name-status", "-r", "-M", revision)
        self.assertIn("R", changes)
        for filename in ("legacy.md", "dated.md"):
            with self.subTest(filename=filename):
                self.assert_passes(f"docs/reports/{filename}")

    def test_identical_relative_links_cannot_change_destination_on_record_rename(self):
        self.git("checkout", "--detach", self.source_commit)
        self.write("docs/coordinator/legacy/example.go", "different historical source\n")
        source = self.commit("Create both possible source destinations")
        for filename, header in (("legacy.md", self.legacy_stamp(source)), ("dated.md", None)):
            name = self.report("../../coordinator/legacy/example.go", directory="reports/deep",
                               filename=filename, header=header)
            path = self.root / name
            path.write_text(path.read_text() + f"\nUnique {filename} evidence.\n" * 20)
        self.commit("Record links to the deeper destination")
        path = self.root / "docs/reports/deep/legacy.md"
        path.write_text(path.read_text().replace(self.legacy_stamp(source),
                                                "> Last updated: 2026-09-13"))
        self.commit("Migrate the deeper legacy record")
        shutil.rmtree(self.root / "coordinator/legacy")
        shutil.rmtree(self.root / "docs/coordinator")
        self.commit("Delete both destinations")
        for filename in ("legacy.md", "dated.md"):
            (self.root / "docs/reports/deep" / filename).rename(
                self.root / "docs/reports" / filename)
        revision = self.commit("Move records without adjusting relative links")
        changes = self.git("diff-tree", "--no-commit-id", "--name-status", "-r", "-M", revision)
        self.assertEqual(changes.count("R100\t"), 2, changes)
        for filename in ("legacy.md", "dated.md"):
            with self.subTest(filename=filename):
                self.assert_broken(f"docs/reports/{filename}")

    def test_date_only_target_spelling_changes_preserve_semantic_continuity(self):
        for target in ("../../coordinator/unused/../legacy/./example.go#L1",
                       "/coordinator/legacy/example.go?raw=1#L1"):
            with self.subTest(target=target):
                name = self.report(target, filename="dated.md")
                self.commit("Adjust link spelling without changing its source path")
                self.assert_passes(name)

    def test_date_only_record_cannot_borrow_unrelated_earlier_source_history(self):
        name = self.report("../../coordinator/legacy/example.go", filename="new.md")
        result = self.assert_broken(name)
        self.assertIn("no committed source-link provenance", result.stderr)
        self.commit("Add link after source removal")
        self.assert_broken(name)

    def test_multiple_date_only_links_are_checked_independently(self):
        name = "docs/reports/dated.md"
        path = self.root / name
        path.write_text(path.read_text() + "\n[missing](../../coordinator/legacy/missing.go)\n")
        self.commit("Add invalid second reference")
        result = self.assert_broken(name)
        self.assertNotIn("broken link -> ../../coordinator/legacy/example.go", result.stderr)

    def test_working_tree_legacy_stamp_cannot_forge_provenance(self):
        name = self.report("../../coordinator/legacy/example.go", filename="forged.md",
                           header=self.legacy_stamp(self.source_commit))
        result = self.assert_broken(name)
        self.assertIn("no committed source-link provenance", result.stderr)

    def test_new_date_only_record_cannot_inherit_a_copied_legacy_stamp(self):
        name = "docs/reports/copied.md"
        shutil.copyfile(self.root / "docs/reports/record.md", self.root / name)
        self.commit("Copy a legacy record after source removal")
        self.report("../../coordinator/legacy/example.go", filename="copied.md")
        self.commit("Migrate copied record to date-only")
        # This copy did contain its own legacy stamp, so that exact commit is
        # valid provenance. A brand-new date-only copy must not inherit it.
        self.assert_passes(name)
        name = self.report("../../coordinator/legacy/example.go", filename="new-copy.md")
        self.commit("Add a date-only copy after source removal")
        self.assert_broken(name)

    def test_latest_legacy_stamp_wins_even_after_multiple_date_only_updates(self):
        self.recorded_legacy_stamp(self.rename_commit)
        self.commit("Migrate invalid latest provenance")
        path = self.root / "docs/reports/record.md"
        path.write_text(path.read_text() + "\nUnrelated note.\n")
        self.commit("Later date-only update")
        self.assert_broken("docs/reports/record.md")

    def test_legacy_stamp_with_body_annotation_retains_its_exact_commit(self):
        header = self.legacy_stamp(self.before_source) + " (evidence below)."
        self.report("../../coordinator/legacy/example.go", header=header)
        self.commit("Record annotated legacy header")
        self.report("../../coordinator/legacy/example.go")
        self.assert_broken("docs/reports/record.md")
        header = self.legacy_stamp(self.source_commit) + " evidence commit `" + self.rename_commit + "`"
        self.report("../../coordinator/legacy/example.go", header=header)
        self.commit("Record exact source with a second evidence commit")
        self.report("../../coordinator/legacy/example.go")
        self.assert_passes("docs/reports/record.md")

    def test_valid_body_evidence_cannot_mask_a_malformed_legacy_stamp(self):
        header = self.legacy_stamp("not-a-sha") + f" evidence commit `{self.source_commit}`"
        self.report("../../coordinator/legacy/example.go", header=header)
        self.commit("Record invalid legacy stamp with valid body evidence")
        self.report("../../coordinator/legacy/example.go")
        result = self.assert_broken("docs/reports/record.md")
        self.assertIn("cannot resolve historical commit", result.stderr)

    def test_legacy_stamp_outside_header_cannot_supply_provenance(self):
        name = self.report("../../coordinator/legacy/example.go", filename="new.md")
        path = self.root / name
        path.write_text(path.read_text() + "\n" * 12 + self.legacy_stamp(self.source_commit) + "\n")
        self.commit("Add body evidence after source removal")
        self.assert_broken(name)

    def test_date_only_link_introduction_not_removal_or_reintroduction(self):
        name = "docs/reports/dated.md"
        self.report("../../coordinator/current/example.go", filename="dated.md")
        self.commit("Remove old relative source link")
        self.report("../../coordinator/legacy/example.go", filename="dated.md")
        self.assert_broken(name)
        self.commit("Reintroduce old path after source removal")
        self.assert_broken(name)

    def test_migrated_legacy_link_cannot_borrow_provenance_after_a_continuity_break(self):
        for replacement in ("No source link.\n",
                             "[replacement](../../coordinator/current/example.go)\n",
                             "```markdown\n[source](../../coordinator/legacy/example.go)\n```\n",
                             "`[source](../../coordinator/legacy/example.go)`\n"):
            with self.subTest(replacement=replacement):
                self.git("checkout", "--detach", self.source_commit)
                self.install_checker(self.root)
                name = self.report("../../coordinator/legacy/example.go",
                                   header=self.legacy_stamp(self.source_commit), filename="legacy.md")
                self.commit("Record legacy source provenance")
                self.report("../../coordinator/legacy/example.go", filename="legacy.md")
                self.commit("Migrate the continuous link")
                self.write(name, "# Record\n\n> Last updated: 2026-09-13\n\n" + replacement)
                self.commit("Break source link continuity")
                shutil.rmtree(self.root / "coordinator/legacy")
                self.commit("Delete the source after the link break")
                self.report("../../coordinator/legacy/example.go", filename="legacy.md")
                uncommitted = self.check(name)
                self.commit("Reintroduce the source link after deletion")
                self.assert_broken(name)
                self.assertNotEqual(uncommitted.returncode, 0, uncommitted.stdout + uncommitted.stderr)

    def test_reintroduced_link_uses_new_provenance_when_source_exists(self):
        self.recorded_legacy_stamp(self.before_source)
        self.commit("Migrate legacy stamp whose exact source commit is invalid")
        name = "docs/reports/record.md"
        self.write(name, "# Record\n\n> Last updated: 2026-09-13\n\nNo source link.\n")
        self.commit("Remove the legacy link")
        self.write("coordinator/legacy/example.go", "reintroduced source\n")
        self.report("../../coordinator/legacy/example.go")
        self.commit("Reintroduce the link alongside its source")
        (self.root / "coordinator/legacy/example.go").unlink()
        self.commit("Delete source again after its new link introduction")
        self.assert_passes(name)

    def test_new_date_only_copy_cannot_inherit_link_introduction(self):
        old = self.root / "docs/reports/dated.md"
        name = "docs/reports/copied-date-only.md"
        shutil.copyfile(old, self.root / name)
        self.commit("Copy date-only record after its source was removed")
        self.assert_broken(name)

    def test_date_only_prose_reference_cannot_backdate_a_new_link(self):
        self.git("checkout", "--detach", self.source_commit)
        name = "docs/reports/new.md"
        self.write(name, "# Record\n\n> Last updated: 2099-12-31\n\n"
                   "Mention `../../coordinator/legacy/example.go` without a link.\n")
        self.commit("Mention source while it exists")
        shutil.rmtree(self.root / "coordinator/legacy")
        self.commit("Delete source")
        path = self.root / name
        path.write_text(path.read_text() + "\n[source](../../coordinator/legacy/example.go)\n")
        self.commit("Add actual link after deletion")
        self.assert_broken(name)

    def test_fenced_markdown_samples_cannot_backdate_an_actual_source_link(self):
        for fence, reference in (("```", False), ("~~~", True), ("````", False)):
            with self.subTest(fence=fence, reference=reference):
                self.git("checkout", "--detach", self.source_commit)
                self.install_checker(self.root)
                name = "docs/reports/sample.md"
                sample = ("[source][entry]\n\n[entry]: ../../coordinator/legacy/example.go"
                          if reference else "[source](../../coordinator/legacy/example.go)")
                nested_fence = "```\n" if fence == "````" else ""
                self.write(name, "# Record\n\n> Last updated: 1900-01-01\n\n"
                           f"{fence}markdown\n{nested_fence}{sample}\n{fence}\n")
                self.commit("Show source link only in a fenced Markdown sample")
                shutil.rmtree(self.root / "coordinator/legacy")
                self.commit("Delete source before adding the real link")
                path = self.root / name
                path.write_text(path.read_text() + "\n[source](../../coordinator/legacy/example.go)\n")
                self.commit("Introduce the real source link after deletion")
                self.assert_broken(name)

    def test_date_only_reference_link_survives_source_removal(self):
        self.git("checkout", "--detach", self.source_commit)
        name = self.report("../../coordinator/legacy/example.go", filename="reference.md",
                           reference=True, header="> Last updated: 1900-01-01")
        self.commit("Introduce a date-only reference link")
        shutil.rmtree(self.root / "coordinator/legacy")
        self.commit("Delete original source")
        self.assert_passes(name)

    def test_inline_code_samples_cannot_backdate_an_actual_source_link(self):
        for sample in (
            "`[source](../../coordinator/legacy/example.go)`",
            "``[source](../../coordinator/legacy/example.go) and `nested` code``",
            "`[source](../../coordinator/legacy/example.go)\ncontinued code`",
            "`[entry]: ../../coordinator/legacy/example.go`",
        ):
            with self.subTest(sample=sample):
                self.git("checkout", "--detach", self.source_commit)
                self.install_checker(self.root)
                name = "docs/reports/inline.md"
                self.write(name, "# Record\n\n> Last updated: 2026-09-13\n\n" + sample + "\n")
                self.commit("Show source link only in inline code")
                shutil.rmtree(self.root / "coordinator/legacy")
                self.commit("Delete source before adding the real link")
                path = self.root / name
                path.write_text(path.read_text() + "\n[source](../../coordinator/legacy/example.go)\n")
                self.commit("Introduce the real source link after inline sample")
                self.assert_broken(name)

    def test_link_samples_are_ignored_by_current_and_frozen_checks(self):
        for directory in ("reports", "architecture"):
            for sample in (
                "`[source](../../missing.bin)`",
                "``[source](../../missing.bin) and `nested` code``",
                "`[source](../../missing.bin)\ncontinued code`",
                "```markdown\n[source](../../missing.bin)\n```",
                "~~~markdown\n[entry]: ../../missing.bin\n~~~",
                "````markdown\n```\n[source](../../missing.bin)\n```\n````",
                "    [source](../../missing.bin)",
            ):
                with self.subTest(directory=directory, sample=sample):
                    name = f"docs/{directory}/sample.md"
                    self.write(name, "# Record\n\n> Last updated: 2026-09-13\n\n" + sample + "\n")
                    self.assert_passes(name)

    def test_sample_link_does_not_make_a_page_reachable(self):
        self.git("checkout", "--detach", self.before_source)
        self.install_checker(self.root)
        self.write("docs/README.md", "# Index\n\n> Last updated: 2026-09-13\n\n"
                   "`[sample](orphan.md)`\n\n```markdown\n[sample](orphan.md)\n```\n")
        self.write("docs/orphan.md", "# Orphan\n\n> Last updated: 2026-09-13\n")
        self.commit("Add a page mentioned only in code examples")
        result = self.check("--all")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("docs/orphan.md: orphan", result.stderr)
        self.write("docs/README.md", "# Index\n\n> Last updated: 2026-09-13\n\n"
                   "[page][entry]\n\n[entry]: orphan.md\n")
        self.assert_passes("--all")

    def test_unmatched_and_escaped_code_markers_do_not_hide_real_links(self):
        for sample in ("\\`[source](../../missing.bin)\\`",
                       "`unmatched [source](../../missing.bin)",
                       "`unmatched\n\n[source](../../missing.bin)\n\nseparate paragraph`",
                       "`unmatched\n\n```text\nexample\n```\n[source](../../missing.bin) `"):
            with self.subTest(sample=sample):
                name = "docs/reports/markers.md"
                self.write(name, "# Record\n\n> Last updated: 2026-09-13\n\n" + sample + "\n")
                self.assert_broken(name)

    def test_actual_header_stops_before_legacy_examples(self):
        for stamp in (self.source_commit, "not-a-sha"):
            for sample in (self.legacy_stamp(stamp),
                           "```markdown\n" + self.legacy_stamp(stamp) + "\n```"):
                with self.subTest(sample=sample):
                    name = self.report("../../coordinator/legacy/example.go", filename="example.md")
                    path = self.root / name
                    path.write_text(path.read_text() + "\n" + sample + "\n")
                    self.commit("Add link after source removal with a legacy header example")
                    self.assert_broken(name)

    def test_fenced_legacy_header_before_actual_stamp_is_not_metadata(self):
        name = "docs/reports/header.md"
        self.write(name, "# Record\n\n```markdown\n" + self.legacy_stamp(self.source_commit) +
                   "\n```\n\n> Last updated: 2026-09-13\n\n"
                   "[source](../../coordinator/legacy/example.go)\n")
        self.commit("Add new source link with an earlier fenced header example")
        self.assert_broken(name)

    def test_freshness_metadata_cannot_be_supplied_by_a_code_example(self):
        for sample in ("```markdown\n> Last updated: 2026-09-13\n```",
                       "`> Last updated: 2026-09-13`",
                       "    > Last updated: 2026-09-13",
                       self.legacy_stamp(self.source_commit) + "\n\n> Last updated: 2026-09-13"):
            with self.subTest(sample=sample):
                name = "docs/reports/stamp.md"
                self.write(name, "# Record\n\n" + sample + "\n")
                result = self.check(name)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("missing date-only freshness stamp", result.stderr)

    def merge_record(self, *, stamp=False, inherited=False, stamp_commit=None):
        self.git("checkout", "--detach", self.source_commit)
        name = "docs/reports/merge.md"
        target = "../../coordinator/legacy/example.go"
        self.report(target if stamp else "../../l.go", filename="merge.md")
        base = self.commit("Record before divergent branches")
        self.git("checkout", "-b", "side")
        if inherited:
            self.report(target, filename="merge.md")
        self.write("side.txt", "side branch\n")
        self.commit("Change side branch")
        self.git("checkout", "--detach", base)
        self.write("main.txt", "main branch\n")
        self.commit("Change first parent")
        self.git("merge", "--no-ff", "--no-commit", "side")
        if not inherited:
            self.report(target, filename="merge.md",
                        header=self.legacy_stamp(stamp_commit or self.source_commit) if stamp else None)
        merge = self.commit("Resolve merge with source provenance")
        # Default path history has no statuses for this merge; it must still
        # inspect the merge tree itself, not just patches on the two branches.
        history = self.git("log", "--follow", "--format=%H", "--name-status", "--", name)
        self.assertNotIn(merge, history)
        self.assertEqual(len(self.git("rev-list", "--parents", "-1", merge).split()), 3)
        return name, merge

    def test_merge_resolution_can_introduce_a_date_only_link(self):
        name, _ = self.merge_record()
        shutil.rmtree(self.root / "coordinator/legacy")
        self.commit("Delete source after merge-added link")
        self.assert_passes(name)

    def test_merge_resolution_can_introduce_a_legacy_stamp(self):
        name, _ = self.merge_record(stamp=True)
        self.report("../../coordinator/legacy/example.go", filename="merge.md")
        self.commit("Migrate merge-added legacy stamp")
        shutil.rmtree(self.root / "coordinator/legacy")
        self.commit("Delete source after merge-added stamp")
        self.assert_passes(name)

    def test_merge_added_stamp_pins_its_exact_source_revision(self):
        # An invalid merge-added stamp must beat the otherwise valid link
        # introduction, even though default --follow omits this merge.
        name, _ = self.merge_record(stamp=True, stamp_commit=self.before_source)
        self.report("../../coordinator/legacy/example.go", filename="merge.md")
        shutil.rmtree(self.root / "coordinator/legacy")
        self.commit("Migrate stamp and remove source")
        self.assert_broken(name)

    def test_merge_inherits_continuous_link_from_second_parent(self):
        name, _ = self.merge_record(inherited=True)
        shutil.rmtree(self.root / "coordinator/legacy")
        self.commit("Delete source after inherited merge link")
        self.assert_passes(name)

    def test_merge_prefers_an_unchanged_document_over_another_continuous_parent(self):
        self.git("checkout", "--detach", self.source_commit)
        name = self.report("../../coordinator/legacy/example.go", filename="merge.md")
        base = self.commit("Record common source link")
        self.git("checkout", "-b", "side")
        self.report("../../coordinator/legacy/example.go", filename="merge.md",
                    header=self.legacy_stamp(self.source_commit))
        self.commit("Verify side branch source")
        self.report("../../coordinator/legacy/example.go", filename="merge.md")
        path = self.root / name
        path.write_text(path.read_text() + "\nSide branch evidence.\n")
        side = self.commit("Migrate side branch metadata")
        self.git("checkout", "--detach", base)
        self.report("../../coordinator/legacy/example.go", filename="merge.md",
                    header=self.legacy_stamp(self.before_source))
        self.commit("Pin invalid source in the first parent")
        self.git("merge", "--no-ff", "--no-commit", "side")
        self.write(name, self.git("show", f"{side}:{name}") + "\n")
        self.commit("Keep the exact second-parent document at merge")
        shutil.rmtree(self.root / "coordinator/legacy")
        self.commit("Delete source after document merge")
        self.assert_passes(name)

    def test_merge_traversal_follows_parent_document_renames(self):
        self.git("checkout", "--detach", self.source_commit)
        old = self.report("../../coordinator/legacy/example.go", filename="merge.md")
        base = self.commit("Record source before a branch rename")
        self.git("checkout", "-b", "side")
        name = "docs/releases/renamed.md"
        (self.root / name).parent.mkdir(parents=True, exist_ok=True)
        (self.root / old).rename(self.root / name)
        self.commit("Rename the document on the second parent")
        self.git("checkout", "--detach", base)
        self.write("main.txt", "main branch\n")
        self.commit("Advance the first parent")
        self.git("merge", "--no-ff", "--no-commit", "side")
        self.commit("Merge renamed document")
        shutil.rmtree(self.root / "coordinator/legacy")
        self.commit("Remove source after merge rename")
        self.assert_passes(name)

    def test_real_link_with_code_label_and_samples_survives_record_rename(self):
        self.git("checkout", "--detach", self.source_commit)
        old = "docs/reports/samples.md"
        self.write(old, "# Record\n\n> Last updated: 2026-09-13\n\n"
                   "[`source`](../../coordinator/legacy/example.go)\n\n"
                   "``[sample](../../missing.bin) with `nested` code``\n\n"
                   "````markdown\n```\n[sample](../../missing.bin)\n```\n````\n")
        self.commit("Record a real link beside inline and fenced samples")
        shutil.rmtree(self.root / "coordinator/legacy")
        self.commit("Remove source while retaining the record")
        name = "docs/releases/renamed.md"
        (self.root / name).parent.mkdir(parents=True, exist_ok=True)
        (self.root / old).rename(self.root / name)
        self.commit("Rename the record without changing source destinations")
        self.assert_passes(name)

    def test_validation_does_not_change_pinned_hashes_or_body_evidence(self):
        name = "docs/reports/dated.md"
        evidence = (f"\nEvidence commit `{self.source_commit}`.\n"
                    f"[pinned](https://example.invalid/blob/{self.before_source}/file.go)\n")
        path = self.root / name
        path.write_text(path.read_text() + evidence)
        self.commit("Keep immutable evidence outside date-only metadata")
        before = path.read_bytes()
        self.assert_passes(name)
        self.assertEqual(path.read_bytes(), before)
        self.assertIn(evidence, path.read_text())

    def test_documented_history_command_shows_patches_and_renames(self):
        name = "docs/reports/dated.md"
        renamed = "docs/reports/renamed.md"
        (self.root / name).rename(self.root / renamed)
        self.commit("Rename record for documented history inspection")
        command = next(line.strip() for line in GUIDANCE.read_text().splitlines()
                       if line.strip().startswith("git log --follow "))
        arguments = command.split()[1:]
        arguments[-1] = renamed
        history = self.git(*arguments)
        self.assertIn("rename from " + name, history)
        self.assertIn("diff --git ", history)
        self.assertIn("+[source](../../coordinator/legacy/example.go)", history)

    def test_installation_guide_prose_links_remain_visible_after_config_sample(self):
        guide = CHECKER.parent.parent / "docs/provider/installation.md"
        result = subprocess.run(
            ["python3", str(CHECKER.with_name("docs-historical-source.py")), "--links", str(guide)],
            text=True, capture_output=True, check=True, timeout=15,
        )
        self.assertIn("../reference/provider-authorization.md", result.stdout.splitlines())
        self.assertIn("./troubleshooting.md#installer-exits", result.stdout.splitlines())


if __name__ == "__main__":
    unittest.main()
