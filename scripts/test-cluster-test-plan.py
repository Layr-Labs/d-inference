#!/usr/bin/env python3
"""Offline checks of the cluster test plan and the jobs that run it."""

import importlib.util
import os
from pathlib import Path
import re
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parent.parent
_SPEC = importlib.util.spec_from_file_location("cluster_test_plan", ROOT / "scripts/cluster-test-plan.py")
plan = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(plan)
_SPEC = importlib.util.spec_from_file_location("provider_workflow", ROOT / "scripts/test-provider-ci-workflow.py")
workflow = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(workflow)


def swift_processes():
    return [process for lane in ("blocking", "nonblocking") for process in plan.processes(lane)]


def selected(process, test_id):
    """Whether `swift test` with this process's filter and skip runs `test_id`."""
    return plan.planned([test_id], process) == [test_id]


class ClusterTestPlanTests(unittest.TestCase):
    def setUp(self):
        self.jobs = workflow.job_blocks(plan.WORKFLOW.read_text())

    def test_plan_names_every_gated_test_and_runner(self):
        self.assertEqual(plan.audit(), [])

    def test_every_test_runs_in_exactly_one_process_unless_it_needs_a_model(self):
        module = plan.MODULE
        swift = swift_processes()
        cases = {f"{module}.AnySuite/{name}(sharded:)": name for selection in plan.SELECTIONS for name in selection.tests}
        _, units, _ = plan.base_units(plan.load_weights())
        split = next(unit for unit in units if "/" in unit)
        whole = next(unit for unit in units if unit.endswith("*"))[:-1] + "AnySuiteTests"
        cases.update({
            # A weighed test of a split suite, and one the weights do not name yet.
            f"{module}.{split}()": "base",
            f"{module}.QwenTensorParallelBatchSessionTests/actualShardsBatchIndependentHistories()": "base",
            f"{module}.QwenTensorParallelBatchSessionTests/Nested/plainCase()": "base",
            f"{module}.{whole}/anyCase()": "base",
            f"{module}.{whole}/Nested/anyCase(width:)": "base",
            f"{module}.PrefixCacheContractTests/plannedFramesStartAtTheReusedPrefix()": "base",
            f"{module}.QwenBatchCancellationTests/testAcceptedStartStaysCharged": "base",
            f"{module}.QwenTensorParallelBatchSessionTestsMore/plainCase()": "base",
            f"{module}.BrandNewSuite/plainCase()": "base",
            f"{module}.freeFunction()": "base",
            f"{module}.QwenBrandNewTests/plainCase()": "base",
            f"{module}.GLM5NextStageFrameTransportTests/bothNativeStagesCommitOnlyTheirAcknowledgedFrames()": "base",
        })
        for test_id, owner in cases.items():
            with self.subTest(test_id=test_id):
                runs = [process for process in swift if selected(process, test_id)]
                self.assertEqual(len(runs), 1, [(process.shard, process.name) for process in runs])
                runner = runs[0]
                self.assertTrue(runner.name == owner or owner in runner.units, runner.name)
        # Base tests the weights do not name run in the last shard's catch-all.
        for test_id in (f"{module}.BrandNewSuite/plainCase()", f"{module}.freeFunction()"):
            runs = [process for process in swift if selected(process, test_id)]
            self.assertTrue(runs[0].catch_all)
            self.assertEqual(runs[0].shard, plan.SHARD_COUNTS["blocking"])
        needs_model = [f"{module}.AnySuite/{name}()" for name in plan.REQUIRES_MODEL]
        needs_model += [f"{module}.{suite}/anyCase()" for suite in plan.REQUIRES_MODEL_SUITES]
        for test_id in needs_model:
            with self.subTest(test_id=test_id):
                self.assertEqual([process.name for process in swift if selected(process, test_id)], [])

    def test_weighed_lanes_place_every_unit_once_and_the_catch_all_last(self):
        weights = plan.load_weights()
        base, units, _ = plan.base_units(weights)
        blocking = plan.processes("blocking", weights)
        shards = plan.SHARD_COUNTS["blocking"]
        self.assertEqual(sorted({process.shard for process in blocking}), list(range(1, shards + 1)))
        catch_all = [process for process in blocking if process.catch_all]
        self.assertEqual([(process.shard, process.name) for process in catch_all], [(shards, base.name)])
        placed = [unit for process in blocking if process.selection is base for unit in process.units]
        self.assertEqual(sorted(catch_all[0].others), sorted(placed))
        self.assertEqual(len(placed), len(set(placed)))
        self.assertLessEqual(set(placed), set(units))
        for selection in plan.SELECTIONS:
            if selection.lane == "blocking" and selection.tests:
                with self.subTest(selection=selection.name):
                    tests = [test for process in blocking if process.selection is selection for test in process.units]
                    self.assertEqual(sorted(tests), sorted(selection.tests))
        # Each (shard, selection) is one process.
        keys = [(process.shard, process.name) for process in blocking]
        self.assertEqual(len(keys), len(set(keys)))
        # A selection with `after` runs in that selection's shard, after it.
        for selection in plan.SELECTIONS:
            if selection.after:
                with self.subTest(after=selection.name):
                    leader = next(key for key in keys if key[1] == selection.after)
                    follower = next(key for key in keys if key[1] == selection.name)
                    self.assertEqual(follower[0], leader[0])
                    self.assertGreater(keys.index(follower), keys.index(leader))
        # Each family runs in one process, a new suite of the family included;
        # a split suite is not part of its family.
        family_units = sorted(unit for unit in units if unit.endswith("*"))
        self.assertEqual(family_units, sorted(f"{family}*" for family in plan.FAMILIES))
        module = plan.MODULE
        for family in plan.FAMILIES:
            with self.subTest(family=family):
                holder = next(process for process in blocking
                              if f"{family}*" in process.units or (process.catch_all and f"{family}*" not in process.others))
                for suite in (f"{family}AlphaTests", f"{family}ZetaTests"):
                    runs = [process for process in blocking if selected(process, f"{module}.{suite}/case()")]
                    self.assertEqual(runs, [holder])
        for suite in plan.SPLIT_SUITES:
            runs = [process for process in blocking if selected(process, f"{module}.{suite}/brandNewCase()")]
            self.assertEqual([process.catch_all for process in runs], [True])
        share_probe = next(s for s in plan.SELECTIONS if s.name == "qwen-tp-share-probe-gpu")
        self.assertEqual(share_probe.after, "qwen-tp-batch-gpu")
        focused = plan.processes("focused", weights)
        self.assertEqual(sorted(process.name for process in focused),
                         sorted(selection.name for selection in plan.SELECTIONS if selection.lane == "focused"))
        self.assertEqual(sorted({process.shard for process in focused}), plan.shards("focused"))
        # A unit the weights do not list yet keeps the plan whole.
        lighter = {key: value for key, value in weights.items() if not key.startswith("qwen-tp-moe-gpu/")}
        moe = [test for process in plan.processes("blocking", lighter)
               if process.name == "qwen-tp-moe-gpu" for test in process.units]
        self.assertEqual(sorted(moe), sorted(next(s for s in plan.SELECTIONS if s.name == "qwen-tp-moe-gpu").tests))

    def test_run_audit_requires_every_blocking_test_once_with_its_count(self):
        module = plan.MODULE
        weights = plan.load_weights()
        blocking = plan.processes("blocking", weights)
        nonblocking = next(s for s in plan.SELECTIONS if s.lane == "nonblocking" and s.tests).tests[0]
        test_ids = [f"{module}.Opt/{name}()" for selection in plan.SELECTIONS
                    if selection.lane == "blocking" for name in selection.tests]
        test_ids += [f"{module}.{unit}()" for unit in plan.base_units(weights)[1] if "/" in unit]
        test_ids += [f"{module}.{family}AnyTests/case()" for family in plan.FAMILIES]
        test_ids += [f"{module}.BrandNewSuite/plainCase()", f"{module}.Legacy/testOld",
                     f"{module}.Opt/{nonblocking}()", f"{module}.Opt/{plan.REQUIRES_MODEL[0]}()"]

        def reports(**overrides):
            return [{"shard": process.shard, "process": process.name, "xctest": 0,
                     "swift_testing": overrides.get(f"{process.shard}/{process.name}",
                                                    len(plan.planned(test_ids, process)))}
                    for process in blocking]

        self.assertEqual(plan.audit_runs(test_ids, reports(), weights), [])
        last = blocking[-1]
        short = plan.audit_runs(test_ids, reports(**{f"{last.shard}/{last.name}": 0}), weights)
        self.assertTrue(any("executed 0 tests" in error for error in short), short)
        missing = plan.audit_runs(test_ids, reports()[1:], weights)
        self.assertTrue(any("Expected one report per process" in error for error in missing), missing)
        self.assertTrue(any("run in no blocking process" in error for error in missing), missing)
        self.assertEqual(plan.blocking_expected([f"{module}.Opt/{nonblocking}()"]), [])

    def test_every_process_runs_through_the_zero_skip_wrapper_serially(self):
        for lane in plan.LANES:
            for process in plan.processes(lane):
                with self.subTest(lane=lane, shard=process.shard, process=process.name):
                    cwd, argv = plan.command(process, Path("/output"), Path("/reports/x.xml"))
                    if process.selection.runner is None:
                        self.assertEqual(cwd, plan.PACKAGE)
                        self.assertEqual(argv[0], str(ROOT / "scripts/run-nested-suite.sh"))
                        self.assertEqual(argv[-3:], ["--xunit-output", "/reports/x.xml", "--no-parallel"])
                        self.assertEqual(plan.command(process, Path("/output"))[1][-1], "--no-parallel")
                    else:
                        self.assertEqual(cwd, ROOT)
                        self.assertTrue(Path(argv[1]).is_file(), argv)

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
        jobs = {"test-cluster": "blocking", "test-cluster-gpu": "nonblocking", "test-cluster-focused": "focused"}
        for job_id, lane in jobs.items():
            with self.subTest(job=job_id):
                job = self.jobs[job_id]
                matrix = re.search(r"(?m)^        shard: \[([0-9, ]+)\]$", job).group(1)
                self.assertEqual([int(shard) for shard in matrix.split(",")], plan.shards(lane))
                self.assertIn("      fail-fast: false\n", job)
                # A dedicated Blacksmith Mac per shard; the route has no lane for it.
                self.assertIn("    runs-on: blacksmith-12vcpu-macos-27\n", job)
                self.assertNotIn(f"        {job_id}", self.jobs["route"])
                steps = workflow.step_blocks(job)
                run = next(step for step in steps if "cluster-test-plan.py run" in step)
                self.assertEqual(workflow.run_command(run), f'python3 scripts/cluster-test-plan.py run {lane} "$SHARD"')
                self.assertEqual(workflow.field(run, "SHARD", indent=10), "${{ matrix.shard }}")
                if lane == "focused":
                    self.assertEqual(workflow.field(run, "if"), "${{ !cancelled() && steps.toolchain.outcome == 'success' }}")
                    continue
                build = next(step for step in steps if workflow.field(step, "uses") == workflow.BUILD_ACTION)
                self.assertEqual(workflow.field(build, "lane", indent=10), "cluster")
                self.assertEqual(workflow.field(run, "if"), workflow.READY)
        # The blocking shards keep their counts and test list for the summary's audit.
        steps = workflow.step_blocks(self.jobs["test-cluster"])
        run = next(step for step in steps if workflow.field(step, "id") == "cluster-tests")
        self.assertEqual(workflow.field(run, "CLUSTER_TEST_REPORT_DIR", indent=10),
                         "${{ runner.temp }}/cluster-test-reports")
        upload = steps[steps.index(run) + 1]
        self.assertIn("name: cluster-test-shard-${{ matrix.shard }}", upload)
        self.assertIn("if-no-files-found: error", upload)
        self.assertEqual(workflow.field(upload, "if"), "${{ !cancelled() && steps.cluster-tests.outcome != 'skipped' }}")

    def test_summary_audits_the_blocking_shards_and_the_gate_requires_it(self):
        job = self.jobs["test-cluster-summary"]
        self.assertIn("    needs: [changes, test-cluster]\n", job)
        self.assertIn("    if: ${{ !cancelled() && needs.changes.outputs.provider == 'true' }}\n", job)
        self.assertIn("    runs-on: ubuntu-24.04\n", job)
        self.assertNotRegex(job, r"(?m)^    continue-on-error:")
        steps = workflow.step_blocks(job)
        audit = next(step for step in steps if "audit-runs" in step)
        self.assertIsNone(workflow.field(audit, "if"))
        self.assertNotIn("continue-on-error:", audit)
        # Only the report-only weight steps may fail without failing the job.
        tolerant = [workflow.field(step, "name", indent=6) for step in steps if "continue-on-error: true" in step]
        self.assertEqual(tolerant, ["Measure unit times for shard balance", "Upload measured unit times"])
        self.assertIn('cmp -s "$list" "${lists[0]}"', audit)
        self.assertIn('python3 scripts/cluster-test-plan.py audit-runs "${lists[0]}" "$RUNNER_TEMP/cluster-test-shards"',
                      audit)
        self.assertIn("pattern: cluster-test-shard-*", next(step for step in steps if "download-artifact@" in step))
        gate = workflow.field(self.jobs["provider-test-gate"], "needs", indent=4)
        self.assertIn("test-cluster-summary", [name.strip() for name in gate.strip("[]").split(",")])

    def test_only_the_gpu_job_continues_after_a_failure_and_the_gate_requires_the_others(self):
        self.assertIn("continue-on-error: true", workflow.step_blocks(self.jobs["test-cluster-gpu"])[-1])
        gate = workflow.field(self.jobs["provider-test-gate"], "needs", indent=4)
        needs = [name.strip() for name in gate.strip("[]").split(",")]
        for job_id in ("test-cluster", "test-cluster-focused"):
            with self.subTest(job=job_id):
                self.assertNotIn("continue-on-error:", self.jobs[job_id])
                self.assertIn(job_id, needs)
        self.assertNotIn("test-cluster-gpu", self.jobs["provider-test-gate"])


if __name__ == "__main__":
    unittest.main()
