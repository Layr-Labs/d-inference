#!/usr/bin/env python3
"""Offline checks of the provider test shards: classes, partition, counts and audit."""

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import textwrap
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("provider_test_shards", ROOT / "scripts/provider-test-shards.py")
shards = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(shards)

ISOLATED = "ProcessMemoryNativeIntegrationTests|stageDelta"
MLX_PACKAGES = {"mlx-swift", "mlx-swift-lm", "darkbloom-cluster"}
MLX_IMPORT = re.compile(r"(?m)^\s*(@\w+\s+)*import\s+(MLX\w*|Cmlx|Metal|MetalKit|MetalPerformanceShaders\w*)\b")


def package_targets():
    """{name: (local dependencies, package dependencies, path)} from Package.swift."""
    text = (ROOT / "provider-swift/Package.swift").read_text()
    targets = {}
    for match in re.finditer(r"\.(?:target|testTarget|executableTarget)\(\s*name: \"([^\"]+)\"(.*?)\n        \)",
                             text, re.DOTALL):
        name, body = match.group(1), match.group(2)
        dependencies = re.search(r"dependencies: \[(.*?)\]\s*,?\s*\n\s*(?:path|swiftSettings|linkerSettings|resources|\))",
                                 body, re.DOTALL)
        listed = dependencies.group(1) if dependencies else ""
        packages = set(re.findall(r"package: \"([^\"]+)\"", listed))
        local = set(re.findall(r"(?<![:\w])\"([^\"]+)\"", re.sub(r"\.product\([^)]*\)", "", listed)))
        path = re.search(r"path: \"([^\"]+)\"", body)
        targets[name] = (local, packages, path.group(1) if path else None)
    return targets


def identifiers(module, suite, tests, separator):
    return [f"{module}{separator}{suite}/{test}" for test in tests]


class ParallelClassTests(unittest.TestCase):
    def test_parallel_modules_have_no_mlx_metal_or_cluster_runtime_in_their_closure(self):
        targets = package_targets()
        self.assertIn("ProviderCoreTests", targets)
        self.assertTrue(targets["ProviderCore"][1] & MLX_PACKAGES)
        for module in shards.PARALLEL_MODULES:
            with self.subTest(module=module):
                self.assertIn(module, targets)
                pending, seen = [module], set()
                while pending:
                    name = pending.pop()
                    if name in seen:
                        continue
                    seen.add(name)
                    local, packages, path = targets[name]
                    self.assertFalse(packages & MLX_PACKAGES, (name, packages))
                    self.assertIsNotNone(path, name)
                    for source in (ROOT / "provider-swift" / path).rglob("*.swift"):
                        self.assertIsNone(MLX_IMPORT.search(source.read_text(errors="replace")), str(source))
                    pending.extend(local)
                # The closure reaches no target that links MLX.
                self.assertNotIn("ProviderCore", seen)

    def test_serial_targets_that_link_mlx_are_never_parallel(self):
        for module in ("ProviderCoreTests", "DarkbloomCLITests", "ServingQualificationTests"):
            self.assertNotIn(module, shards.PARALLEL_MODULES)


class PartitionTests(unittest.TestCase):
    def setUp(self):
        # Seconds well above each shard's fixed extra seconds, so every shard gets a suite.
        self.weights = {"ProviderCoreTests.Heavy": 5000.0, "ProviderCoreTests.Medium": 2000.0,
                        "ProviderCoreTests.Light": 100.0, "DarkbloomCLITests.Commands": 3000.0,
                        "ProviderCoreTests.HeavyTail": 500.0, "ProviderCoreFoundationTests.Pure": 900.0}
        self.tests = [
            *identifiers("ProviderCoreTests", "Heavy", ["a()", "b()"], "."),
            # Swift Testing may print the module separator as a slash.
            *identifiers("ProviderCoreTests", "Heavy", ["z()"], "/"),
            *identifiers("ProviderCoreTests", "Medium", ["c()"], "."),
            *identifiers("ProviderCoreTests", "HeavyTail", ["d()"], "."),
            *identifiers("ProviderCoreTests", "Light", ["e()", "stageDeltaIsolated()"], "."),
            *identifiers("DarkbloomCLITests", "Commands", ["f()"], "/"),
            *identifiers("ProviderCoreTests", "BrandNew", ["g()"], "."),
            *identifiers("ProviderCoreFoundationTests", "Pure", ["h()"], "."),
            *identifiers("DarkbloomFanCoreTests", "Fan", ["i()"], "."),
            "ProviderCoreTests.freeFunction()",
            "ProviderCoreTests.ProcessMemoryNativeIntegrationTests/j()",
        ]

    def plans(self, total):
        selections = ["parallel", *(f"{index}/{total}" for index in range(1, total + 1))]
        return {selection: shards.planned(self.tests, selection, ISOLATED, self.weights)
                for selection in selections}

    def test_every_listed_test_runs_in_exactly_one_selection(self):
        expected = [test for test in self.tests if not re.search(ISOLATED, test)]
        for total in range(1, 6):
            with self.subTest(shards=total):
                plans = self.plans(total)
                selected = [test for plan in plans.values() for test in plan]
                self.assertEqual(sorted(selected), sorted(expected))
                self.assertEqual(len(selected), len(set(selected)))

    def test_new_and_unweighted_suites_fall_into_the_last_shard(self):
        plans = self.plans(3)
        for test in ("ProviderCoreTests.BrandNew/g()", "ProviderCoreTests.freeFunction()"):
            self.assertIn(test, plans["3/3"])
        heavy = next(selection for selection, plan in plans.items() if "ProviderCoreTests.Heavy/a()" in plan)
        self.assertIn("ProviderCoreTests/Heavy/z()", plans[heavy])

    def test_parallel_selection_is_exactly_the_mlx_free_targets(self):
        plans = self.plans(3)
        self.assertEqual(sorted(plans["parallel"]),
                         ["DarkbloomFanCoreTests.Fan/i()", "ProviderCoreFoundationTests.Pure/h()"])
        for selection, plan in plans.items():
            if selection != "parallel":
                self.assertFalse([test for test in plan if test.split(".")[0].split("/")[0]
                                  in shards.PARALLEL_MODULES], selection)

    def test_suite_prefix_does_not_select_a_longer_suite_name(self):
        pattern = shards.suites_regex(["ProviderCoreTests.Heavy"])
        self.assertTrue(re.search(pattern, "ProviderCoreTests.Heavy/a()"))
        self.assertTrue(re.search(pattern, "ProviderCoreTests/Heavy/Nested/a()"))
        self.assertTrue(re.search(pattern, "ProviderCoreTests.Heavy"))
        self.assertFalse(re.search(pattern, "ProviderCoreTests.HeavyTail/d()"))
        self.assertFalse(re.search(pattern, "OtherTests.Heavy/a()"))

    def test_longest_suites_spread_over_the_shards(self):
        # Weights well above the fixed extra seconds of shards 1 and N, and
        # the two longest closer together than those extras differ.
        assigned, loads = shards.assignment(2, {"M.A": 1000.0, "M.B": 990.0, "M.C": 200.0, "M.D": 10.0})
        self.assertEqual([sorted(keys) for keys in assigned], [["M.A", "M.C"], ["M.B", "M.D"]])
        # Shard 2 is both the parity shard and the last shard here.
        self.assertEqual(loads, [1200.0 + shards.FIRST_SHARD_EXTRA_SECONDS,
                                 1000.0 + shards.PARITY_SHARD_EXTRA_SECONDS + shards.LAST_SHARD_EXTRA_SECONDS])
        _, loads = shards.assignment(1, {})
        self.assertEqual(loads, [shards.FIRST_SHARD_EXTRA_SECONDS + shards.PARITY_SHARD_EXTRA_SECONDS
                                 + shards.LAST_SHARD_EXTRA_SECONDS])

    def test_job_level_extras_load_every_selection_of_their_job(self):
        first, parity, last = (shards.FIRST_SHARD_EXTRA_SECONDS, shards.PARITY_SHARD_EXTRA_SECONDS,
                               shards.LAST_SHARD_EXTRA_SECONDS)
        # One selection per job: the extras sit on selections 1, PARITY_SHARD and N.
        _, loads = shards.assignment(6, {})
        self.assertEqual(loads, [first, parity, 0.0, 0.0, 0.0, last])
        # Three per job: Prompt Parity runs after job 1's processes and the
        # isolated processes after job 2's, so they load each selection there.
        # A job's processes start together, so no slot starts with a wait.
        _, loads = shards.assignment(6, {}, processes=3)
        self.assertEqual(loads, [first + parity, parity, parity, last, last, last])
        with self.assertRaisesRegex(ValueError, "do not make jobs"):
            shards.assignment(5, {}, processes=3)
        # Without fixed work, equal suites fill the slots alike; the fourth
        # goes to the first of the equally loaded slots.
        with mock.patch.multiple(shards, FIRST_SHARD_EXTRA_SECONDS=0.0, PARITY_SHARD_EXTRA_SECONDS=0.0,
                                 LAST_SHARD_EXTRA_SECONDS=0.0):
            assigned, loads = shards.assignment(3, {"M.A": 100.0, "M.B": 100.0, "M.C": 100.0, "M.D": 100.0},
                                                processes=3)
        self.assertEqual(assigned, [["M.A", "M.D"], ["M.B"], ["M.C"]])
        self.assertEqual(loads, [200.0, 100.0, 100.0])
        # Every listed test still runs in exactly one selection of a job plan
        # (2 jobs of 2 processes: this fixture has 5 serial suites).
        plans = {selection: shards.planned(self.tests, selection, ISOLATED, self.weights, 2)
                 for selection in ("parallel", *(f"{index}/4" for index in range(1, 5)))}
        selected = [test for plan in plans.values() for test in plan]
        self.assertEqual(len(selected), len(set(selected)))
        self.assertEqual(set(selected), {test for test in self.tests if not re.search(ISOLATED, test)})

    def test_the_own_process_class_leaves_the_selections_only_with_several_processes(self):
        own = shards.OWN_PROCESS_SUITES[0]
        own_tests = [f"{own}/s()", f"{own.replace('.', '/', 1)}/t()"]
        # The heaviest suite, so a plan of one process per job gives it a selection.
        weights = {**self.weights, own: 6000.0}
        tests = [*self.tests, *own_tests]
        expected = [test for test in tests if not re.search(ISOLATED, test)]
        for processes in (1, 2):
            with self.subTest(processes=processes):
                selections = [*shards.class_selections(processes), *(f"{index}/4" for index in range(1, 5))]
                plans = {selection: shards.planned(tests, selection, ISOLATED, weights, processes)
                         for selection in selections}
                selected = [test for plan in plans.values() for test in plan]
                self.assertEqual(sorted(selected), sorted(expected))
                self.assertEqual(len(selected), len(set(selected)))
                holders = [index for index, keys in enumerate(shards.assignment(4, weights, processes)[0])
                           if own in keys]
                if processes == 1:
                    # One process per job (the release qualification lane): a
                    # numbered selection plans the suite, as before.
                    self.assertNotIn("own", plans)
                    self.assertEqual(len(holders), 1)
                    with self.assertRaisesRegex(ValueError, "several processes"):
                        shards.arguments("own", ISOLATED, weights, processes)
                else:
                    # Its own serial process: the command line of a selection
                    # that held only this suite; the last selection skips it.
                    self.assertEqual(holders, [])
                    self.assertEqual(sorted(plans["own"]), sorted(own_tests))
                    self.assertEqual(shards.arguments("own", ISOLATED, weights, processes),
                                     ["--filter", shards.suites_regex([own]), "--skip", ISOLATED])
                    self.assertIn(shards.suites_regex([own]), shards.arguments("4/4", ISOLATED, weights, processes)[1])

    def test_arguments_and_shard_validation(self):
        self.assertEqual(shards.arguments("parallel", ISOLATED, self.weights),
                         ["--filter", shards.parallel_regex(), "--skip", ISOLATED])
        first = shards.arguments("1/2", ISOLATED, self.weights)
        self.assertEqual(first[0], "--filter")
        self.assertEqual(first[2:], ["--skip", ISOLATED])
        last = shards.arguments("2/2", ISOLATED, self.weights)
        self.assertEqual(last[0], "--skip")
        self.assertIn(first[1], last[1])
        self.assertIn(shards.parallel_regex(), last[1])
        for invalid in ("0/2", "3/2", "2", "a/b", ""):
            with self.subTest(shard=invalid), self.assertRaises(ValueError):
                shards.arguments(invalid, ISOLATED, self.weights)
        with self.assertRaises(ValueError):
            shards.arguments("1/9", ISOLATED, {"M.A": 1.0})

    def test_checked_in_weights_are_valid_and_cover_the_serial_suite(self):
        weights = shards.load_weights()
        serial = {key: value for key, value in weights.items()
                  if key.split(".", 1)[0] not in shards.PARALLEL_MODULES}
        self.assertGreater(len(serial), 100)
        for total in (2, 3, 4):
            assigned, _ = shards.assignment(total, weights)
            self.assertTrue(all(assigned[:-1]), total)


def swift_testing_report(*cases):
    """Swift Testing's xUnit report as Swift 6.4 writes it; a case is
    (classname/name, skipped). Its `tests` attribute leaves out the skips."""
    skips = sum(skipped for _, skipped in cases)
    body = "".join(f'<testcase classname="{name.rsplit("/", 1)[0]}" name="{name.rsplit("/", 1)[-1]}" time="0.1"'
                   + (' >\n<skipped>needs a fixture</skipped>\n</testcase>\n' if skipped else ' />\n')
                   for name, skipped in cases)
    return ('<?xml version="1.0" encoding="UTF-8"?>\n<testsuites>\n'
            f'<testsuite name="TestResults" errors="0" tests="{len(cases) - skips}" failures="0" skipped="{skips}" '
            f'time="1.0">\n{body}</testsuite>\n</testsuites>\n')


# SwiftPM's stdout (the test process's output) for 3 XCTest cases, one skipped.
XCTEST_STDOUT = textwrap.dedent("""\
    Test Suite 'Selected tests' started at 2026-10-29 12:25:40.000.
    Test Suite 'DarkbloomProviderPackageTests.xctest' passed at 2026-10-29 12:26:47.782.
    \t Executed 3 tests, with 1 test skipped and 0 failures (0 unexpected) in 1.0 (1.0) seconds
    Test Suite 'Selected tests' passed at 2026-10-29 12:26:47.783.
    \t Executed 3 tests, with 1 test skipped and 0 failures (0 unexpected) in 1.0 (1.0) seconds
    ✔ Test run with 4 tests in 2 suites passed after 1.000 seconds.
    """)
# Run 44909219943: SwiftPM's stderr warning inside the Swift Testing summary
# of a merged console (`2>&1`).
SPLIT_CONSOLE = ("✔ Test run with 29warning: '--build-system native' has been deprecated and will be removed in a "
                 "future release; please report an issue at https://github.com/swiftlang/swift-package-manager/issues "
                 "if you are unable to adopt the default build system\n"
                 " tests in 3 suites passed after 72.041 seconds.\n")


class CountAndAuditTests(unittest.TestCase):
    def counts(self, report, stdout):
        """counts() of one run whose report and stdout log hold this text; None writes no file."""
        temporary = tempfile.TemporaryDirectory(prefix="shard-counts-")
        self.addCleanup(temporary.cleanup)
        xunit, log = Path(temporary.name) / "shard-1-of-2-swift-testing.xml", Path(temporary.name) / "shard-1-of-2.log"
        for path, text in ((xunit, report), (log, stdout)):
            if text is not None:
                path.write_text(text)
        return shards.counts(xunit, log)

    def test_counts_read_both_frameworks_skips_included(self):
        # Skipped tests count as run in both, as the console summaries did:
        # in run 44914459288 selection 3/12 printed `Test run with 1245 tests`,
        # and its report held 1245 cases, 213 of them skipped.
        report = swift_testing_report(("M.A/a()", False), ("M.A/b()", True), ("M.B/c()", False), ("M.B/d()", False))
        self.assertEqual(self.counts(report, XCTEST_STDOUT), {"swift_testing": 4, "xctest": 3})
        failed = XCTEST_STDOUT.replace("Test Suite 'Selected tests' passed", "Test Suite 'Selected tests' failed")
        self.assertEqual(self.counts(report, failed), {"swift_testing": 4, "xctest": 3})
        self.assertEqual(self.counts(swift_testing_report(("M.A/a()", False)), ""), {"swift_testing": 1, "xctest": 0})
        # A parity selection of only XCTest cases (Nemotron): its report holds none.
        self.assertEqual(self.counts(swift_testing_report(), XCTEST_STDOUT), {"swift_testing": 0, "xctest": 3})
        # The test process's own output can arrive between XCTest's last two lines.
        noisy = XCTEST_STDOUT.replace("12:26:47.783.\n", "12:26:47.783.\nflushed\noutput\nof\na test\n")
        self.assertEqual(self.counts(report, noisy), {"swift_testing": 4, "xctest": 3})
        with self.assertRaisesRegex(ValueError, "zero tests"):
            self.counts(swift_testing_report(), "Test Suite 'Selected tests' passed at x\n Executed 0 tests")

    def test_a_warning_inside_the_console_summary_does_not_move_the_counts(self):
        # The same run's merged console read as its stdout: the counts never
        # come from the Swift Testing summary line.
        report = swift_testing_report(*((f"M.S/test{index}()", False) for index in range(29)))
        self.assertEqual(self.counts(report, SPLIT_CONSOLE), {"swift_testing": 29, "xctest": 0})
        self.assertEqual(self.counts(report, XCTEST_STDOUT.replace("✔ Test run with 4 tests in 2 suites passed after "
                                                                   "1.000 seconds.\n", SPLIT_CONSOLE)),
                         {"swift_testing": 29, "xctest": 3})

    def test_counts_fail_without_a_readable_report_or_stdout(self):
        # SwiftPM writes the report when the run finishes: without one, or
        # with one cut short, the run did not finish, whatever its console says.
        console = "✔ Test run with 4 tests in 2 suites passed after 1.000 seconds.\n"
        for report, message in ((None, "No Swift Testing xUnit report"),
                                ("", "Unreadable Swift Testing xUnit report"),
                                ('<?xml version="1.0" encoding="UTF-8"?>\n<testsuites>\n',
                                 "Unreadable Swift Testing xUnit report")):
            with self.subTest(report=report), self.assertRaisesRegex(ValueError, message + ".*did not finish"):
                self.counts(report, XCTEST_STDOUT + console)
        with self.assertRaisesRegex(ValueError, "No stdout log.*did not finish"):
            self.counts(swift_testing_report(("M.A/a()", False)), None)

    def test_counts_command_fails_loudly_and_a_test_that_did_not_run_fails_the_audit(self):
        # The run's report and stdout, through `counts` and `audit-job`, as CI runs them.
        weighted = next(key for key in shards.load_weights() if key.startswith("DarkbloomCLITests."))
        tests = [f"{weighted}/a()", f"{weighted}/b()", "ProviderCoreTests.XCTestClass/testOne",
                 "ProviderCoreTests.XCTestClass/testTwo", "ProviderCoreTests.XCTestClass/testThree",
                 "ProviderCoreFoundationTests.Pure/f()"]
        temporary = tempfile.TemporaryDirectory(prefix="shard-counts-audit-")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        (root / "tests.txt").write_text("\n".join(tests) + "\n")
        reports = root / "reports"
        reports.mkdir()
        environment = {key: value for key, value in os.environ.items() if key != "PROVIDER_TEST_PROCESSES"}

        def run(*arguments):
            return subprocess.run(["python3", str(ROOT / "scripts/provider-test-shards.py"), *map(str, arguments)],
                                  capture_output=True, text=True, env=environment)

        def counts(shard, cases, stdout):
            name = shard.replace("/", "-of-")
            report = reports / f"shard-{name}-swift-testing.xml"
            if cases is not None:
                report.write_text(swift_testing_report(*cases))
            (reports / f"shard-{name}.log").write_text(stdout)
            return run("counts", shard, ISOLATED, report, reports / f"shard-{name}.log", reports / f"shard-{name}.json")

        self.assertEqual(counts("parallel", [], "").returncode, 1)
        self.assertFalse((reports / "shard-parallel.json").exists())
        self.assertEqual(counts("parallel", [("ProviderCoreFoundationTests.Pure/f()", False)], "").returncode, 0)
        missing = counts("1/1", None, XCTEST_STDOUT)
        self.assertEqual(missing.returncode, 1)
        self.assertIn("::error::Selection 1/1: No Swift Testing xUnit report", missing.stdout)
        self.assertFalse((reports / "shard-1-of-1.json").exists())
        # Every planned test ran once, one Swift Testing test as a skip: the
        # audit passes, though a warning split the console's summary.
        ran = counts("1/1", [(f"{weighted}/a()", False), (f"{weighted}/b()", True)], XCTEST_STDOUT + SPLIT_CONSOLE)
        self.assertEqual(ran.returncode, 0, ran.stdout + ran.stderr)
        self.assertEqual(json.loads((reports / "shard-1-of-1.json").read_text()),
                         {"shard": "1/1", "pattern": ISOLATED, "processes": 1, "swift_testing": 2, "xctest": 3})
        audited = run("audit-job", root / "tests.txt", reports, "1/1")
        self.assertEqual(audited.returncode, 0, audited.stdout + audited.stderr)
        self.assertIn("selection 1/1: planned 5, executed 5", audited.stdout)
        # A planned test that did not run fails the audit.
        self.assertEqual(counts("1/1", [(f"{weighted}/a()", False)], XCTEST_STDOUT).returncode, 0)
        audited = run("audit-job", root / "tests.txt", reports, "1/1")
        self.assertEqual(audited.returncode, 1, audited.stdout + audited.stderr)
        self.assertIn("::error::Selection 1/1 executed 4 tests but its plan lists 5", audited.stdout)

    def test_each_job_audits_its_own_selections_and_the_last_the_whole_plan(self):
        # Seconds well above the fixed extra seconds, so each of the 4
        # selections gets a suite.
        weights = {"ProviderCoreTests.A": 300.0, "ProviderCoreTests.B": 250.0, "ProviderCoreTests.C": 200.0,
                   "ProviderCoreTests.D": 150.0}
        tests = ["ProviderCoreTests.A/a()", "ProviderCoreTests.B/b()", "ProviderCoreTests.C/c()",
                 "ProviderCoreTests.D/x()",
                 "ProviderCoreTests.New/d()", "ProviderCoreTests.ProcessMemoryNativeIntegrationTests/e()",
                 "ProviderCoreFoundationTests.Pure/f()", "ProviderCoreTests.ProductionPromptParityTests/p()",
                 "ProviderCoreTests.NemotronTemplateParityLiveTests/n()",
                 f"{shards.OWN_PROCESS_SUITES[0]}/s()"]
        parity = [{"shard": "parity", "pattern": name, "swift_testing": 1, "xctest": 0}
                  for name in ("ProductionPromptParityTests", "NemotronTemplateParityLiveTests")]

        def own(selections, processes=2, **changed):
            return [{"shard": selection, "pattern": ISOLATED, "processes": processes, "xctest": 0,
                     "swift_testing": changed.get(selection, len(shards.planned(tests, selection, ISOLATED,
                                                                                 weights, processes)))}
                    for selection in selections]

        # 2 jobs of 2 processes: job 1 runs the parallel class, the
        # own-process class, 1/4, 2/4 and Prompt Parity (PARITY_SHARD 2); job
        # 2 runs 3/4 and 4/4.
        first, second = own(("parallel", "own", "1/4", "2/4")) + parity, own(("3/4", "4/4"))
        self.assertEqual(len(shards.planned(tests, "own", ISOLATED, weights, 2)), 1)
        self.assertEqual(shards.audit_job(tests, first, ISOLATED, weights, 1, 2, 2), [])
        self.assertEqual(shards.audit_job(tests, second, ISOLATED, weights, 2, 2, 2), [])
        # A selection that ran one test too few, a missing one, parity in the
        # wrong job, or a report planned for another process count fails;
        # so does an own-process class that ran short, is missing from job 1
        # or ran in another job.
        self.assertTrue(shards.audit_job(tests, own(("3/4", "4/4"), **{"4/4": 0}), ISOLATED, weights, 2, 2, 2))
        self.assertTrue(shards.audit_job(tests, own(("3/4",)), ISOLATED, weights, 2, 2, 2))
        self.assertTrue(shards.audit_job(tests, second + parity, ISOLATED, weights, 2, 2, 2))
        self.assertTrue(shards.audit_job(tests, own(("parallel", "own", "1/4", "2/4")), ISOLATED, weights, 1, 2, 2))
        self.assertTrue(shards.audit_job(tests, own(("3/4", "4/4"), processes=1), ISOLATED, weights, 2, 2, 2))
        self.assertTrue(shards.audit_job(tests, own(("parallel", "own", "1/4", "2/4"), **{"own": 0}) + parity,
                                         ISOLATED, weights, 1, 2, 2))
        self.assertTrue(shards.audit_job(tests, own(("parallel", "1/4", "2/4")) + parity, ISOLATED, weights, 1, 2, 2))
        self.assertTrue(shards.audit_job(tests, second + own(("own",)), ISOLATED, weights, 2, 2, 2))
        # Every test is in exactly one plan, so the job audits add up to the
        # full-suite audit over all of the reports, which needs the own-process
        # class's report too.
        self.assertEqual(shards.audit(tests, first + second, ISOLATED, weights, 2), [])
        self.assertTrue(shards.audit(tests, [report for report in first + second if report["shard"] != "own"],
                                     ISOLATED, weights, 2))

    def test_audit_requires_every_shard_to_run_its_plan_and_the_sum_to_match(self):
        weights = {"ProviderCoreTests.A": 10.0, "ProviderCoreTests.B": 10.0}
        tests = ["ProviderCoreTests.A/a()", "ProviderCoreTests.A/b()", "ProviderCoreTests.B/c()",
                 "ProviderCoreTests.New/d()", "ProviderCoreTests.ProcessMemoryNativeIntegrationTests/e()",
                 "ProviderCoreFoundationTests.Pure/f()", "ProviderCoreTests.ProductionPromptParityTests/p()",
                 "ProviderCoreTests.ProductionPromptParityTests/q()",
                 "ProviderCoreTests.NemotronTemplateParityLiveTests/n()"]
        parity_counts = {"ProductionPromptParityTests": 2, "NemotronTemplateParityLiveTests": 1}

        def reports(parity=None, **changed):
            result = []
            for selection in ("parallel", "1/2", "2/2"):
                count = len(shards.planned(tests, selection, ISOLATED, weights))
                count = changed.get(selection, count)
                result.append({"shard": selection, "pattern": ISOLATED, "swift_testing": count, "xctest": 0})
            for pattern, count in (parity_counts if parity is None else parity).items():
                result.append({"shard": "parity", "pattern": pattern, "swift_testing": count, "xctest": 0})
            return result

        self.assertEqual(shards.audit(tests, reports(), ISOLATED, weights), [])
        # Prompt Parity: each suite ran once, with every listed test.
        partial = shards.audit(tests, reports({**parity_counts, "ProductionPromptParityTests": 1}), ISOLATED, weights)
        self.assertEqual(partial, ["Prompt Parity ProductionPromptParityTests executed 1 tests; the suite lists 2"])
        absent = shards.audit(tests, reports({"ProductionPromptParityTests": 2}), ISOLATED, weights)
        self.assertTrue(any("one Prompt Parity report per suite" in error for error in absent), absent)
        unlisted = [test for test in tests if "Nemotron" not in test]
        self.assertTrue(any("NemotronTemplateParityLiveTests executed 1 tests; the suite lists 0" in error
                            for error in shards.audit(unlisted, reports(), ISOLATED, weights)))
        short = shards.audit(tests, reports(**{"2/2": 5}), ISOLATED, weights)
        self.assertTrue(any("Shard 2/2 executed 5 tests" in error for error in short), short)
        self.assertTrue(any("The shards executed" in error for error in short), short)
        missing = shards.audit(tests, [r for r in reports() if r["shard"] != "1/2"], ISOLATED, weights)
        self.assertTrue(any("Expected one report per shard" in error for error in missing), missing)
        mixed = reports() + [{"shard": "1/3", "pattern": ISOLATED, "swift_testing": 1, "xctest": 0}]
        self.assertTrue(shards.audit(tests, mixed, ISOLATED, weights))

    def test_listed_tests_ignore_build_and_warning_lines(self):
        listed = shards.listed_tests("Building for debugging...\nwarning: something\n"
                                     "ProviderCoreTests.A/a()\nProviderCoreTests/B/b(selection:)\n\n")
        self.assertEqual(listed, ["ProviderCoreTests.A/a()", "ProviderCoreTests/B/b(selection:)"])

    def test_unweighted_serial_suites_are_reported(self):
        tests = ["ProviderCoreTests.A/a()", "ProviderCoreTests/New/b()", "ProviderCoreTests.freeFunction()",
                 "ProviderCoreFoundationTests.Pure/c()", "DarkbloomCLITests.Other/d()"]
        weights = {"ProviderCoreTests.A": 1.0, "DarkbloomCLITests.Other": 2.0}
        # Free functions have no suite and the parallel class has no weights to keep.
        self.assertEqual(shards.unweighted(tests, weights), ["ProviderCoreTests.New"])
        self.assertEqual(shards.unweighted(tests, {**weights, "ProviderCoreTests.New": 0.5}), [])
        # A suite that runs only in an isolated process needs no weight.
        isolated = [*tests, "ProviderCoreTests.ProcessMemoryNativeIntegrationTests/e()"]
        self.assertEqual(shards.unweighted(isolated, weights, ISOLATED), ["ProviderCoreTests.New"])

    def test_stale_weights_name_suites_no_selection_runs(self):
        tests = ["ProviderCoreTests.A/a()", "ProviderCoreTests.ProcessMemoryNativeIntegrationTests/e()"]
        weights = {"ProviderCoreTests.A": 1.0, "ProviderCoreTests.Removed": 2.0,
                   "ProviderCoreTests.ProcessMemoryNativeIntegrationTests": 3.0}
        self.assertEqual(shards.stale(tests, weights, ISOLATED),
                         ["ProviderCoreTests.ProcessMemoryNativeIntegrationTests", "ProviderCoreTests.Removed"])
        self.assertEqual(shards.stale(tests, {"ProviderCoreTests.A": 1.0}, ISOLATED), [])

    def test_weight_drift_warns_below_the_limit_and_fails_above_it(self):
        tests = ["ProviderCoreTests.A/a()", "ProviderCoreTests.New/b()", "ProviderCoreTests.Newer/c()"]
        weights = {"ProviderCoreTests.A": 1.0}
        limit = shards.UNWEIGHTED_SECONDS_LIMIT
        self.assertEqual(shards.weight_drift(tests, {**weights, "ProviderCoreTests.New": 1.0,
                                                     "ProviderCoreTests.Newer": 1.0}, ISOLATED, {}), ([], []))
        warnings, errors = shards.weight_drift(tests, weights, ISOLATED, {"ProviderCoreTests.New": limit / 2})
        self.assertEqual(errors, [])
        self.assertEqual(len(warnings), 1)
        self.assertIn("2 serial suites have no measured seconds", warnings[0])
        # The seconds of every unweighted suite count together.
        measured = {"ProviderCoreTests.New": limit / 2, "ProviderCoreTests.Newer": limit / 2 + 1}
        warnings, errors = shards.weight_drift(tests, weights, ISOLATED, measured)
        self.assertEqual(warnings, [])
        self.assertEqual(len(errors), 1)
        self.assertIn(f"{limit + 1:.0f} s in this run", errors[0])
        self.assertEqual(shards.missing_entries(tests, weights, ISOLATED, measured), measured)
        # Weights of removed suites only warn: they skew the plan, not the coverage.
        warnings, errors = shards.weight_drift(tests[:1], {**weights, "ProviderCoreTests.Gone": 5.0}, ISOLATED, {})
        self.assertEqual(errors, [])
        self.assertIn("1 weights name suites no selection runs (ProviderCoreTests.Gone)", warnings[0])

    def test_a_selection_whose_suites_outran_their_weights_warns(self):
        weights = {"ProviderCoreTests.A": 100.0, "ProviderCoreTests.B": 90.0, "ProviderCoreTests.C": 10.0}
        limit = shards.STALE_SELECTION_SECONDS
        with mock.patch.multiple(shards, FIRST_SHARD_EXTRA_SECONDS=0.0, PARITY_SHARD_EXTRA_SECONDS=0.0,
                                 LAST_SHARD_EXTRA_SECONDS=0.0):
            self.assertEqual(shards.assignment(2, weights)[0], [["ProviderCoreTests.A"],
                                                                ["ProviderCoreTests.B", "ProviderCoreTests.C"]])
            self.assertIsNone(shards.stale_selection("1/2", weights, 1, {"ProviderCoreTests.A": 100.0 + limit}))
            # Run 44696233902: one suite of selection 4 ran 181 s, weighed 26 s.
            longer = shards.stale_selection("1/2", weights, 1, {"ProviderCoreTests.A": 100.0 + limit + 1})
            self.assertIn(f"Selection 1/2 ran its suites for {100 + limit + 1:.0f} s, but their weights say 100 s "
                          f"(ProviderCoreTests.A 100 s -> {100 + limit + 1:.0f} s)", longer)
            # Shorter warns too: the other jobs then carry its share. The
            # last selection's unweighted suites count in weight_drift, not here.
            shorter = shards.stale_selection("2/2", weights, 1, {"ProviderCoreTests.B": 20.0, "ProviderCoreTests.C": 10.0})
            self.assertIn("ProviderCoreTests.B 90 s -> 20 s, ProviderCoreTests.C 10 s -> 10 s", shorter)
            self.assertIsNone(shards.stale_selection("2/2", weights, 1, {"ProviderCoreTests.B": 90.0,
                                                                         "ProviderCoreTests.C": 10.0,
                                                                         "ProviderCoreTests.New": 500.0}))

    def test_last_job_audit_fails_when_unweighted_suites_outgrow_the_limit(self):
        weighted = next(key for key in shards.load_weights() if key.startswith("DarkbloomCLITests."))
        new = "ProviderCoreTests.SuiteThatHasNoWeightYet"
        tests = [f"{weighted}/a()", f"{new}/b()", f"{new}/c()"]
        with tempfile.TemporaryDirectory(prefix="shard-drift-") as temporary:
            root = Path(temporary)
            listing = root / "tests.txt"
            listing.write_text("\n".join(tests) + "\n")
            reports = root / "reports"
            reports.mkdir()
            for shard, count in (("parallel", 0), ("1/1", 3)):
                name = shard.replace("/", "-of-")
                (reports / f"shard-{name}.json").write_text(json.dumps(
                    {"shard": shard, "pattern": ISOLATED, "processes": 1, "swift_testing": count, "xctest": 0}))

            def audit(seconds):
                (reports / "shard-1-of-1-swift-testing.xml").write_text(
                    '<testsuites><testsuite name="x">'
                    f'<testcase classname="{weighted}" name="a()" time="1"/>'
                    f'<testcase classname="{new}" name="b()" time="{seconds}"/>'
                    '</testsuite></testsuites>')
                # The XCTest case of the same suite comes from the selection's log.
                (reports / "shard-1-of-1.log").write_text(
                    f"Test Case '-[{new} c]' passed (1.000 seconds).\n")
                environment = {key: value for key, value in os.environ.items() if key != "PROVIDER_TEST_PROCESSES"}
                return subprocess.run(
                    ["python3", str(ROOT / "scripts/provider-test-shards.py"), "audit-job", str(listing),
                     str(reports), "1/1"], capture_output=True, text=True, env=environment)

            below = audit(shards.UNWEIGHTED_SECONDS_LIMIT - 2)
            self.assertEqual(below.returncode, 0, below.stdout + below.stderr)
            self.assertIn("::warning title=Provider shard weights::1 serial suites", below.stdout)
            # The one selection ran 1 s of the whole weighed serial suite: a
            # warning, never a failure.
            self.assertIn("selection 1/1: its suites ran 1 s", below.stdout)
            self.assertIn("::warning title=Provider shard weights::Selection 1/1 ran its suites for 1 s", below.stdout)
            above = audit(shards.UNWEIGHTED_SECONDS_LIMIT)
            self.assertEqual(above.returncode, 1, above.stdout + above.stderr)
            self.assertIn("::error title=Provider shard weights::1 serial suites", above.stdout)
            self.assertIn(f'"{new}": {shards.UNWEIGHTED_SECONDS_LIMIT + 1},', above.stdout)

    def test_weights_sum_xunit_cases_per_top_level_suite(self):
        with tempfile.TemporaryDirectory(prefix="shard-weights-") as temporary:
            path = Path(temporary) / "shard-1-of-2.xml"
            path.write_text('<testsuites><testsuite name="x">'
                            '<testcase classname="ProviderCoreTests.A" name="a" time="1.5"/>'
                            '<testcase classname="ProviderCoreTests.A.Nested" name="b" time="0.5"/>'
                            '<testcase classname="ProviderCoreTests" name="free()" time="9"/>'
                            '</testsuite></testsuites>')
            self.assertEqual(shards.measured_weights([path]), {"ProviderCoreTests.A": 2.0})
            # XCTest classes have no serial xUnit report; they keep their old seconds.
            base = {"ProviderCoreTests.A": 7.0, "ProviderCoreTests.XCTestClass": 3.0}
            self.assertEqual(shards.measured_weights([path], base),
                             {"ProviderCoreTests.A": 2.0, "ProviderCoreTests.XCTestClass": 3.0})

    def test_weights_read_xctest_cases_from_logs_once_and_prune_unmeasured_suites(self):
        with tempfile.TemporaryDirectory(prefix="shard-weights-") as temporary:
            report = Path(temporary) / "shard-1-of-2-swift-testing.xml"
            report.write_text('<testsuites><testsuite name="x">'
                              '<testcase classname="ProviderCoreTests.A" name="a()" time="1.5"/>'
                              '</testsuite></testsuites>')
            log = Path(temporary) / "shard-1-of-2.log"
            log.write_text("Test Case '-[ProviderCoreTests.XCTestClass testOne]' started.\n"
                           "Test Case '-[ProviderCoreTests.XCTestClass testOne]' passed (2.250 seconds).\n"
                           "Test Case '-[ProviderCoreTests.XCTestClass testTwo]' skipped (0.001 seconds).\n"
                           "Test Case '-[ProviderCoreTests.Other testThree]' failed (4 seconds).\n")
            # The process slot's output holds the same cases; they count once.
            slot = Path(temporary) / "slot-1-of-2.out"
            slot.write_text(log.read_text())
            base = {"ProviderCoreTests.A": 7.0, "ProviderCoreTests.Gone": 3.0}
            measured = {"ProviderCoreTests.A": 1.5, "ProviderCoreTests.Other": 4.0,
                        "ProviderCoreTests.XCTestClass": 2.251}
            self.assertEqual(shards.measured_weights([report, log, slot], base),
                             {**measured, "ProviderCoreTests.Gone": 3.0})
            self.assertEqual(shards.measured_weights([report, log, slot], base, prune=True), measured)
            # Without logs, pruning would drop every XCTest suite.
            with self.assertRaisesRegex(ValueError, "selection logs"):
                shards.measured_weights([report], base, prune=True)
            # --prune reads no checked-in weights, so a shell redirect may
            # empty the weights file before the command runs.
            emptied = Path(temporary) / "provider-test-shard-weights.json"
            emptied.write_text("")
            argv = ["provider-test-shards.py", "weights", "--prune", str(report), str(log)]
            with mock.patch.object(shards, "WEIGHTS", emptied), mock.patch.object(sys, "argv", argv), \
                    contextlib.redirect_stdout(io.StringIO()) as printed:
                self.assertEqual(shards.main(), 0)
            self.assertEqual(json.loads(printed.getvalue()), {"ProviderCoreTests.A": 1.5, "ProviderCoreTests.Other": 4.0,
                                                              "ProviderCoreTests.XCTestClass": 2.251})


class RunnerTests(unittest.TestCase):
    """run-provider-tests.sh with a recording `swift` in place of the toolchain."""

    def run_tests(self, shard=None, processes=None, status=0, stale_reports=(), **stub):
        temporary = tempfile.TemporaryDirectory(prefix="provider-shard-runner-")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        # Reports an earlier run left in the report directory.
        for name in stale_reports:
            (root / "reports").mkdir(exist_ok=True)
            (root / "reports" / name).write_text(swift_testing_report(("M.S/old()", False), ("M.S/older()", False)))
        calls, environments = root / "calls.jsonl", root / "environments.jsonl"
        self.starts = root / "starts.jsonl"
        swift = root / "swift"
        swift.write_text(textwrap.dedent("""\
            #!/usr/bin/env python3
            import json, os, sys, time
            with open(os.environ["STUB_CALLS"], "a") as calls:
                calls.write(json.dumps(sys.argv[1:]) + "\\n")
            with open(os.environ["STUB_STARTS"], "a") as starts:
                starts.write(json.dumps([time.time(), sys.argv[1:]]) + "\\n")
            with open(os.environ["STUB_ENVIRONMENTS"], "a") as environments:
                environments.write(json.dumps({name: os.environ.get(name) for name in (
                    "TMPDIR", "DARKBLOOM_STATE_FILE", "DARKBLOOM_LOADED_MODELS_FILE",
                    "DARKBLOOM_VERIFIED_WEIGHTS_FILE")}) + "\\n")
            split = bool(os.environ.get("STUB_SPLIT"))
            if "--xunit-output" in sys.argv and not os.environ.get("STUB_NO_XUNIT"):
                report = sys.argv[sys.argv.index("--xunit-output") + 1]
                open(report, "w").write("<testsuites/>")
                # Swift Testing's report, which the selection's counts and
                # scripts/run-nested-suite.sh read.
                cases = "".join(f'<testcase name="t{index}()" />' for index in range(29 if split else 2))
                open(report.removesuffix(".xml") + "-swift-testing.xml", "w").write(
                    f'<testsuites><testsuite tests="{29 if split else 2}">{cases}</testsuite></testsuites>')
            # SwiftPM's native build system: unless the build is planned in
            # memory (--disable-build-manifest-caching), `swift test
            # --skip-build` runs llbuild's package-structure step inside BEGIN
            # EXCLUSIVE on .build/build.db. A process that cannot get the
            # database reports it locked, runs its tests anyway and exits 1.
            # The holder keeps the database until STUB_PEERS processes have
            # tried it, as a slow step does while the others start. Exactly
            # one process holds it: an exclusive create decides, where SQLite's
            # BEGIN EXCLUSIVE with no wait can refuse every process that
            # starts at the same moment.
            locked = False
            if "--disable-build-manifest-caching" not in sys.argv:
                os.makedirs(".build", exist_ok=True)
                try:
                    holder = os.open(".build/build.db.holder", os.O_CREAT | os.O_EXCL | os.O_WRONLY)
                except FileExistsError:
                    locked = True
                with open(".build/attempts", "a") as attempts:
                    attempts.write(".")
                peers, deadline = int(os.environ.get("STUB_PEERS", "1")), time.monotonic() + 10
                while not locked and len(open(".build/attempts").read()) < peers and time.monotonic() < deadline:
                    time.sleep(0.01)
                if not locked:
                    os.close(holder)
                    os.unlink(".build/build.db.holder")
            if locked:
                print('error: unable to attach DB: error: accessing build database "/x/.build/build.db": '
                      'database is locked Possibly there are two concurrent builds running in the same '
                      'filesystem location.')
            if split:
                # Run 44909219943: SwiftPM's own warning, on its stderr, inside
                # the summary line the test process wrote to its stdout.
                for stream, text in (
                        (sys.stdout, "\\u2714 Test run with 29"),
                        (sys.stderr, "warning: '--build-system native' has been deprecated and will be removed "
                                     "in a future release\\n"),
                        (sys.stdout, " tests in 3 suites passed after 72.041 seconds.\\n")):
                    stream.flush()
                    stream.buffer.write(text.encode())
                    stream.buffer.flush()
            else:
                print("Test run with 2 tests in 1 suite passed after 0.1 seconds.")
            sys.exit(1 if locked else 0)
            """))
        swift.chmod(0o755)
        environment = {**os.environ, "PATH": f"{root}{os.pathsep}{os.environ['PATH']}",
                       "STUB_CALLS": str(calls), "STUB_ENVIRONMENTS": str(environments),
                       "STUB_STARTS": str(self.starts), "TMPDIR": str(root), **stub}
        environment.pop("PROVIDER_TEST_SHARD", None)
        environment.pop("PROVIDER_TEST_PROCESSES", None)
        if shard:
            environment.update(PROVIDER_TEST_SHARD=shard, PROVIDER_TEST_REPORT_DIR=str(root / "reports"))
        if processes is not None:
            environment["PROVIDER_TEST_PROCESSES"] = processes
        result = subprocess.run(["bash", str(ROOT / "scripts/run-provider-tests.sh")], cwd=root,
                                env=environment, text=True, capture_output=True, timeout=60)
        self.assertEqual(result.returncode, status, result.stdout + result.stderr)
        self.result, self.reports = result, root / "reports"
        if status:
            return result
        self.environments = [json.loads(line) for line in environments.read_text().splitlines()]
        return [json.loads(line) for line in calls.read_text().splitlines()], root / "reports"

    def test_unsharded_run_is_one_serial_suite_and_every_isolated_process(self):
        calls, _ = self.run_tests()
        self.assertEqual(calls[0][:3], ["test", "--skip-build", "--no-parallel"])
        self.assertEqual(calls[0][3], "--skip")
        self.assertNotIn("--filter", calls[0])
        self.assertEqual(len(calls), 10)

    def test_middle_shard_runs_only_its_serial_selection(self):
        calls, reports = self.run_tests("2/4")
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][:4], ["test", "--skip-build", "--no-parallel", "--filter"])
        self.assertIn("--xunit-output", calls[0])
        report = json.loads((reports / "shard-2-of-4.json").read_text())
        self.assertEqual(report["shard"], "2/4")
        self.assertEqual(report["swift_testing"], 2)

    def test_counts_survive_a_warning_inside_the_summary_line(self):
        # Run 44909219943: SwiftPM's stderr warning split `✔ Test run with 29`
        # from ` tests in 3 suites passed`. Each selection's counts read its
        # xUnit report and stdout alone, which the warning never enters; the
        # warning still reaches the output, and slot-*.out beside the stdout.
        for shard, processes, names in (("2/4", "1", ["2-of-4"]),
                                        ("1/2", "3", ["1-of-6", "2-of-6", "3-of-6", "own", "parallel"])):
            with self.subTest(processes=processes):
                _, reports = self.run_tests(shard, processes=processes, STUB_SPLIT="1")
                for name in names:
                    self.assertEqual(json.loads((reports / f"shard-{name}.json").read_text())["swift_testing"], 29)
                    log = (reports / f"shard-{name}.log").read_text()
                    self.assertIn("✔ Test run with 29 tests in 3 suites passed", log)
                    self.assertNotIn("warning:", log)
                output = self.result.stdout + self.result.stderr
                self.assertIn("warning: '--build-system native' has been deprecated", output)
                for slot in reports.glob("slot-*.out"):
                    self.assertIn("warning: '--build-system native'", slot.read_text())

    def test_a_selection_without_its_report_fails_beside_an_earlier_one(self):
        result = self.run_tests("2/4", status=1, stale_reports=["shard-2-of-4-swift-testing.xml"],
                                STUB_NO_XUNIT="1")
        self.assertIn("::error::Selection 2/4: No Swift Testing xUnit report", result.stdout)
        self.assertFalse((self.reports / "shard-2-of-4-swift-testing.xml").exists())
        self.assertFalse((self.reports / "shard-2-of-4.json").exists())

    def test_first_shard_also_runs_the_parallel_class(self):
        calls, reports = self.run_tests("1/4")
        self.assertEqual(len(calls), 2)
        self.assertIn("--no-parallel", calls[0])
        self.assertNotIn("--no-parallel", calls[1])
        self.assertEqual(calls[1][calls[1].index("--filter") + 1], shards.parallel_regex())
        self.assertTrue((reports / "shard-parallel.json").is_file())

    def test_last_shard_runs_the_catch_all_and_every_isolated_process(self):
        calls, _ = self.run_tests("4/4")
        self.assertEqual(len(calls), 10)
        self.assertEqual(calls[0][:4], ["test", "--skip-build", "--no-parallel", "--skip"])
        self.assertNotIn("--filter", calls[0])


    def selection_of(self, call):
        """The selection a recorded `swift test` call ran, from its xUnit report name."""
        return call[call.index("--xunit-output") + 1].rsplit("/shard-", 1)[1].removesuffix(".xml")

    def test_one_process_keeps_the_single_selection_command_line(self):
        calls, _ = self.run_tests("2/4", processes="1")
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][:4], ["test", "--skip-build", "--no-parallel", "--filter"])

    def test_processes_run_their_selections_beside_each_other_with_their_own_files(self):
        calls, reports = self.run_tests("1/2", processes="3")
        # Job 1 of 2 with 3 processes runs selections 1 to 3 of 6 and, in a
        # fourth process, the own-process class; selection 1's process also
        # runs the parallel class. No isolated process runs.
        self.assertEqual(sorted(self.selection_of(call) for call in calls),
                         ["1-of-6", "2-of-6", "3-of-6", "own", "parallel"])
        for call in calls:
            self.assertEqual(call[:4], ["test", "--skip-build", "--ignore-lock", "--disable-build-manifest-caching"])
        for name in ("1-of-6", "2-of-6", "3-of-6", "own", "parallel"):
            self.assertTrue((reports / f"shard-{name}.json").is_file(), name)
        # Each process has its own TMPDIR and state files; the parallel class
        # shares selection 1's, as it runs after it in the same slot.
        directories = {environment["TMPDIR"] for environment in self.environments}
        states = {environment["DARKBLOOM_STATE_FILE"] for environment in self.environments}
        self.assertEqual(len(directories), 4)
        self.assertEqual(len(states), 4)
        for environment in self.environments:
            self.assertTrue(environment["DARKBLOOM_STATE_FILE"].startswith(str(Path(environment["TMPDIR"]).parent)))

    def test_a_jobs_processes_start_together(self):
        # They started 15 s apart while a process that started beside another
        # could find .build/build.db locked; none opens it now, and a wait
        # would only delay the job's later selections (run 44898503457).
        self.run_tests("1/2", processes="3")
        starts = [started for started, call in map(json.loads, self.starts.read_text().splitlines())
                  if self.selection_of(call) != "parallel"]
        self.assertEqual(len(starts), 4)
        self.assertLess(max(starts) - min(starts), 5.0)

    def test_job_one_runs_the_own_process_class_beside_its_selections(self):
        # Serial, with the shared-build flags of its job's selections, the
        # filter of a selection that held only those suites, its own report;
        # the last selection skips them. No other job, and no job of one
        # process, runs it.
        calls, reports = self.run_tests("1/2", processes="3")
        own = next(call for call in calls if self.selection_of(call) == "own")
        second = next(call for call in calls if self.selection_of(call) == "2-of-6")
        self.assertEqual(own[:7], ["test", "--skip-build", "--ignore-lock", "--disable-build-manifest-caching",
                                   "--no-parallel", "--filter", shards.suites_regex(shards.OWN_PROCESS_SUITES)])
        self.assertEqual(own[7:9], second[second.index("--skip"):second.index("--skip") + 2])
        self.assertEqual(json.loads((reports / "shard-own.json").read_text())["shard"], "own")
        self.assertTrue((reports / "slot-own.out").is_file())
        calls, _ = self.run_tests("2/2", processes="3")
        catch_all = next(call for call in calls[:3] if self.selection_of(call) == "6-of-6")
        self.assertIn(shards.suites_regex(shards.OWN_PROCESS_SUITES), catch_all[catch_all.index("--skip") + 1])
        for shard, processes in (("2/2", "3"), ("1/2", "1")):
            with self.subTest(shard=shard, processes=processes):
                calls, reports = self.run_tests(shard, processes=processes)
                self.assertFalse([call for call in calls if any("/shard-own" in argument for argument in call)])
                self.assertFalse((reports / "shard-own.json").exists())

    def test_last_job_runs_its_selections_then_every_isolated_process_alone(self):
        calls, reports = self.run_tests("2/2", processes="3")
        self.assertEqual(sorted(self.selection_of(call) for call in calls[:3]), ["4-of-6", "5-of-6", "6-of-6"])
        catch_all = next(call for call in calls[:3] if self.selection_of(call) == "6-of-6")
        self.assertNotIn("--filter", catch_all)
        # The isolated processes and the exclusive GPU test run after all
        # selections, one at a time, with SwiftPM's defaults.
        self.assertEqual(len(calls), 3 + 9)
        for call in calls[3:]:
            self.assertNotIn("--ignore-lock", call)
            self.assertNotIn("--disable-build-manifest-caching", call)
        self.assertEqual(len({environment["TMPDIR"] for environment in self.environments[3:]}), 1)

    def test_processes_that_start_together_never_meet_on_the_build_database(self):
        # Runs 44891331193 and 44889529003: selection 12 started beside 10 and
        # 11, waited 5 s for .build/build.db while another process's SwiftPM
        # held it in its package-structure step, ran every test and exited 1.
        # The processes now plan in memory and never open the database, so all
        # of them pass even when they start together and a holder keeps it.
        calls, reports = self.run_tests("1/2", processes="3", STUB_PEERS="3")
        self.assertEqual(sorted(self.selection_of(call) for call in calls),
                         ["1-of-6", "2-of-6", "3-of-6", "own", "parallel"])
        # The slot output holds both streams of its selections.
        for name in ("1-of-6", "2-of-6", "3-of-6", "own"):
            self.assertNotIn("database is locked", (reports / f"slot-{name}.out").read_text())
        self.assertEqual(sorted(path.name for path in reports.iterdir() if not path.name.startswith("shard-")),
                         ["slot-1-of-6.out", "slot-2-of-6.out", "slot-3-of-6.out", "slot-own.out"])
        # The stub is SwiftPM's lock: without the flag, processes that start
        # together find the database locked.
        temporary = tempfile.TemporaryDirectory(prefix="provider-build-database-")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        environment = {**os.environ, "STUB_PEERS": "3", "STUB_CALLS": os.devnull, "STUB_ENVIRONMENTS": os.devnull,
                       "STUB_STARTS": os.devnull}
        stub = reports.parent / "swift"
        for flags, expected in (([], [0, 1, 1]), (["--disable-build-manifest-caching"], [0, 0, 0])):
            with self.subTest(flags=flags):
                (root / ".build").mkdir(exist_ok=True)
                (root / ".build/attempts").write_text("")
                children = [subprocess.Popen([str(stub), "test", "--skip-build", "--ignore-lock", *flags], cwd=root,
                                             env=environment, stdout=subprocess.PIPE, text=True) for _ in range(3)]
                outputs = [child.communicate(timeout=30)[0] for child in children]
                self.assertEqual(sorted(child.returncode for child in children), expected)
                self.assertEqual(sum("database is locked" in output for output in outputs), expected.count(1))

    def test_invalid_job_or_process_count_refuses_before_any_test(self):
        for shard, processes in (("3/2", "3"), ("0/2", "3"), ("1/2", "0"), ("1/2", "10"), ("1/2", "x"), ("x", "1")):
            with self.subTest(shard=shard, processes=processes):
                result = self.run_tests(shard, processes=processes, status=2)
                self.assertIn("PROVIDER_TEST_SHARD must be K/N", result.stderr)


if __name__ == "__main__":
    unittest.main()
