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
        for module in ("ProviderCoreTests", "DarkbloomCLITests", "ServingQualificationTests",
                       "GPTOSSOptimizationTests"):
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


class RunnerTests(unittest.TestCase):
    """run-provider-tests.sh with a recording `swift` in place of the toolchain."""

    def run_tests(self, shard=None):
        temporary = tempfile.TemporaryDirectory(prefix="provider-shard-runner-")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        calls = root / "calls.jsonl"
        swift = root / "swift"
        swift.write_text(textwrap.dedent("""\
            #!/usr/bin/env python3
            import json, os, sys
            with open(os.environ["STUB_CALLS"], "a") as calls:
                calls.write(json.dumps(sys.argv[1:]) + "\\n")
            print("Test run with 2 tests in 1 suite passed after 0.1 seconds.")
            """))
        swift.chmod(0o755)
        environment = {**os.environ, "PATH": f"{root}{os.pathsep}{os.environ['PATH']}",
                       "STUB_CALLS": str(calls), "TMPDIR": str(root)}
        environment.pop("PROVIDER_TEST_SHARD", None)
        if shard:
            environment.update(PROVIDER_TEST_SHARD=shard, PROVIDER_TEST_REPORT_DIR=str(root / "reports"))
        result = subprocess.run(["bash", str(ROOT / "scripts/run-provider-tests.sh")], cwd=root,
                                env=environment, text=True, capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
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


if __name__ == "__main__":
    unittest.main()
