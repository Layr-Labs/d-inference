#!/usr/bin/env python3
"""Offline checks of the cluster test plan and the jobs that run it."""

import importlib.util
import io
import os
from pathlib import Path
import re
import sys
import tempfile
import time
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parent.parent
_SPEC = importlib.util.spec_from_file_location("cluster_test_plan", ROOT / "scripts/cluster-test-plan.py")
plan = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(plan)
_SPEC = importlib.util.spec_from_file_location("provider_workflow", ROOT / "scripts/test-provider-ci-workflow.py")
workflow = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(workflow)


def selected(selection, test_id):
    """Whether `swift test` with this selection's filter and skip runs `test_id`."""
    filter_regex, *extra = plan.swift_arguments(selection)
    skip = extra[extra.index("--skip") + 1] if "--skip" in extra else None
    return bool(re.search(filter_regex, test_id)) and not (skip and re.search(skip, test_id))


class ClusterTestPlanTests(unittest.TestCase):
    def setUp(self):
        self.jobs = {**workflow.job_blocks(plan.WORKFLOW.read_text()),
                     **workflow.job_blocks(workflow.PLAN_WORKFLOW.read_text().split("\njobs:\n", 1)[1])}

    def test_plan_names_every_gated_test_and_runner(self):
        self.assertEqual(plan.audit(), [])

    def test_every_test_runs_in_exactly_one_selection_unless_it_needs_a_model(self):
        module = plan.MODULE
        swift = [selection for selection in plan.SELECTIONS if selection.runner is None]
        cases = {f"{module}.AnySuite/{name}(sharded:)": name for selection in swift for name in selection.tests}
        cases.update({
            f"{module}.QwenTensorParallelBatchSessionTests/actualShardsBatchIndependentHistories()": "base-batch-session",
            f"{module}.QwenTensorParallelBatchSessionTests/Nested/plainCase()": "base-batch-session",
            # The prefix tier tests of the suite, and only of that suite, run in their own process.
            f"{module}.QwenTensorParallelBatchSessionTests/warmAttentionPrefixesPreserveMixedHistoriesAndRetirement()":
                "base-batch-session-prefix-tiers",
            f"{module}.QwenTensorParallelBatchSessionTests/ssdBalancedRecordsAdoptOnBothRanksWithAnExactBand()":
                "base-batch-session-prefix-tiers",
            f"{module}.QwenTensorParallelBatchSessionTests/Nested/ssdAttentionPrefixesRestoreAfterTheTiersReopen()":
                "base-batch-session",
            f"{module}.QwenTensorParallelBatchSessionTestsMore/ssdAttentionPrefixesRestoreAfterTheTiersReopen()":
                "base",
            f"{module}.PrefixCacheContractTests/plannedFramesStartAtTheReusedPrefix()": "base",
            f"{module}.QwenBatchCancellationTests/testAcceptedStartStaysCharged": "base",
            f"{module}.QwenTensorParallelBatchSessionTestsMore/plainCase()": "base",
            f"{module}.Gemma4TensorParallelTests/plainCase()": "base-gemma-tensor-parallel",
            f"{module}.Gemma4BatchDecodeTests/plainCase()": "base-gemma",
            f"{module}/ResidentAdmissionGemma4Tests/Nested/plainCase()": "base-gemma",
            f"{module}.Gemma4TensorParallelTestsMore/plainCase()": "base",
            # A switched test of a Gemma suite runs only in its switch's selection.
            f"{module}.Gemma4TensorParallelTests/diagnosticShardOperationsEqualWholeOperations()": "gemma-tp-diag",
        })
        for test_id, owner in cases.items():
            with self.subTest(test_id=test_id):
                runs = [selection for selection in swift if selected(selection, test_id)]
                self.assertEqual(len(runs), 1, [selection.name for selection in runs])
                runner = runs[0]
                self.assertTrue(runner.name == owner or owner in runner.tests, runner.name)
        needs_model = [f"{module}.AnySuite/{name}()" for name in plan.REQUIRES_MODEL]
        needs_model += [f"{module}.{suite}/anyCase()" for suite in plan.REQUIRES_MODEL_SUITES]
        for test_id in needs_model:
            with self.subTest(test_id=test_id):
                self.assertEqual([selection.name for selection in swift if selected(selection, test_id)], [])

    def test_every_selection_runs_through_the_zero_skip_wrapper_serially(self):
        for selection in plan.SELECTIONS:
            with self.subTest(selection=selection.name):
                cwd, argv = plan.command(selection, Path("/output"))
                if selection.runner is None:
                    self.assertEqual(cwd, plan.PACKAGE)
                    self.assertEqual(argv[0], str(ROOT / "scripts/run-nested-suite.sh"))
                    self.assertEqual(argv[-1], "--no-parallel")
                    # Only a grouped selection runs beside others on one build,
                    # so only it skips SwiftPM's lock on .build.
                    self.assertEqual("--ignore-lock" in argv, selection.group is not None)
                    self.assertEqual(argv[1], plan.swift_arguments(selection)[0])
                else:
                    self.assertEqual(cwd, ROOT)
                    self.assertTrue(Path(argv[1]).is_file(), argv)

    def test_order_dependent_selections_keep_their_process_and_order(self):
        # Some GPU and peer tests pass only after earlier work in the same
        # process or on the same Mac (PR 1745 runs 41692814231, 41700931534).
        # Every base suite runs whole in one process, except the CPU
        # batch-session suite, whose prefix tier tests run in a process of
        # their own and its other tests in another. The Gemma family runs in
        # two processes of its own (Gemma4TensorParallelTests, then the
        # others), and every other base suite in `base`.
        base = [selection for selection in plan.SELECTIONS if selection.base]
        gemma_rest = tuple(suite for suite in plan.GEMMA_SUITES if suite != "Gemma4TensorParallelTests")
        self.assertEqual([(selection.name, selection.suites, selection.functions) for selection in base],
                         [("base-batch-session", ("QwenTensorParallelBatchSessionTests",), ()),
                          ("base-batch-session-prefix-tiers", ("QwenTensorParallelBatchSessionTests",),
                           plan.BATCH_SESSION_PREFIX_TIER_TESTS),
                          ("base", None, ()),
                          ("base-gemma-tensor-parallel", ("Gemma4TensorParallelTests",), ()),
                          ("base-gemma", gemma_rest, ())])
        self.assertTrue(all("Gemma" in suite for suite in plan.GEMMA_SUITES))
        # Each Gemma selection has a shard and its Mac to itself.
        for name in ("base-gemma-tensor-parallel", "base-gemma"):
            gemma = next(selection for selection in base if selection.name == name)
            self.assertIsNone(gemma.group)
            self.assertEqual([selection.name for selection in plan.SELECTIONS
                              if (selection.lane, selection.shard) == ("blocking", gemma.shard)], [name])
        # `base`, the longest selection, and then the share probe have shard 1
        # and its Mac to themselves, one process at a time. The probe times
        # its share against a 1.5 s budget: it never shares a shard with the
        # concurrent GPU groups (run 41973436945 failed it right after them).
        order = [selection.name for selection in plan.SELECTIONS]
        probe = next(selection for selection in plan.SELECTIONS if selection.name == "qwen-tp-share-probe-gpu")
        base_selection = next(selection for selection in plan.SELECTIONS if selection.name == "base")
        self.assertIsNone(base_selection.group)
        self.assertIsNone(probe.group)
        self.assertEqual([selection.name for selection in plan.SELECTIONS
                          if (selection.lane, selection.shard) == ("blocking", base_selection.shard)],
                         ["base", "qwen-tp-share-probe-gpu"])
        self.assertGreater(order.index(probe.name), order.index(base_selection.name))
        grouped_shards = {(selection.lane, selection.shard) for selection in plan.SELECTIONS
                          if selection.group is not None}
        self.assertNotIn((probe.lane, probe.shard), grouped_shards)
        # Groups exist only where the plan puts them: the focused and GPU lanes
        # still run one selection at a time.
        self.assertEqual({selection.lane for selection in plan.SELECTIONS if selection.group is not None},
                         {"blocking"})

    def test_each_half_of_the_real_geometry_rows_check_has_a_gpu_shard_to_itself(self):
        # As one test the check alone set the run's wall time; its halves
        # compare against their own solo runs, so each runs on its own Mac.
        halves = {"qwen-tp-real-geometry-gpu": "rowsEqualTheirSoloStepsAndWindowPositionsAtRealWidths",
                  "qwen-tp-real-geometry-gpu-segments": "rowsAcrossKVSegmentsEqualTheirSoloStepsAtRealWidths"}
        selections = {selection.name: selection for selection in plan.SELECTIONS}
        shards = set()
        for name, test in halves.items():
            with self.subTest(selection=name):
                selection = selections[name]
                self.assertEqual((selection.lane, selection.tests, selection.group), ("nonblocking", (test,), None))
                self.assertEqual(selection.environment, {"QWEN_TP_REAL_GEOMETRY_GPU": "1"})
                self.assertEqual([other.name for other in plan.SELECTIONS
                                  if (other.lane, other.shard) == ("nonblocking", selection.shard)], [name])
                shards.add(selection.shard)
        self.assertEqual(len(shards), 2)

    def test_a_shard_runs_its_groups_together_then_its_other_selections_alone(self):
        marks = Path(self.enterContext(tempfile.TemporaryDirectory())) / "marks"
        script = ("import os, sys, time; name = sys.argv[1]; path = sys.argv[2]\n"
                  "open(path, 'a').write(f'tmp {name} {os.environ.get(\"TMPDIR\", \"-\")}\\n')\n"
                  "time.sleep(1.5 if name == 'a1' else 0.1)\n"
                  "open(path, 'a').write(f'end {name} {time.monotonic()}\\n')\n"
                  "sys.exit(3 if name == 'b2' else 0)\n")
        selections = (
            plan.Selection("a1", "blocking", 1, group=1), plan.Selection("a2", "blocking", 1, group=1),
            plan.Selection("b1", "blocking", 1, group=2), plan.Selection("b2", "blocking", 1, group=2),
            plan.Selection("alone", "blocking", 1), plan.Selection("other-shard", "blocking", 2),
        )
        # Each launch is timed here, in the test process: plan.execute spawns
        # the child right after calling `command`. A start mark written by the
        # child would also time its interpreter's startup, which a loaded
        # runner delays (runs 42179534473, 42190956483).
        launched = {}

        def command(selection, output):
            launched[selection.name] = time.monotonic()
            return ROOT, [sys.executable, "-c", script, selection.name, str(marks)]

        # CLUSTER_TEST_START_GAP: far longer than a1 takes to launch, and a
        # second shorter than a1's 1.5 s, so b1 (0.1 s) launches and ends
        # while a1 runs.
        gap = 0.5
        with mock.patch.object(plan, "SELECTIONS", selections), mock.patch.object(plan, "command", command), \
                mock.patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": "", "CLUSTER_TEST_START_GAP": str(gap)}):
            started = time.monotonic()
            self.assertEqual(plan.run("blocking", 1), 1)
        ended, temporary = {}, {}
        for line in marks.read_text().splitlines():
            kind, name, value = line.split(maxsplit=2)
            if kind == "tmp":
                temporary[name] = value
            else:
                ended[name] = float(value)
        # Exactly this shard's selections launch, and each child runs to its end mark.
        names = ("a1", "a2", "b1", "b2", "alone")
        self.assertEqual(set(launched), set(names))
        self.assertEqual(set(ended), set(names))
        # Each group keeps its order: a selection launches after the one before it ends.
        self.assertLessEqual(ended["a1"], launched["a2"])
        self.assertLessEqual(ended["b1"], launched["b2"])
        # Group 1 launches at once (within half a gap) and group 2 one gap
        # after the groups start, while a1 still runs: the groups overlap, and
        # their SwiftPM startups do not meet. The plan counts the gap from the
        # groups' start, which follows `started`, so b1 cannot launch before
        # `started + gap` when the plan works; a1's launch can trail that
        # start, so a gap counted from it can fall short.
        self.assertLess(launched["a1"], started + gap / 2)
        self.assertGreaterEqual(launched["b1"], started + gap)
        self.assertLess(launched["b1"], ended["a1"])
        # A launch is not yet a running child: b1's child also runs to its end
        # before a1's, so the children overlap, not only their launches.
        self.assertLess(ended["b1"], ended["a1"])
        # Each group has its own TMPDIR; the alone selection launches after all of them end.
        self.assertEqual(temporary["a1"], temporary["a2"])
        self.assertNotEqual(temporary["a1"], temporary["b1"])
        self.assertGreaterEqual(launched["alone"], max(ended[name] for name in names[:4]))

    def test_a_grouped_selection_that_finds_the_build_database_locked_runs_once_more(self):
        root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        # The first run of "locked-once" finds build.db locked, as SwiftPM
        # reports it, passes its tests and exits 1; "locked-other-wording"
        # does the same with SwiftPM's other wording (run 42057277814);
        # "locked" always does; "locked-failing" finds it locked and a test
        # fails; "failing" fails.
        script = ("import os, sys; name, root = sys.argv[1], sys.argv[2]\n"
                  "runs = os.path.join(root, name)\n"
                  "count = len(open(runs).read()) if os.path.exists(runs) else 0\n"
                  "open(runs, 'a').write('x')\n"
                  "locked = name in ('locked', 'locked-failing') or (name.startswith('locked-o') and count == 0)\n"
                  "if locked and name == 'locked-other-wording':\n"
                  "    print('error: error: accessing build database \"/x/.build/build.db\": database is locked', flush=True)\n"
                  "elif locked: print('error: unable to attach DB: error: accessing build database '\n"
                  "                   '\"/x/.build/build.db\": database is locked', flush=True)\n"
                  "print(f'run {count + 1}', flush=True)\n"
                  "if name == 'locked-failing': print('\u2718 Test run with 2 tests failed after 0.1 seconds.')\n"
                  "else: print('\u2714 Test run with 2 tests passed after 0.1 seconds.')\n"
                  "sys.exit(1 if locked or name == 'failing' else 0)\n")
        selections = (plan.Selection("locked-once", "blocking", 1, group=1),
                      plan.Selection("locked", "blocking", 1, group=2),
                      plan.Selection("failing", "blocking", 1, group=3),
                      plan.Selection("locked-failing", "blocking", 1, group=4),
                      plan.Selection("locked-other-wording", "blocking", 1, group=5))
        command = lambda selection, output: (ROOT, [sys.executable, "-c", script, selection.name, str(root)])
        with mock.patch.object(plan, "SELECTIONS", selections), mock.patch.object(plan, "command", command), \
                mock.patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": "", "CLUSTER_TEST_START_GAP": "0"}), \
                mock.patch.object(sys, "stdout", io.TextIOWrapper(io.BytesIO(), write_through=True)) as stdout:
            self.assertEqual(plan.run("blocking", 1), 1)
            printed = stdout.buffer.getvalue().decode()
        runs = {selection.name: len((root / selection.name).read_text()) for selection in selections}
        self.assertEqual(runs, {"locked-once": 2, "locked": 2, "failing": 1, "locked-failing": 1,
                                "locked-other-wording": 2})
        # The first attempt's log prints before the second's.
        once = printed.split("::group::locked-once (group 1)", 1)[1].split("::endgroup::", 1)[0]
        self.assertLess(once.index("Attempt 1's log"), once.index("run 1"))
        self.assertLess(once.index("run 1"), once.index("Attempt 2's log"))
        self.assertLess(once.index("Attempt 2's log"), once.index("run 2"))
        # A selection alone has no other process to meet: no retry.
        with mock.patch.object(plan, "command", command):
            status, _ = plan.execute(plan.Selection("locked", "blocking", 1), root)
        self.assertEqual((status, len((root / "locked").read_text())), (1, 3))

    def test_the_group_start_gap_defaults_to_the_provider_shards_and_refuses_text(self):
        with mock.patch.dict(os.environ, {"CLUSTER_TEST_START_GAP": ""}):
            self.assertEqual(plan.start_gap(), 15.0)
        with mock.patch.dict(os.environ, {"CLUSTER_TEST_START_GAP": "2.5"}):
            self.assertEqual(plan.start_gap(), 2.5)
        for value in ("-1", "fifteen", "1e3"):
            with self.subTest(value=value), mock.patch.dict(os.environ, {"CLUSTER_TEST_START_GAP": value}), \
                    self.assertRaises(ValueError):
                plan.start_gap()
        # The workflow sets no gap, so shard 2 staggers by the default.
        self.assertNotIn("CLUSTER_TEST_START_GAP", plan.WORKFLOW.read_text())

    def test_each_process_has_only_its_own_switches(self):
        switches = {name: "1" for selection in plan.SELECTIONS for name in selection.environment}
        switches.update({"GLM53_WINDOW_CENSUS_LONG": "1", "DARKBLOOM_PAGED_BENCH_CTX": "4096"})
        with mock.patch.dict(os.environ, switches):
            for selection in plan.SELECTIONS:
                with self.subTest(selection=selection.name):
                    environment = plan.environment(selection)
                    self.assertEqual(environment["MLX_QMV_BATCH_INVARIANT"], "1")
                    own = {name: value for name, value in environment.items() if name in switches}
                    # Only its own switches: also none of the other variables the tests read.
                    self.assertEqual(own, selection.environment)

    def test_jobs_run_every_shard_of_their_lane(self):
        jobs = {"test-cluster": ("blocking", "Run cluster runtime tests"),
                "test-cluster-gpu": ("nonblocking", "Run non-blocking cluster GPU tests")}
        for job_id, (lane, name) in jobs.items():
            with self.subTest(job=job_id):
                job = self.jobs[job_id]
                if lane == "blocking":
                    # Each blocking shard reads the Darkbloom lane its matrix
                    # entry names; two shards can share a lane, which the
                    # route then requests for both (test-darkbloom-route.py).
                    entries = re.findall(r"(?m)^          - \{shard: ([0-9]+), lane: ([a-z0-9-]+)\}$", job)
                    self.assertEqual([int(shard) for shard, _ in entries], plan.shards(lane))
                    self.assertIn("    runs-on: ${{ fromJSON(inputs.routes)[matrix.lane] }}\n", job)
                    for _, route_lane in entries:
                        self.assertIn(f"        {route_lane} macos_arm64 ", self.jobs["route"])
                else:
                    # GPU shards 1 and 3 each read a lane of their own. Shard 2
                    # needs more memory than any signed Darkbloom size: it has
                    # no lane and keeps Blacksmith.
                    matrix = re.search(r"(?m)^        shard: \[([0-9, ]+)\]$", job).group(1)
                    self.assertEqual([int(shard) for shard in matrix.split(",")], plan.shards(lane))
                    self.assertIn(f"    runs-on: ${{{{ matrix.shard == 2 && '{workflow.BLACKSMITH_MAC}' || "
                                  f"fromJSON(inputs.routes)[format('{job_id}-{{0}}', matrix.shard)] }}}}\n", job)
                    for shard in (1, 3):
                        self.assertIn(f"        {job_id}-{shard} macos_arm64 ", self.jobs["route"])
                    self.assertNotIn(f"        {job_id}-2 ", self.jobs["route"])
                steps = {workflow.field(step, "name", indent=6): step for step in workflow.step_blocks(job)}
                products = steps["Download cluster test products"]
                self.assertEqual(workflow.field(products, "uses"), workflow.PRODUCTS_ACTION)
                self.assertEqual(workflow.field(products, "lane", indent=10), "cluster")
                run = steps[name]
                self.assertEqual(workflow.run_command(run), f'python3 scripts/cluster-test-plan.py run {lane} "$SHARD"')
                self.assertEqual(workflow.field(run, "SHARD", indent=10), "${{ matrix.shard }}")
                self.assertEqual(workflow.field(run, "if"), workflow.READY)
        self.assertEqual(plan.shards("focused"), [1])
        focused = {workflow.field(step, "name", indent=6): step
                   for step in workflow.step_blocks(self.jobs["test-cluster-focused"])}
        self.assertEqual(workflow.run_command(focused["Run cluster focused checks"]),
                         "python3 scripts/cluster-test-plan.py run focused 1")
        self.assertIn("matrix.shard == 1 && ", workflow.field(focused["Run cluster focused checks"], "if"))
        self.assertIn("        test-cluster-focused macos_arm64 ", self.jobs["route"])

    def test_only_the_gpu_job_continues_after_a_failure_and_the_gate_requires_the_others(self):
        # Besides the report-only resource samples.
        self.assertEqual(workflow.continues_on_error(self.jobs["test-cluster-gpu"]),
                         ["Run non-blocking cluster GPU tests", workflow.SAMPLER_STEPS[-1]])
        gate = workflow.field(self.jobs["provider-test-gate"], "needs", indent=4)
        needs = [name.strip() for name in gate.strip("[]").split(",")]
        for job_id in ("test-cluster", "test-cluster-focused", "cluster-release-checks"):
            with self.subTest(job=job_id):
                self.assertEqual(workflow.continues_on_error(self.jobs[job_id]), [workflow.SAMPLER_STEPS[-1]])
                self.assertIn(job_id, needs)
        self.assertNotIn("test-cluster-gpu", self.jobs["provider-test-gate"])


if __name__ == "__main__":
    unittest.main()
