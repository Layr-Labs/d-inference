#!/usr/bin/env python3
"""Offline checks of the tested-change lookup (scripts/ci-tested-tree.py); no network."""

import importlib.util
from pathlib import Path
import subprocess
import sys
import unittest
import urllib.error

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("ci_tested_tree", ROOT / "scripts/ci-tested-tree.py")
lookup = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(lookup)

REPO = "Layr-Labs/d-inference"
REF = f"{REPO}/.github/workflows/ci-dev.yml@refs/heads/dev"
TREE, OTHER = "a" * 40, "b" * 40
BASE, HEAD, MERGE, ELSE = "1" * 40, "2" * 40, "3" * 40, "4" * 40
ALL = {"provider": True, "cluster": True, "mimo_audio": True}
PROVIDER = {"provider": True, "cluster": False, "mimo_audio": False}


def run(run_id, **changes):
    value = {"id": run_id, "status": "completed", "conclusion": "success", "path": ".github/workflows/ci-dev.yml",
             "event": "pull_request", "head_sha": HEAD, "repository": {"full_name": REPO},
             "head_repository": {"full_name": REPO}, "html_url": f"https://github.com/{REPO}/actions/runs/{run_id}"}
    value.update(changes)
    return value


class Api:
    """Answers the GET paths the lookup uses, and records them."""

    def __init__(self, artifacts=(), runs=None, commits=None, fail=None):
        self.artifacts, self.runs, self.fail, self.paths = list(artifacts), runs or {}, fail, []
        self.commits = commits if commits is not None else {MERGE: {"tree": {"sha": TREE},
                                                                    "parents": [{"sha": BASE}, {"sha": HEAD}]}}

    def __call__(self, path):
        self.paths.append(path)
        if self.fail:
            raise self.fail
        if "/actions/artifacts?name=" in path:
            name = path.split("name=", 1)[1].split("&", 1)[0]
            return {"artifacts": [artifact for artifact in self.artifacts if artifact["name"] == name]}
        if "/git/commits/" in path:
            return self.commits[path.rsplit("/", 1)[1]]
        return self.runs[int(path.rsplit("/", 1)[1])]


def record(run_id, tree=TREE, base=BASE, head=HEAD, selected=None, **changes):
    name = lookup.record_name(tree, base, head, selected or ALL)
    return {"name": name, "expired": False, "workflow_run": {"id": run_id}, **changes}


class LookupTests(unittest.TestCase):
    def push(self, api, selected=PROVIDER, commit=MERGE, tree=TREE):
        return lookup.decide(REPO, REF, "push", commit, tree, "", "", selected, 99, get=api)

    def pull(self, api, selected=PROVIDER, base=BASE, head=HEAD, tree=TREE):
        return lookup.decide(REPO, REF, "pull_request", MERGE, tree, base, head, selected, 99, get=api)

    def test_merge_push_skips_after_the_pull_request_run_of_the_same_change(self):
        api = Api([record(7)], {7: run(7)})
        skip, url, note = self.push(api)
        self.assertTrue(skip)
        self.assertEqual(url, f"https://github.com/{REPO}/actions/runs/7")
        self.assertIn("already passed", note)

    def test_a_different_tree_runs(self):
        self.assertFalse(self.push(Api([record(7, tree=OTHER)], {7: run(7)}))[0])
        self.assertFalse(self.pull(Api([record(7, tree=OTHER)], {7: run(7)}))[0])

    def test_lookup_failure_runs(self):
        for failure in (urllib.error.URLError("down"), TimeoutError(), KeyError("GITHUB_TOKEN"), ValueError("bad")):
            with self.subTest(failure=type(failure).__name__):
                skip, url, note = self.push(Api(fail=failure))
                self.assertFalse(skip)
                self.assertIn("lookup failed", note)

    def test_a_record_must_cover_every_component_this_run_selects(self):
        provider_only = record(7, selected=PROVIDER)
        # A provider-only record does not cover a full (master) run...
        self.assertFalse(self.push(Api([provider_only], {7: run(7)}), selected=ALL)[0])
        # ...a full record covers a provider-only run, and a superset is found.
        self.assertTrue(self.push(Api([record(7, selected=ALL)], {7: run(7)}), selected=PROVIDER)[0])
        self.assertTrue(self.push(Api([provider_only], {7: run(7)}), selected=PROVIDER)[0])
        partial = {"provider": True, "cluster": True, "mimo_audio": False}
        self.assertFalse(self.push(Api([record(7, selected=partial)], {7: run(7)}), selected=ALL)[0])

    def test_the_record_binds_to_the_merged_head_and_the_tested_base(self):
        # The pushed merge commit merges HEAD into BASE; a record of another
        # head, another base, or a run of another head proves nothing.
        self.assertFalse(self.push(Api([record(7, head=ELSE)], {7: run(7, head_sha=ELSE)}))[0])
        self.assertFalse(self.push(Api([record(7, base=ELSE)], {7: run(7)}))[0])
        self.assertFalse(self.push(Api([record(7)], {7: run(7, head_sha=ELSE)}))[0])
        # A record a push run made is used only by a run of that same push.
        pushed = record(7, base="push", head=MERGE)
        self.assertTrue(self.push(Api([pushed], {7: run(7, event="push", head_sha=MERGE)}))[0])
        self.assertFalse(self.push(Api([pushed], {7: run(7, event="pull_request", head_sha=MERGE)}))[0])
        # A pushed commit whose tree is not the tree under test proves nothing.
        commits = {MERGE: {"tree": {"sha": OTHER}, "parents": [{"sha": BASE}, {"sha": HEAD}]}}
        self.assertFalse(self.push(Api([record(7)], {7: run(7)}, commits=commits))[0])
        # A direct push (one parent) can only match a run of itself.
        commits = {MERGE: {"tree": {"sha": TREE}, "parents": [{"sha": BASE}]}}
        self.assertFalse(self.push(Api([record(7)], {7: run(7)}, commits=commits))[0])
        # A pull request matches only its own base and head.
        self.assertTrue(self.pull(Api([record(7)], {7: run(7)}))[0])
        self.assertFalse(self.pull(Api([record(7)], {7: run(7)}), base=ELSE)[0])

    def test_a_dispatched_run_never_skips_and_reads_no_record(self):
        api = Api([record(7, base="push", head=MERGE)], {7: run(7, event="push", head_sha=MERGE)})
        skip, url, note = lookup.decide(REPO, REF, "workflow_dispatch", MERGE, TREE, "", "", ALL, 99, get=api)
        self.assertEqual((skip, url), (False, ""))
        self.assertIn("never skips", note)
        self.assertEqual(api.paths, [])

    def test_unproven_runs_never_skip(self):
        cases = {
            "failed": run(7, conclusion="failure"),
            "cancelled": run(7, conclusion="cancelled"),
            "unfinished": run(7, status="in_progress", conclusion=None),
            "another workflow": run(7, path=".github/workflows/ci-master.yml"),
            "a fork's run": run(7, head_repository={"full_name": "someone/d-inference"}),
            "another repository": run(7, repository={"full_name": "someone/d-inference"}),
        }
        for name, recorded in cases.items():
            with self.subTest(case=name):
                self.assertFalse(self.push(Api([record(7)], {7: recorded}))[0])
        self.assertFalse(self.push(Api([record(7, expired=True)], {7: run(7)}))[0])
        self.assertFalse(self.push(Api([record(99)], {99: run(99)}))[0])
        api = Api([record(7), record(8)], {7: run(7, conclusion="failure"), 8: run(8)})
        self.assertEqual(self.push(api)[1], f"https://github.com/{REPO}/actions/runs/8")

    def test_inputs_are_validated_before_any_record_is_read(self):
        for kwargs in ({"tree": "abc"}, {"commit": "A" * 40}):
            with self.subTest(**kwargs):
                api = Api([record(7)], {7: run(7)})
                self.assertFalse(self.push(api, **kwargs)[0])
                self.assertFalse(any("/artifacts" in path for path in api.paths))
        api = Api([record(7)], {7: run(7)})
        self.assertFalse(lookup.decide(REPO, f"{REPO}/ci.yml@main", "push", MERGE, TREE, "", "", PROVIDER, 99,
                                       get=api)[0])
        self.assertEqual(api.paths, [])
        self.assertFalse(lookup.decide(REPO, REF, "schedule", MERGE, TREE, "", "", PROVIDER, 99, get=api)[0])
        with self.assertRaises(ValueError):
            lookup.components("provider=true,cluster=false")
        # Nothing selected: nothing to skip, and no record is read.
        api = Api([record(7)], {7: run(7)})
        none = dict.fromkeys(lookup.COMPONENTS, False)
        self.assertFalse(self.push(api, selected=none)[0])
        self.assertEqual(api.paths, [])

    def test_the_gate_and_the_lookup_name_records_alike(self):
        result = subprocess.run([sys.executable, str(ROOT / "scripts/ci-tested-tree.py"), "name", "--tree", TREE,
                                 "--base", "push", "--head", MERGE,
                                 "--components", "provider=true,cluster=false,mimo_audio=true"],
                                capture_output=True, text=True, check=True)
        self.assertEqual(result.stdout.strip(), f"ci-tested-{TREE}-push-{MERGE}-p1c0m1")
        self.assertEqual(lookup.workflow_path(f"{REPO}/.github/workflows/ci-master.yml@refs/pull/12/merge", REPO),
                         ".github/workflows/ci-master.yml")


if __name__ == "__main__":
    unittest.main()
