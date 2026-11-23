#!/usr/bin/env python3
"""ci-checkout-submodules.py leaves the checkout that `submodules: recursive` leaves.

Each test builds local repositories: a superproject whose submodules (one
with a nested submodule) record commits behind their remotes' tips, the way
a pin trails a moving branch. It compares the script with the commands that
actions/checkout runs, on depth-1 clones.

Run: python3 scripts/test-ci-checkout-submodules.py
"""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parent / "ci-checkout-submodules.py"
# actions/checkout's `submodules: recursive` with fetch-depth 1.
STANDARD = (("submodule", "sync", "--recursive"),
            ("-c", "protocol.version=2", "submodule", "update", "--init", "--force", "--depth=1", "--recursive"))


class CheckoutSubmodules(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.work = Path(temporary.name)
        settings = {"protocol.file.allow": "always", "uploadpack.allowAnySHA1InWant": "true",
                    "init.defaultBranch": "main", "user.name": "t", "user.email": "t@t", "commit.gpgsign": "false",
                    "advice.detachedHead": "false"}
        self.environment = {**{key: value for key, value in os.environ.items() if not key.startswith("GIT_")},
                            "HOME": str(self.work), "GIT_CONFIG_NOSYSTEM": "1",
                            "GIT_CONFIG_COUNT": str(len(settings))}
        for index, (key, value) in enumerate(settings.items()):
            self.environment[f"GIT_CONFIG_KEY_{index}"] = key
            self.environment[f"GIT_CONFIG_VALUE_{index}"] = value
        inner = self.repository("inner", "inner.txt")
        middle = self.repository("middle", "middle.txt", {"nested/inner": inner})
        self.superproject = self.repository("super", "super.txt", {"libs/middle": middle, "libs/inner": inner})

    def git(self, directory, *arguments):
        return subprocess.run(["git", "-C", str(directory), *arguments], env=self.environment, check=True,
                              capture_output=True, text=True).stdout.strip()

    def repository(self, name, file, submodules=None):
        """A repository whose recorded submodule commits are the parents of their remotes' tips."""
        directory = self.work / "remotes" / name
        directory.mkdir(parents=True)
        self.git(directory, "init", "-q")
        (directory / file).write_text(f"{name} 1\n")
        for path, remote in (submodules or {}).items():
            pinned = self.git(remote, "rev-parse", "HEAD~1")
            self.git(directory, "config", "--file", ".gitmodules", f"submodule.{path}.path", path)
            self.git(directory, "config", "--file", ".gitmodules", f"submodule.{path}.url", remote.as_uri())
            self.git(directory, "update-index", "--add", "--cacheinfo", f"160000,{pinned},{path}")
            self.git(directory, "add", ".gitmodules")
        self.git(directory, "add", file)
        self.git(directory, "commit", "-q", "-m", "first")
        (directory / file).write_text(f"{name} 2\n")
        self.git(directory, "commit", "-q", "-am", "second")
        self.git(directory, "checkout", "-q", "HEAD~1")
        self.git(directory, "branch", "-q", "-f", "pinned")
        self.git(directory, "checkout", "-q", "main")
        return directory

    def clone(self, name):
        """A depth-1 clone of the superproject at its pinned commit, as actions/checkout fetches it."""
        directory = self.work / name
        subprocess.run(["git", "clone", "-q", "--depth=1", "--branch", "pinned", self.superproject.as_uri(), str(directory)],
                       env=self.environment, check=True)
        return directory

    def standard(self, directory):
        for arguments in STANDARD:
            self.git(directory, *arguments)

    def script(self, directory):
        return subprocess.run([sys.executable, str(SCRIPT)], cwd=directory, env=self.environment,
                              capture_output=True, text=True)

    def state(self, directory):
        """What a later step reads: pins, heads, files, git directories and their links.

        Refs differ by design: git's own clone also keeps the default
        branch's tip as a branch and a remote-tracking ref.
        """
        status = [line.split()[:2] for line in self.git(directory, "submodule", "status", "--recursive").splitlines()]
        files = {str(path.relative_to(directory)): path.read_text() for path in sorted(directory.rglob("*"))
                 if path.is_file() and ".git" not in path.relative_to(directory).parts}
        links = {str(path.relative_to(directory)): path.read_text() for path in sorted(directory.rglob(".git"))
                 if path.is_file()}
        modules = sorted(str(path.parent.relative_to(directory)) for path in (directory / ".git/modules").rglob("config")
                         if (path.parent / "objects").is_dir())
        shallow = {path: self.git(directory / path, "rev-parse", "--is-shallow-repository")
                   for _, path in status}
        return {"status": status, "files": files, "links": links, "modules": modules, "shallow": shallow,
                "clean": self.git(directory, "status", "--porcelain", "--ignore-submodules=none")}

    def test_leaves_the_checkout_that_the_standard_update_leaves(self):
        expected, actual = self.clone("standard"), self.clone("script")
        self.standard(expected)
        result = self.script(actual)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Fetched 3 submodules at their recorded commits", result.stdout)
        self.assertEqual(self.state(actual), self.state(expected))
        state = self.state(actual)
        self.assertEqual([path for _, path in state["status"]], ["libs/inner", "libs/middle", "libs/middle/nested/inner"])
        self.assertEqual(state["files"]["libs/middle/nested/inner/inner.txt"], "inner 1\n")
        self.assertEqual(set(state["shallow"].values()), {"true"})
        self.assertEqual(state["clean"], "")

    def test_leaves_a_submodule_whose_git_directory_exists_to_the_update(self):
        # A restored .git holds the submodules' git directories but no work tree.
        expected, actual = self.clone("standard"), self.clone("script")
        self.standard(expected)
        self.standard(actual)
        self.git(actual, "submodule", "deinit", "-q", "--all", "--force")
        result = self.script(actual)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Fetched 0 submodules", result.stdout)
        self.assertEqual(self.state(actual), self.state(expected))

    def test_a_pin_that_moved_after_a_restore_fetches_no_other_branch(self):
        # A later run restores the .git the script made, and a pin has moved
        # since: the update's first fetch uses the submodule's fetch refspec.
        expected, actual = self.clone("standard"), self.clone("script")
        self.standard(expected)
        self.assertEqual(self.script(actual).returncode, 0)
        tip = self.git(self.work / "remotes" / "inner", "rev-parse", "main")
        for directory in (expected, actual):
            self.git(directory, "update-index", "--cacheinfo", f"160000,{tip},libs/inner")
        self.standard(expected)
        result = self.script(actual)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Fetched 0 submodules", result.stdout)
        self.assertEqual(self.state(actual), self.state(expected))
        tracked = {name: set(self.git(directory / "libs/inner", "for-each-ref", "--format=%(refname)", "refs/remotes").split())
                   for name, directory in (("standard", expected), ("script", actual))}
        self.assertLessEqual(tracked["script"], tracked["standard"])

    def test_a_commit_the_remote_lacks_fails(self):
        directory = self.clone("script")
        missing = "1" * 40
        self.git(directory, "update-index", "--cacheinfo", f"160000,{missing},libs/inner")
        result = self.script(directory)
        self.assertEqual(result.returncode, 1)
        self.assertIn("::error title=Submodules::", result.stdout)
        self.assertIn(missing, result.stdout)


if __name__ == "__main__":
    unittest.main()
