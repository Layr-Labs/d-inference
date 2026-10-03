#!/usr/bin/env python3
"""Offline checks for complete selection, fail-closed execution and coverage."""

import collections
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
from types import SimpleNamespace
import unittest
import unittest.mock

from coordinator_tests.results import merge_coverage, partition, test_names, verify_events
from coordinator_tests.runner import API, REGISTRY, ROOT, Processes, run, run_task


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

    def test_uninstrumented_numeric_gate_follows_its_test_owner(self):
        name = "TestConstrainedExactNonnegativeIntBoundsAdversarialLiterals"
        package = "coordinator/api/inference/request"
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        command = f"go test -race=false -cover=false ./{package} -run '^{name}$' -count=1"
        self.assertTrue(command in workflow, "CI must run the numeric gate in its owning request package")
        declarations = sum(f"func {name}(" in path.read_text()
                           for path in (ROOT / package).glob("*_test.go"))
        self.assertEqual(declarations, 1, "the CI selector must execute exactly one existing test")

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

    def test_outer_timeout_applies_only_to_api_shards(self):
        output = 'print(\'{"Package":"p","Action":"pass","Test":"TestA"}\'); print(\'{"Package":"p","Action":"pass"}\')'
        real_wait = subprocess.Popen.wait
        for expected, timeout in ((None, None), (["TestA"], 660)):
            with self.subTest(expected=expected):
                waits = []

                def observed_wait(process, timeout=None):
                    waits.append(timeout)
                    return real_wait(process, timeout=timeout)

                with unittest.mock.patch("coordinator_tests.runner.subprocess.Popen.wait", new=observed_wait):
                    result = run_task("child", [sys.executable, "-c", output], self.root,
                                      self.root, expected, Processes(), ["p"])
                self.assertTrue(result["passed"])
                self.assertEqual(waits, [timeout])

    def test_selected_packages_flags_and_profiles_survive_sharding(self):
        store = API.rsplit("/", 1)[0] + "/store"
        nested = REGISTRY + "/routingsim"
        contracts = API + "/tests/operations"
        testkit = API + "/tests/internal/testkit"
        selected_packages = [API, REGISTRY, store, nested, contracts, testkit]
        for race, jobs in ((True, 4), (True, 1), (False, 4)):
            with self.subTest(race=race, jobs=jobs):
                output = self.root / f"{race}-{jobs}"
                output.mkdir()
                tasks, builds = [], []
                aggregate_started = threading.Event()
                args = SimpleNamespace(packages=["./..."], race=race, jobs=jobs,
                                       coverprofile=str(output / "merged.cover"))

                def checked(command, cwd, processes, env=None):
                    if command[:2] == ["go", "list"]:
                        return "\n".join([*selected_packages, API])
                    if command[:3] == ["go", "test", "-c"]:
                        self.assertTrue(aggregate_started.wait(5), "aggregate must start before compilation")
                        builds.append(command)
                        return ""
                    self.assertEqual(command[-1], "-test.list=.")
                    self.assertEqual(cwd, ROOT / "coordinator" / Path(command[0]).stem)
                    self.assertTrue(Path(env["GOCOVERDIR"]).is_dir())
                    return "TestA\nExampleB\nFuzzC\n"

                def task(label, command, cwd, output, expected, processes, packages):
                    tasks.append((label, command, expected, packages))
                    if label == "packages":
                        aggregate_started.set()
                    return {"task": label, "seconds": 0, "passed": True}

                with unittest.mock.patch("coordinator_tests.runner.checked_output", side_effect=checked), \
                        unittest.mock.patch("coordinator_tests.runner.run_task", side_effect=task), \
                        unittest.mock.patch("coordinator_tests.runner.merge_coverage") as merge:
                    self.assertEqual(run(args, output, Processes()), 0)
                sharded = [REGISTRY, API] if race else [API]
                self.assertEqual([command[-1] for command in builds], sharded)
                for command in builds:
                    self.assertEqual("-race" in command, race)
                    self.assertIn("-covermode=atomic", command)
                    self.assertIn("-coverpkg=" + ",".join([API, REGISTRY, store, nested]), command)
                aggregate = next(task for task in tasks if task[0] == "packages")
                self.assertIn("-coverpkg=" + ",".join([API, REGISTRY, store, nested]), aggregate[1])
                self.assertEqual(aggregate[3], [package for package in selected_packages
                                                 if package not in sharded])
                for package in sharded:
                    selected = [task for task in tasks if task[3] == [package]]
                    self.assertEqual(len(selected), 1 if jobs == 1 else 3)
                    self.assertEqual(collections.Counter(test for task in selected for test in task[2]),
                                     collections.Counter(["TestA", "ExampleB", "FuzzC"]))
                profiles = merge.call_args.args[0]
                self.assertEqual(len(profiles), len(tasks))
                self.assertEqual(len(profiles), len(set(profiles)))
                for label, command, expected, _ in tasks:
                    flag = "-test.coverprofile=" if expected else "-coverprofile="
                    self.assertIn(flag + str(output / f"{label}.cover"), command)

    def test_contract_only_selection_instruments_owners_without_running_them(self):
        contract = API + "/tests/operations"
        testkit = API + "/tests/internal/testkit"
        httpx = API + "/httpx"
        args = SimpleNamespace(packages=[contract], race=True, jobs=1,
                               coverprofile=str(self.root / "merged.cover"))
        lists = []

        def checked(command, cwd, processes, env=None):
            lists.append(command)
            if command == ["go", "list", contract]:
                return contract
            self.assertEqual(command, ["go", "list", API + "/..."])
            return "\n".join([API, httpx, contract, testkit])

        def task(label, command, cwd, output, expected, processes, packages):
            self.assertEqual(label, "packages")
            self.assertEqual(packages, [contract])
            self.assertEqual(command[-1], contract)
            self.assertIn(f"-coverpkg={API},{httpx}", command)
            return {"task": label, "seconds": 0, "passed": True}

        with unittest.mock.patch("coordinator_tests.runner.checked_output", side_effect=checked), \
                unittest.mock.patch("coordinator_tests.runner.run_task", side_effect=task), \
                unittest.mock.patch("coordinator_tests.runner.merge_coverage"):
            self.assertEqual(run(args, self.root, Processes()), 0)
        self.assertEqual(len(lists), 2)

    def test_preparation_failure_cancels_running_aggregate(self):
        started = threading.Event()
        children = []
        processes = Processes()
        args = SimpleNamespace(packages=["./..."], race=True, jobs=2, coverprofile=None)

        def checked(command, cwd, processes, env=None):
            if command[:2] == ["go", "list"]:
                return API + "\n" + API.rsplit("/", 1)[0] + "/store"
            self.assertTrue(started.wait(5))
            raise ValueError("compilation failed")

        def task(label, command, cwd, output, expected, processes, packages):
            child = processes.start([sys.executable, "-c", "import time; time.sleep(60)"])
            children.append(child)
            started.set()
            try:
                child.wait(timeout=5)
            finally:
                if child.poll() is None:
                    child.kill()
                    child.wait()
                processes.finish(child)

        with unittest.mock.patch("coordinator_tests.runner.checked_output", side_effect=checked), \
                unittest.mock.patch("coordinator_tests.runner.run_task", side_effect=task):
            with self.assertRaisesRegex(ValueError, "compilation failed"):
                run(args, self.root, processes)
        self.assertTrue(processes.cancelled)
        self.assertEqual(len(children), 1)
        self.assertNotEqual(children[0].returncode, 0)
        self.assertTrue((self.root / "summary.json").exists())

    def test_single_package_without_coverage_respects_worker_bound(self):
        for jobs in (1, 2):
            with self.subTest(jobs=jobs):
                output = self.root / str(jobs)
                output.mkdir()
                args = SimpleNamespace(packages=[REGISTRY], race=True, jobs=jobs, coverprofile=None)
                lock = threading.Lock()
                active = maximum = 0

                def checked(command, cwd, processes, env=None):
                    self.assertFalse(any("cover" in flag for flag in command))
                    if command[:2] == ["go", "list"]:
                        return REGISTRY
                    if command[:3] == ["go", "test", "-c"]:
                        return ""
                    return "\n".join(f"Test{i}" for i in range(8))

                def task(label, command, cwd, output, expected, processes, packages):
                    nonlocal active, maximum
                    self.assertEqual(packages, [REGISTRY])
                    self.assertFalse(any("cover" in flag for flag in command))
                    with lock:
                        active += 1
                        maximum = max(maximum, active)
                    time.sleep(0.02)
                    with lock:
                        active -= 1
                    return {"task": label, "seconds": 0, "passed": True}

                with unittest.mock.patch("coordinator_tests.runner.checked_output", side_effect=checked), \
                        unittest.mock.patch("coordinator_tests.runner.run_task", side_effect=task), \
                        unittest.mock.patch("coordinator_tests.runner.merge_coverage") as merge:
                    self.assertEqual(run(args, output, Processes()), 0)
                self.assertEqual(maximum, jobs)
                merge.assert_not_called()

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
