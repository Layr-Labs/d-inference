#!/usr/bin/env python3
"""Offline checks of the tested-tree lookup (scripts/ci-tested-tree.py); no network."""

import importlib.util
from pathlib import Path
import unittest
import urllib.error

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("ci_tested_tree", ROOT / "scripts/ci-tested-tree.py")
lookup = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(lookup)

REPO = "Layr-Labs/d-inference"
REF = f"{REPO}/.github/workflows/ci-dev.yml@refs/heads/dev"
TREE = "a" * 40
OTHER = "b" * 40


def run(run_id, **changes):
    value = {"id": run_id, "status": "completed", "conclusion": "success", "path": ".github/workflows/ci-dev.yml",
             "repository": {"full_name": REPO}, "head_repository": {"full_name": REPO},
             "html_url": f"https://github.com/{REPO}/actions/runs/{run_id}"}
    value.update(changes)
    return value


class Api:
    """Answers the two GET paths the lookup uses, and records them."""

    def __init__(self, artifacts, runs, fail=None):
        self.artifacts, self.runs, self.fail, self.paths = artifacts, runs, fail, []

    def __call__(self, path):
        self.paths.append(path)
        if self.fail:
            raise self.fail
        if path.startswith(f"/repos/{REPO}/actions/artifacts?name=ci-tested-tree-"):
            tree = path.split("ci-tested-tree-", 1)[1].split("&", 1)[0]
            return {"artifacts": [artifact for artifact in self.artifacts
                                  if artifact["name"] == f"ci-tested-tree-{tree}"]}
        return self.runs[int(path.rsplit("/", 1)[1])]


def artifact(tree, run_id, **changes):
    return {"name": f"ci-tested-tree-{tree}", "expired": False, "workflow_run": {"id": run_id}, **changes}


class LookupTests(unittest.TestCase):
    def decide(self, api, tree=TREE, run_id=99):
        return lookup.decide(REPO, REF, tree, run_id, get=api)

    def test_same_tree_tested_by_a_successful_run_skips(self):
        api = Api([artifact(TREE, 7)], {7: run(7)})
        skip, url, note = self.decide(api)
        self.assertTrue(skip)
        self.assertEqual(url, f"https://github.com/{REPO}/actions/runs/7")
        self.assertIn("already passed", note)
        # One listing call and one run read.
        self.assertEqual(len(api.paths), 2)

    def test_a_different_tree_runs(self):
        api = Api([artifact(OTHER, 7)], {7: run(7)})
        self.assertEqual(self.decide(api)[:2], (False, ""))

    def test_lookup_failure_runs(self):
        for failure in (urllib.error.URLError("down"), TimeoutError(), KeyError("GITHUB_TOKEN"), ValueError("bad")):
            with self.subTest(failure=type(failure).__name__):
                skip, url, note = self.decide(Api([], {}, fail=failure))
                self.assertFalse(skip)
                self.assertIn("lookup failed", note)

    def test_unproven_runs_never_skip(self):
        cases = {
            "failed": run(7, conclusion="failure"),
            "cancelled": run(7, conclusion="cancelled"),
            "unfinished": run(7, status="in_progress", conclusion=None),
            "another workflow": run(7, path=".github/workflows/ci-master.yml"),
            "a fork's run": run(7, head_repository={"full_name": "someone/d-inference"}),
            "another repository": run(7, repository={"full_name": "someone/d-inference"}),
        }
        for name, record in cases.items():
            with self.subTest(case=name):
                self.assertFalse(self.decide(Api([artifact(TREE, 7)], {7: record}))[0])
        # An expired artifact, or this run's own, proves nothing.
        self.assertFalse(self.decide(Api([artifact(TREE, 7, expired=True)], {7: run(7)}))[0])
        self.assertFalse(self.decide(Api([artifact(TREE, 99)], {99: run(99)}))[0])
        # A later proving run is found past an unproven one.
        api = Api([artifact(TREE, 7), artifact(TREE, 8)], {7: run(7, conclusion="failure"), 8: run(8)})
        self.assertEqual(self.decide(api)[1], f"https://github.com/{REPO}/actions/runs/8")

    def test_inputs_are_validated_before_any_request(self):
        for ref, tree in ((f"{REPO}/ci.yml@main", TREE), ("other/repo/.github/workflows/ci-dev.yml@x", TREE),
                          (REF, "abc"), (REF, "A" * 40)):
            with self.subTest(ref=ref, tree=tree):
                api = Api([artifact(TREE, 7)], {7: run(7)})
                self.assertFalse(self.decide(api, tree=tree, run_id=99)[0] if ref == REF else
                                 lookup.decide(REPO, ref, tree, 99, get=api)[0])
                self.assertEqual(api.paths, [])

    def test_workflow_path_comes_from_the_caller_ref(self):
        self.assertEqual(lookup.workflow_path(f"{REPO}/.github/workflows/ci-master.yml@refs/pull/12/merge", REPO),
                         ".github/workflows/ci-master.yml")


if __name__ == "__main__":
    unittest.main()
