"""Exercise repository refresh behavior with isolated local Git repositories."""

import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest


sys.dont_write_bytecode = True
script = Path(__file__).resolve().parents[1] / "refresh.py"
spec = importlib.util.spec_from_file_location("refresh_nightly_skills", script)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class RefreshTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="nightly-skills-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.origin = self.root / "origin.git"
        self.author = self.root / "author"
        self.clone = self.root / "managed"
        self.environment = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)
        self.git(self.root, "init", "--bare", str(self.origin))
        self.git(self.root, "init", "--initial-branch=main", str(self.author))
        self.git(self.author, "config", "user.name", "Fixture Author")
        self.git(self.author, "config", "user.email", "fixture@example.invalid")
        self.write_version("one")
        self.commit("Initial skills")
        self.git(self.author, "remote", "add", "origin", str(self.origin))
        self.git(self.author, "push", "origin", "main")
        self.git(self.root, "clone", "--branch", "main", str(self.origin), str(self.clone))
        self.git(self.clone, "config", "nightlyLinear.managed", "true")
        self.config = self.root / "config.json"
        self.data = {"source_repo": {
            "checkout_path": str(self.clone), "origin_url": str(self.origin), "branch": "main",
        }}
        self.save_config()
        self.state = self.root / "state.json"
        self.state.write_text('{"pending_actions":[{"fingerprint":"already-written"}]}\n')
        self.initial_state = self.state.read_bytes()
        self.initial_head = self.git(self.clone, "rev-parse", "HEAD")

    def git(self, cwd, *arguments):
        result = subprocess.run(
            ["git", "-C", str(cwd), "-c", "core.hooksPath=/dev/null", *arguments],
            capture_output=True, text=True, env=self.environment, check=True,
        )
        return result.stdout.strip()

    def save_config(self):
        self.config.write_text(json.dumps(self.data))

    def write_version(self, label):
        for name in module.SKILLS:
            path = self.author / module.PACKAGE_ROOT / "skills" / name / "SKILL.md"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(f"---\nname: {name}\ndescription: Fixture\n---\nVersion {label}\n")
        playbook = self.author / module.PACKAGE_ROOT / "run.md"
        playbook.parent.mkdir(parents=True, exist_ok=True)
        playbook.write_text(f"Playbook version {label}\n")

    def commit(self, message):
        self.git(self.author, "add", ".")
        self.git(self.author, "-c", "commit.gpgsign=false", "commit", "-m", message)

    def publish_version(self, label):
        self.write_version(label)
        self.commit(f"Version {label}")
        self.git(self.author, "push", "origin", "main")
        return self.git(self.author, "rev-parse", "HEAD")

    def run_refresh(self):
        return subprocess.run(
            [sys.executable, str(script), str(self.config)],
            capture_output=True, text=True, env=self.environment,
        )

    def assert_preserved(self):
        self.assertEqual(self.git(self.clone, "rev-parse", "HEAD"), self.initial_head)
        self.assertEqual(self.state.read_bytes(), self.initial_state)

    def test_fetches_new_commit_and_all_bodies_from_that_commit(self):
        latest = self.publish_version("two")
        result = self.run_refresh()
        self.assertEqual(result.returncode, 0, result.stderr)
        loaded = json.loads(result.stdout)
        self.assertEqual(loaded["revision"], latest)
        self.assertEqual(self.git(self.clone, "rev-parse", "HEAD"), latest)
        self.assertIn("version two", loaded["playbook"])
        for body in loaded["skills"].values():
            self.assertIn("Version two", body)
        self.assertEqual(self.state.read_bytes(), self.initial_state)

    def test_repeat_run_uses_same_revision_without_changing_state(self):
        first = self.run_refresh()
        second = self.run_refresh()
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(json.loads(first.stdout), json.loads(second.stdout))
        self.assert_preserved()

    def test_real_package_loads_from_a_committed_clone(self):
        package = script.parent
        destination = self.author / module.PACKAGE_ROOT
        shutil.copytree(package, destination, dirs_exist_ok=True,
                        ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
        self.commit("Install real workflow package")
        self.git(self.author, "push", "origin", "main")
        result = self.run_refresh()
        self.assertEqual(result.returncode, 0, result.stderr)
        loaded = json.loads(result.stdout)
        self.assertEqual(loaded["playbook"], (package / "run.md").read_text().strip())
        for name, body in loaded["skills"].items():
            self.assertEqual(body, (package / "skills" / name / "SKILL.md").read_text().strip())
        for name in ("setup.md", "teammate-prompt.md", "config.example.json", "state.example.json"):
            self.assertEqual(
                self.git(self.clone, "show", f'{loaded["revision"]}:{module.PACKAGE_ROOT}/{name}'),
                (package / name).read_text().strip(),
            )
        self.assertEqual(self.state.read_bytes(), self.initial_state)

    def test_package_documentation_links_resolve(self):
        for document in script.parent.rglob("*.md"):
            for target in re.findall(r"\[[^\]]+\]\(([^)]+)\)", document.read_text()):
                if "://" not in target and not target.startswith("#"):
                    self.assertTrue((document.parent / target.split("#", 1)[0]).exists(),
                                    f"Broken package link in {document.name}: {target}")

    def test_dirty_clone_preserves_local_edits(self):
        self.publish_version("two")
        path = self.clone / module.PACKAGE_ROOT / "skills" / module.SKILLS[0] / "SKILL.md"
        path.write_text("My local edits\n")
        result = self.run_refresh()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(result.stdout)
        self.assertEqual(path.read_text(), "My local edits\n")
        self.assert_preserved()

    def test_untracked_files_are_preserved(self):
        path = self.clone / "personal-note.txt"
        path.write_text("Keep me\n")
        result = self.run_refresh()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(path.read_text(), "Keep me\n")
        self.assert_preserved()

    def test_local_commits_are_never_reset(self):
        self.git(self.clone, "config", "user.name", "Fixture User")
        self.git(self.clone, "config", "user.email", "fixture-user@example.invalid")
        (self.clone / "local.txt").write_text("A local commit\n")
        self.git(self.clone, "add", ".")
        self.git(self.clone, "-c", "commit.gpgsign=false", "commit", "-m", "Local work")
        self.initial_head = self.git(self.clone, "rev-parse", "HEAD")
        self.publish_version("two")
        result = self.run_refresh()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(result.stdout)
        self.assert_preserved()

    def test_failed_fetch_never_loads_cached_workflow(self):
        unavailable = str(self.root / "missing-origin.git")
        self.git(self.clone, "remote", "set-url", "origin", unavailable)
        self.data["source_repo"]["origin_url"] = unavailable
        self.save_config()
        result = self.run_refresh()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(result.stdout)
        self.assert_preserved()

    def test_wrong_origin_is_rejected(self):
        self.data["source_repo"]["origin_url"] = str(self.root / "different-origin.git")
        self.save_config()
        result = self.run_refresh()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("origin differs", result.stderr)
        self.assert_preserved()

    def test_unmanaged_clone_is_rejected(self):
        self.git(self.clone, "config", "--unset", "nightlyLinear.managed")
        result = self.run_refresh()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not marked", result.stderr)
        self.assert_preserved()

    def test_broken_update_does_not_replace_working_checkout(self):
        (self.author / module.PACKAGE_ROOT / "skills" / module.SKILLS[1] / "SKILL.md").unlink()
        self.commit("Remove required skill")
        self.git(self.author, "push", "origin", "main")
        result = self.run_refresh()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(result.stdout)
        self.assert_preserved()


if __name__ == "__main__":
    unittest.main()
