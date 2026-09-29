#!/usr/bin/env python3
"""Offline checks for complete selection, fail-closed execution and coverage."""

import collections
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import unittest.mock

from coordinator_tests.results import merge_coverage, partition, test_names, verify_events
from coordinator_tests.runner import Processes, run_task


class CoordinatorRunnerTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def events(self, events):
        path = self.root / "test.jsonl"
        path.write_text("".join(json.dumps(event) + "\n" for event in events))
        return path

    def profile(self, name, body):
        path = self.root / name
        path.write_text(body)
        return path

    def test_discovery_and_partition_include_every_test_once(self):
        names = test_names("TestUnit\nExampleExample\nFuzzCorpus\nBenchmarkSpeed\nPASS\nok package 1s\n")
        self.assertEqual(names, ["TestUnit", "ExampleExample", "FuzzCorpus"])
        names += [f"TestNew{i}" for i in range(100)]
        for workers in (1, 4, 8, 500):
            shards = partition(names, workers)
            self.assertTrue(all(shards))
            self.assertEqual(collections.Counter(name for shard in shards for name in shard), collections.Counter(names))
            self.assertEqual(shards, partition(list(reversed(names)), workers))
        self.assertEqual(partition(["TestNew"], 4), [["TestNew"]])

    def test_empty_duplicate_and_invalid_partition_fail(self):
        for names, count in (([], 4), (["TestA", "TestA"], 4), (["TestA"], 0)):
            with self.assertRaises(ValueError):
                partition(names, count)

    def test_terminal_membership_and_subtests(self):
        events = [{"Package": "p", "Action": "pass", "Test": "TestA/case"},
                  {"Package": "p", "Action": "pass", "Test": "TestA"},
                  {"Package": "p", "Action": "skip", "Test": "TestB"},
                  {"Package": "p", "Action": "pass"}]
        self.assertEqual(verify_events(self.events(events), ["TestA", "TestB"]), {"pass": 2, "skip": 1})
        for expected in (["TestA"], ["TestA", "TestB", "TestMissing"]):
            with self.assertRaises(ValueError):
                verify_events(self.events(events), expected)
        with self.assertRaises(ValueError):
            verify_events(self.events(events + [events[1]]), ["TestA", "TestB"])

    def test_empty_truncated_and_failure_output_never_pass(self):
        for events in ([], [{"Action": "run", "Test": "TestA"}],
                       [{"Package": "p", "Action": "fail"}],
                       [{"Package": "p", "Action": "pass"}, {"Action": "fail", "Test": "TestA"}]):
            with self.assertRaises(ValueError):
                verify_events(self.events(events), None)
        with self.assertRaises(ValueError):
            verify_events(self.profile("bad.jsonl", "not JSON\n"), None)

    def test_every_selected_package_must_complete_exactly_once(self):
        events = [{"Package": "p", "Action": "pass"}, {"Package": "no_tests", "Action": "skip"}]
        verify_events(self.events(events), None, ["p", "no_tests"])
        for incomplete in (events[:1], events + events[:1]):
            with self.assertRaises(ValueError):
                verify_events(self.events(incomplete), None, ["p", "no_tests"])

    def test_merge_counts_preserves_uncovered_blocks_and_denominator(self):
        a = self.profile("a.cover", "mode: atomic\np/a.go:1.1,2.2 2 1\np/a.go:3.1,4.2 3 0\n")
        b = self.profile("b.cover", "mode: atomic\np/a.go:1.1,2.2 2 4\np/a.go:3.1,4.2 3 0\np/b.go:1.1,2.2 1 2\n")
        output = self.root / "merged.cover"
        merge_coverage([a, b], output)
        self.assertEqual(output.read_text(), "mode: atomic\np/a.go:1.1,2.2 2 5\np/a.go:3.1,4.2 3 0\np/b.go:1.1,2.2 1 2\n")

    def test_bad_or_missing_profiles_fail_closed(self):
        good = self.profile("good.cover", "mode: atomic\np/a.go:1.1,2.2 2 1\n")
        for body in ("mode: atomic\n", "mode: set\np/a.go:1.1,2.2 2 1\n",
                     "mode: atomic\np/a.go:1.1,2.2 3 1\n", "mode: atomic\np/a.go:1.1,2.2 2 -1\n"):
            with self.assertRaises(ValueError):
                merge_coverage([good, self.profile("bad.cover", body)], self.root / "out.cover")
        with self.assertRaises(OSError):
            merge_coverage([self.root / "missing.cover"], self.root / "out.cover")

    def test_child_status_and_actual_events_both_required(self):
        output = 'print(\'{"Package":"p","Action":"pass","Test":"TestA"}\'); print(\'{"Package":"p","Action":"pass"}\')'
        for source, success in ((output, True), (output + "; raise SystemExit(1)", False), ("pass", False)):
            result = run_task("child", [sys.executable, "-c", source], self.root,
                              self.root, ["TestA"], Processes())
            self.assertEqual(result["passed"], success)

    def test_cancellation_reaps_owned_child_and_blocks_later_work(self):
        processes = Processes()
        child = processes.start([sys.executable, "-c", "import time; time.sleep(60)"])
        try:
            processes.cancel()
            self.assertNotEqual(child.wait(timeout=5), 0)
            with self.assertRaises(InterruptedError):
                processes.start([sys.executable, "-c", "pass"])
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()
            processes.finish(child)

    def test_cancellation_during_spawn_cannot_orphan_child(self):
        processes = Processes()
        real_popen = subprocess.Popen

        def interrupted_spawn(*args, **kwargs):
            child = real_popen(*args, **kwargs)
            processes.cancel()
            return child

        with unittest.mock.patch("coordinator_tests.runner.subprocess.Popen", side_effect=interrupted_spawn):
            child = processes.start([sys.executable, "-c", "import time; time.sleep(60)"])
        try:
            self.assertNotEqual(child.wait(timeout=5), 0)
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()
            processes.finish(child)


if __name__ == "__main__":
    unittest.main()
