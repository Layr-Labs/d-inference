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


def selected(selection, test_id):
    """Whether `swift test` with this selection's filter and skip runs `test_id`."""
    filter_regex, *extra = plan.swift_arguments(selection)
    skip = extra[extra.index("--skip") + 1] if "--skip" in extra else None
    return bool(re.search(filter_regex, test_id)) and not (skip and re.search(skip, test_id))


class ClusterTestPlanTests(unittest.TestCase):
    def setUp(self):
        self.jobs = workflow.job_blocks(plan.WORKFLOW.read_text())

    def test_plan_names_every_gated_test_and_runner(self):
        self.assertEqual(plan.audit(), [])

    def test_every_test_runs_in_exactly_one_selection_unless_it_needs_a_model(self):
        module = plan.MODULE
        swift = [selection for selection in plan.SELECTIONS if selection.runner is None]
        cases = {f"{module}.AnySuite/{name}(sharded:)": name for selection in swift for name in selection.tests}
        cases.update({f"{module}.AnySuite/{name}()": name for name in plan.HARDWARE_GATED})
        cases.update({
            f"{module}.QwenTensorParallelBatchSessionTests/actualShardsBatchIndependentHistories()": "base-batch-session",
            f"{module}.QwenTensorParallelBatchSessionTests/Nested/plainCase()": "base-batch-session",
            f"{module}.PrefixCacheContractTests/plannedFramesStartAtTheReusedPrefix()": "base",
            f"{module}.QwenBatchCancellationTests/testAcceptedStartStaysCharged": "base",
            f"{module}.QwenTensorParallelBatchSessionTestsMore/plainCase()": "base",
        })
        for test_id, owner in cases.items():
            with self.subTest(test_id=test_id):
                runs = [selection for selection in swift if selected(selection, test_id)]
                self.assertEqual(len(runs), 1, [selection.name for selection in runs])
                runner = runs[0]
                self.assertTrue(runner.name == owner or owner in runner.tests or
                                (owner in plan.HARDWARE_GATED and runner.base), runner.name)
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
                else:
                    self.assertEqual(cwd, ROOT)
                    self.assertTrue(Path(argv[1]).is_file(), argv)

    def test_each_process_has_only_its_own_switches(self):
        switches = {name: "1" for selection in plan.SELECTIONS for name in selection.environment}
        with mock.patch.dict(os.environ, switches):
            for selection in plan.SELECTIONS:
                with self.subTest(selection=selection.name):
                    environment = plan.environment(selection)
                    self.assertEqual(environment["MLX_QMV_BATCH_INVARIANT"], "1")
                    own = {name: value for name, value in environment.items() if name in switches}
                    self.assertEqual(own, selection.environment)

    def test_jobs_run_every_shard_of_their_lane(self):
        jobs = {"test-cluster": "blocking", "test-cluster-gpu": "nonblocking"}
        for job_id, lane in jobs.items():
            with self.subTest(job=job_id):
                job = self.jobs[job_id]
                matrix = re.search(r"(?m)^        shard: \[([0-9, ]+)\]$", job).group(1)
                self.assertEqual([int(shard) for shard in matrix.split(",")], plan.shards(lane))
                for shard in plan.shards(lane):
                    self.assertIn(f"        {job_id}-{shard} macos_arm64 ", self.jobs["route"])
                steps = workflow.step_blocks(job)
                build = next(step for step in steps if workflow.field(step, "uses") == workflow.BUILD_ACTION)
                self.assertEqual(workflow.field(build, "lane", indent=10), "cluster")
                run = steps[-1]
                self.assertEqual(workflow.run_command(run), f'python3 scripts/cluster-test-plan.py run {lane} "$SHARD"')
                self.assertEqual(workflow.field(run, "SHARD", indent=10), "${{ matrix.shard }}")
                self.assertEqual(workflow.field(run, "if"), workflow.READY)
        self.assertEqual(plan.shards("focused"), [1])
        focused = workflow.step_blocks(self.jobs["test-cluster-focused"])
        self.assertEqual(workflow.run_command(focused[-1]), "python3 scripts/cluster-test-plan.py run focused 1")
        self.assertIn("        test-cluster-focused macos_arm64 ", self.jobs["route"])

    def test_only_the_gpu_job_continues_after_a_failure_and_the_gate_requires_the_others(self):
        self.assertIn("continue-on-error: true", workflow.step_blocks(self.jobs["test-cluster-gpu"])[-1])
        for job_id in ("test-cluster", "test-cluster-focused"):
            with self.subTest(job=job_id):
                self.assertNotIn("continue-on-error:", self.jobs[job_id])
                self.assertIn(job_id, workflow.field(self.jobs["provider-test-gate"], "needs", indent=4))
        self.assertNotIn("test-cluster-gpu", self.jobs["provider-test-gate"])


if __name__ == "__main__":
    unittest.main()
