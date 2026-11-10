#!/usr/bin/env python3
"""Offline checks of the provider test shards: classes, partition, counts and audit."""

import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import textwrap
import unittest


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
        # Weights well above the fixed extra seconds of shards 1 and N.
        assigned, loads = shards.assignment(2, {"M.A": 1000.0, "M.B": 900.0, "M.C": 200.0, "M.D": 100.0})
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
        _, loads = shards.assignment(6, {}, processes=3)
        self.assertEqual(loads, [first + parity, parity, parity, last, last, last])
        with self.assertRaisesRegex(ValueError, "do not make jobs"):
            shards.assignment(5, {}, processes=3)
        # Every listed test still runs in exactly one selection of a job plan
        # (2 jobs of 2 processes: this fixture has 5 serial suites).
        plans = {selection: shards.planned(self.tests, selection, ISOLATED, self.weights, 2)
                 for selection in ("parallel", *(f"{index}/4" for index in range(1, 5)))}
        selected = [test for plan in plans.values() for test in plan]
        self.assertEqual(len(selected), len(set(selected)))
        self.assertEqual(set(selected), {test for test in self.tests if not re.search(ISOLATED, test)})

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


class CountAndAuditTests(unittest.TestCase):
    LOG = textwrap.dedent("""\
        Test Suite 'Selected tests' started at 2026-10-29 12:25:40.000.
        Test Suite 'Selected tests' passed at 2026-10-29 12:26:47.783.
        \t Executed 3 tests, with 1 test skipped and 0 failures (0 unexpected) in 1.0 (1.0) seconds
        ✔ Test run with 4 tests in 2 suites passed after 1.000 seconds.
        """)

    def test_counts_read_both_frameworks_and_failures(self):
        self.assertEqual(shards.counts(self.LOG), {"swift_testing": 4, "xctest": 3})
        failed = self.LOG.replace("passed after 1.000 seconds.", "failed after 1.000 seconds with 2 issues.")
        self.assertEqual(shards.counts(failed), {"swift_testing": 4, "xctest": 3})
        self.assertEqual(shards.counts("✔ Test run with 1 test in 1 suite passed after 0.1 seconds."),
                         {"swift_testing": 1, "xctest": 0})
        # A shard run without a Swift Testing summary did not finish, even
        # when its XCTest pass did.
        xctest_only = "Test Suite 'Selected tests' passed at x\n Executed 2 tests, with 0 failures"
        with self.assertRaisesRegex(ValueError, "did not finish"):
            shards.counts(xctest_only)
        # A parity selection of only XCTest cases (Nemotron) prints no Swift Testing summary.
        self.assertEqual(shards.counts(xctest_only, xctest_only=True), {"swift_testing": 0, "xctest": 2})
        with self.assertRaisesRegex(ValueError, "did not finish"):
            shards.counts("Test Suite 'Selected tests' started at x\nfatal error", xctest_only=True)
        with self.assertRaisesRegex(ValueError, "zero tests"):
            shards.counts("✔ Test run with 0 tests passed after 0.001 seconds.")

    def test_each_job_audits_its_own_selections_and_the_last_the_whole_plan(self):
        # Seconds well above the fixed extra seconds, so each of the 4
        # selections gets a suite.
        weights = {"ProviderCoreTests.A": 300.0, "ProviderCoreTests.B": 250.0, "ProviderCoreTests.C": 200.0,
                   "ProviderCoreTests.D": 150.0}
        tests = ["ProviderCoreTests.A/a()", "ProviderCoreTests.B/b()", "ProviderCoreTests.C/c()",
                 "ProviderCoreTests.D/x()",
                 "ProviderCoreTests.New/d()", "ProviderCoreTests.ProcessMemoryNativeIntegrationTests/e()",
                 "ProviderCoreFoundationTests.Pure/f()", "ProviderCoreTests.ProductionPromptParityTests/p()",
                 "ProviderCoreTests.NemotronTemplateParityLiveTests/n()"]
        parity = [{"shard": "parity", "pattern": name, "swift_testing": 1, "xctest": 0}
                  for name in ("ProductionPromptParityTests", "NemotronTemplateParityLiveTests")]

        def own(selections, processes=2, **changed):
            return [{"shard": selection, "pattern": ISOLATED, "processes": processes, "xctest": 0,
                     "swift_testing": changed.get(selection, len(shards.planned(tests, selection, ISOLATED,
                                                                                 weights, processes)))}
                    for selection in selections]

        # 2 jobs of 2 processes: job 1 runs the parallel class, 1/4, 2/4 and
        # Prompt Parity (PARITY_SHARD 2); job 2 runs 3/4 and 4/4.
        first, second = own(("parallel", "1/4", "2/4")) + parity, own(("3/4", "4/4"))
        self.assertEqual(shards.audit_job(tests, first, ISOLATED, weights, 1, 2, 2), [])
        self.assertEqual(shards.audit_job(tests, second, ISOLATED, weights, 2, 2, 2), [])
        # A selection that ran one test too few, a missing one, parity in the
        # wrong job, or a report planned for another process count fails.
        self.assertTrue(shards.audit_job(tests, own(("3/4", "4/4"), **{"4/4": 0}), ISOLATED, weights, 2, 2, 2))
        self.assertTrue(shards.audit_job(tests, own(("3/4",)), ISOLATED, weights, 2, 2, 2))
        self.assertTrue(shards.audit_job(tests, second + parity, ISOLATED, weights, 2, 2, 2))
        self.assertTrue(shards.audit_job(tests, own(("parallel", "1/4", "2/4")), ISOLATED, weights, 1, 2, 2))
        self.assertTrue(shards.audit_job(tests, own(("3/4", "4/4"), processes=1), ISOLATED, weights, 2, 2, 2))
        # Every test is in exactly one plan, so the job audits add up to the
        # full-suite audit over all of the reports.
        self.assertEqual(shards.audit(tests, first + second, ISOLATED, weights, 2), [])

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

    def test_weights_sum_xunit_cases_per_top_level_suite(self):
        with tempfile.TemporaryDirectory(prefix="shard-weights-") as temporary:
            path = Path(temporary) / "shard-1-of-2.xml"
            path.write_text('<testsuites><testsuite name="x">'
                            '<testcase classname="ProviderCoreTests.A" name="a" time="1.5"/>'
                            '<testcase classname="ProviderCoreTests.A.Nested" name="b" time="0.5"/>'
                            '<testcase classname="ProviderCoreTests" name="free()" time="9"/>'
                            '</testsuite></testsuites>')
            self.assertEqual(shards.measured_weights([path]), {"ProviderCoreTests.A": 2.0})
            # A retried selection's first attempt never counts twice.
            first = Path(temporary) / "attempt-1-shard-1-of-2.xml"
            first.write_text(path.read_text())
            self.assertEqual(shards.measured_weights([path, first]), {"ProviderCoreTests.A": 2.0})
            # XCTest classes have no serial xUnit report; they keep their old seconds.
            base = {"ProviderCoreTests.A": 7.0, "ProviderCoreTests.XCTestClass": 3.0}
            self.assertEqual(shards.measured_weights([path], base),
                             {"ProviderCoreTests.A": 2.0, "ProviderCoreTests.XCTestClass": 3.0})


_LOCK_SPEC = importlib.util.spec_from_file_location("swift_test_lock_retry", ROOT / "scripts/swift_test_lock_retry.py")
lock_retry = importlib.util.module_from_spec(_LOCK_SPEC)
_LOCK_SPEC.loader.exec_module(lock_retry)


class LockRetryTests(unittest.TestCase):
    """Only a log whose every test passed, beside the lock message, runs again."""

    LOCKED = ('error: unable to attach DB: error: accessing build database "/Users/runner/_work/d-inference/'
              'd-inference/provider-swift/.build/build.db": database is locked Possibly there are two '
              'concurrent builds running in the same filesystem location.\n')
    LOCKED_ACCESS = ('error: error: accessing build database "/private/tmp/dinf/libs/darkbloom-cluster/.build/build.db": '
                     'database is locked Possibly there are two concurrent builds running in the same filesystem location.\n')
    XCTEST = "\t Executed 54 tests, with 8 tests skipped and 0 failures (0 unexpected) in 7.575 (7.581) seconds\n"
    PASSED = "\u2714 Test run with 940 tests in 126 suites passed after 164.700 seconds.\n"

    def test_lock_and_every_test_passed_runs_again(self):
        # Run 41970825476, selection 1-of-6: the lock, then passing summaries.
        self.assertTrue(lock_retry.only_locked(self.LOCKED + self.XCTEST + self.PASSED))
        self.assertTrue(lock_retry.only_locked(self.LOCKED + "Test run with 1 test passed after 0.1 seconds.\n"))
        # Run 42057277814: SwiftPM's other wording of the same lock.
        self.assertTrue(lock_retry.only_locked(self.LOCKED_ACCESS + self.XCTEST + self.PASSED))

    def test_the_other_wording_keeps_the_rule(self):
        # Without a passing summary, or with any failure, it never runs again.
        for text in (self.LOCKED_ACCESS + self.XCTEST,
                     self.LOCKED_ACCESS + "\u2718 Test run with 2 tests failed after 0.1 seconds with 1 issue.\n",
                     # A database message that is not the lock is not the lock.
                     'error: error: accessing build database "/x/.build/build.db": disk I/O error\n' + self.PASSED):
            with self.subTest(text=text):
                self.assertFalse(lock_retry.only_locked(text))

    def test_any_failure_or_missing_proof_does_not_run_again(self):
        cases = {
            "no lock": self.XCTEST + self.PASSED,
            "no Swift Testing summary": self.LOCKED + self.XCTEST,
            "an XCTest failure": self.LOCKED + self.XCTEST.replace("0 failures (0", "1 failure (1") + self.PASSED,
            "an XCTest case failed": self.LOCKED + "Test Case '-[A b]' failed (0.1 seconds).\n" + self.PASSED,
            "a Swift Testing issue": self.LOCKED + "\u2718 Test b() recorded an issue at A.swift:3:5\n" + self.PASSED,
            "a failed run": self.LOCKED + "\u2718 Test run with 2 tests failed after 0.1 seconds with 1 issue.\n",
            "a tripwire": self.LOCKED + self.PASSED + "::error::filter executed ZERO tests\n",
        }
        for name, text in cases.items():
            with self.subTest(case=name):
                self.assertFalse(lock_retry.only_locked(text))


class RunnerTests(unittest.TestCase):
    """run-provider-tests.sh with a recording `swift` in place of the toolchain."""

    def run_tests(self, shard=None, processes=None, status=0, **stub):
        temporary = tempfile.TemporaryDirectory(prefix="provider-shard-runner-")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        calls, environments = root / "calls.jsonl", root / "environments.jsonl"
        swift = root / "swift"
        swift.write_text(textwrap.dedent("""\
            #!/usr/bin/env python3
            import json, os, sys
            with open(os.environ["STUB_CALLS"], "a") as calls:
                calls.write(json.dumps(sys.argv[1:]) + "\\n")
            with open(os.environ["STUB_ENVIRONMENTS"], "a") as environments:
                environments.write(json.dumps({name: os.environ.get(name) for name in (
                    "TMPDIR", "DARKBLOOM_STATE_FILE", "DARKBLOOM_LOADED_MODELS_FILE",
                    "DARKBLOOM_VERIFIED_WEIGHTS_FILE")}) + "\\n")
            # STUB_LOCKED=once: the first run of each selection finds the build
            # database locked, as SwiftPM reports it, passes its tests and
            # exits 1. STUB_LOCKED=once-access: the same with SwiftPM's other
            # wording (run 42057277814). STUB_LOCKED=always: every run does.
            # STUB_LOCKED=failed: the first run finds it locked and a test fails.
            mode = os.environ.get("STUB_LOCKED")
            report = sys.argv[sys.argv.index("--xunit-output") + 1] if "--xunit-output" in sys.argv else ""
            seen = report + ".seen"
            first = bool(report) and not os.path.exists(seen)
            locked = mode == "always" or (mode in ("once", "once-access", "failed") and first)
            if report:
                open(seen, "a").close()
                open(report, "w").write(f"<testsuites><!-- attempt {'1' if first else '2'} --></testsuites>")
            if locked and mode == "once-access":
                print('error: error: accessing build database "/x/.build/build.db": database is locked '
                      'Possibly there are two concurrent builds running in the same filesystem location.')
            elif locked:
                print('error: unable to attach DB: error: accessing build database "/x/.build/build.db": '
                      'database is locked Possibly there are two concurrent builds running in the same '
                      'filesystem location.')
            if locked and mode == "failed":
                print('✘ Test "contended" recorded an issue at A.swift:1:1: Expectation failed')
                print("✘ Test run with 2 tests in 1 suite failed after 0.1 seconds with 1 issue.")
            else:
                print("Test run with 2 tests in 1 suite passed after 0.1 seconds.")
            sys.exit(1 if locked else 0)
            """))
        swift.chmod(0o755)
        environment = {**os.environ, "PATH": f"{root}{os.pathsep}{os.environ['PATH']}",
                       "STUB_CALLS": str(calls), "STUB_ENVIRONMENTS": str(environments), "TMPDIR": str(root),
                       "PROVIDER_TEST_START_GAP": "0", **stub}
        environment.pop("PROVIDER_TEST_SHARD", None)
        environment.pop("PROVIDER_TEST_PROCESSES", None)
        if shard:
            environment.update(PROVIDER_TEST_SHARD=shard, PROVIDER_TEST_REPORT_DIR=str(root / "reports"))
        if processes is not None:
            environment["PROVIDER_TEST_PROCESSES"] = processes
        result = subprocess.run(["bash", str(ROOT / "scripts/run-provider-tests.sh")], cwd=root,
                                env=environment, text=True, capture_output=True, timeout=60)
        self.assertEqual(result.returncode, status, result.stdout + result.stderr)
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
        # Job 1 of 2 with 3 processes runs selections 1 to 3 of 6, and selection
        # 1's process also runs the parallel class; no isolated process runs.
        self.assertEqual(sorted(self.selection_of(call) for call in calls),
                         ["1-of-6", "2-of-6", "3-of-6", "parallel"])
        for call in calls:
            self.assertEqual(call[:3], ["test", "--skip-build", "--ignore-lock"])
        for name in ("1-of-6", "2-of-6", "3-of-6", "parallel"):
            self.assertTrue((reports / f"shard-{name}.json").is_file(), name)
        # Each process has its own TMPDIR and state files; the parallel class
        # shares selection 1's, as it runs after it in the same slot.
        directories = {environment["TMPDIR"] for environment in self.environments}
        states = {environment["DARKBLOOM_STATE_FILE"] for environment in self.environments}
        self.assertEqual(len(directories), 3)
        self.assertEqual(len(states), 3)
        for environment in self.environments:
            self.assertTrue(environment["DARKBLOOM_STATE_FILE"].startswith(str(Path(environment["TMPDIR"]).parent)))

    def test_last_job_runs_its_selections_then_every_isolated_process_alone(self):
        calls, reports = self.run_tests("2/2", processes="3")
        self.assertEqual(sorted(self.selection_of(call) for call in calls[:3]), ["4-of-6", "5-of-6", "6-of-6"])
        catch_all = next(call for call in calls[:3] if self.selection_of(call) == "6-of-6")
        self.assertNotIn("--filter", catch_all)
        # The isolated processes and the exclusive GPU test run after all
        # selections, one at a time, without the lock override.
        self.assertEqual(len(calls), 3 + 9)
        for call in calls[3:]:
            self.assertNotIn("--ignore-lock", call)
        self.assertEqual(len({environment["TMPDIR"] for environment in self.environments[3:]}), 1)

    def test_a_selection_that_finds_the_build_database_locked_runs_once_more(self):
        # Beside other processes, SwiftPM's startup can find build.db locked;
        # it runs the tests and exits 1. The selection runs once more.
        calls, reports = self.run_tests("1/2", processes="3", STUB_LOCKED="once")
        self.assertEqual(sorted(self.selection_of(call) for call in calls),
                         sorted(["1-of-6", "2-of-6", "3-of-6", "parallel"] * 2))
        # The first attempt's log and xUnit report stay beside the second's.
        for name in ("1-of-6", "2-of-6", "3-of-6", "parallel"):
            self.assertIn("database is locked", (reports / f"attempt-1-shard-{name}.log").read_text())
            self.assertIn("attempt 1", (reports / f"attempt-1-shard-{name}.xml").read_text())
            self.assertIn("attempt 2", (reports / f"shard-{name}.xml").read_text())
            self.assertNotIn("database is locked", (reports / f"shard-{name}.log").read_text())
        # SwiftPM's other wording of the lock runs once more as well.
        calls, _ = self.run_tests("1/2", processes="3", STUB_LOCKED="once-access")
        self.assertEqual(sorted(self.selection_of(call) for call in calls),
                         sorted(["1-of-6", "2-of-6", "3-of-6", "parallel"] * 2))
        # A test that failed beside the lock fails the job: no second attempt.
        result = self.run_tests("1/2", processes="3", STUB_LOCKED="failed", status=1)
        self.assertIn("Expectation failed", result.stdout)
        self.assertNotIn("running the selection once more", result.stdout)
        # Only once: a second lock fails the job.
        self.run_tests("1/2", processes="3", STUB_LOCKED="always", status=1)
        # One process has no other process to meet: no retry.
        self.run_tests("2/4", processes="1", STUB_LOCKED="once", status=1)

    def test_invalid_job_or_process_count_refuses_before_any_test(self):
        for shard, processes in (("3/2", "3"), ("0/2", "3"), ("1/2", "0"), ("1/2", "10"), ("1/2", "x"), ("x", "1")):
            with self.subTest(shard=shard, processes=processes):
                result = self.run_tests(shard, processes=processes, status=2)
                self.assertIn("PROVIDER_TEST_SHARD must be K/N", result.stderr)


if __name__ == "__main__":
    unittest.main()
