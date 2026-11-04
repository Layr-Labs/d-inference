#!/usr/bin/env python3
"""Offline checks of the cluster test plan and the jobs that run it."""

import contextlib
import importlib.util
import io
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
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
                else:
                    self.assertEqual(cwd, ROOT)
                    self.assertTrue(Path(argv[1]).is_file(), argv)

    def test_order_dependent_selections_keep_their_process_and_order(self):
        # Some GPU and peer tests pass only after earlier work in the same
        # process or on the same Mac (PR 1745 runs 41692814231, 41700931534).
        # Every base suite but the CPU batch-session suite runs in one process,
        # so each model family shares a process.
        base = [selection for selection in plan.SELECTIONS if selection.base]
        self.assertEqual([(selection.name, selection.suites) for selection in base],
                         [("base-batch-session", ("QwenTensorParallelBatchSessionTests",)), ("base", None)])
        # The share probe's 1.5 s budget includes the first use of the Qwen TP
        # kernels on the Mac: it runs in the shard of qwen-tp-batch-gpu, after it.
        order = [selection.name for selection in plan.SELECTIONS]
        probe = next(selection for selection in plan.SELECTIONS if selection.name == "qwen-tp-share-probe-gpu")
        batch = next(selection for selection in plan.SELECTIONS if selection.name == "qwen-tp-batch-gpu")
        self.assertEqual((probe.lane, probe.shard), (batch.lane, batch.shard))
        self.assertGreater(order.index(probe.name), order.index(batch.name))

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
        jobs = {"test-cluster": "blocking", "test-cluster-gpu": "nonblocking"}
        for job_id, lane in jobs.items():
            with self.subTest(job=job_id):
                job = self.jobs[job_id]
                matrix = re.search(r"(?m)^        shard: \[([0-9, ]+)\]$", job).group(1)
                self.assertEqual([int(shard) for shard in matrix.split(",")], plan.shards(lane))
                # A dedicated Blacksmith Mac per shard; the route has no lane for it.
                self.assertIn("    runs-on: blacksmith-12vcpu-macos-27\n", job)
                self.assertNotIn(f"        {job_id}-", self.jobs["route"])
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
        self.assertIn("    runs-on: blacksmith-12vcpu-macos-27\n", self.jobs["test-cluster-focused"])
        self.assertNotIn("        test-cluster-focused ", self.jobs["route"])

    def test_only_the_gpu_job_continues_after_a_failure_and_the_gate_requires_the_others(self):
        self.assertIn("continue-on-error: true", workflow.step_blocks(self.jobs["test-cluster-gpu"])[-1])
        gate = workflow.field(self.jobs["provider-test-gate"], "needs", indent=4)
        needs = [name.strip() for name in gate.strip("[]").split(",")]
        for job_id in ("test-cluster", "test-cluster-focused"):
            with self.subTest(job=job_id):
                self.assertNotIn("continue-on-error:", self.jobs[job_id])
                self.assertIn(job_id, needs)
        self.assertNotIn("test-cluster-gpu", self.jobs["provider-test-gate"])


class HostGPUArchitectureTests(unittest.TestCase):
    """MLX_METAL_GPU_ARCH for the GPU lane: the host's GPU, only in a VM whose GPU Metal calls `air64_*`."""

    VM = ("air64_v27", "Apple M3 Ultra (Virtual)")

    def architecture(self, lane, metal, brand, caller=None):
        """(architecture_environment(lane), its log, whether it read Metal) where Metal names the GPU
        `metal`, the CPU brand string is `brand` and the caller's environment holds `caller`."""
        with mock.patch.dict(os.environ, caller or {}), \
                mock.patch.object(plan, "metal_architecture", return_value=metal) as probe, \
                mock.patch.object(plan, "cpu_brand", return_value=brand), \
                contextlib.redirect_stdout(io.StringIO()) as log:
            if caller is None:
                os.environ.pop("MLX_METAL_GPU_ARCH", None)
            return plan.architecture_environment(lane), log.getvalue(), probe.called

    def test_each_chip_has_the_name_metal_gives_its_gpu_on_a_mac(self):
        # As Metal names them on Macs (`MTLDevice.architecture.name`, MLX's `device_info()`).
        reported = {"M1 Pro": "applegpu_g13s", "M1 Max": "applegpu_g13s", "M3 Pro": "applegpu_g15s",
                    "M3 Max": "applegpu_g15s", "M3 Ultra": "applegpu_g15d", "M4 Pro": "applegpu_g16s",
                    "M4 Max": "applegpu_g16s", "M5": "applegpu_g17g", "M5 Max": "applegpu_g17s",
                    "M5 Ultra": "applegpu_g17d"}
        for chip, name in reported.items():
            with self.subTest(chip=chip):
                self.assertEqual(plan.host_gpu_architecture(f"Apple {chip} (Virtual)"), name)
        # An MN chip is generation 12 + N, the two digits MLX reads; `g` base, `s` Pro and Max, `d` Ultra.
        suffixes = {"": "g", "Pro": "s", "Max": "s", "Ultra": "d"}
        for chip, name in plan.HOST_GPU_ARCHITECTURES.items():
            with self.subTest(chip=chip):
                family, _, tier = chip.partition(" ")
                self.assertEqual(name, f"applegpu_g{12 + int(family[1:])}{suffixes[tier]}")

    def test_only_a_vm_guests_brand_string_for_a_known_chip_names_a_host(self):
        for brand in ("Apple M3 Ultra", "Apple M6 Max (Virtual)", "Apple M4 Ultra (Virtual)",
                      "Apple processor (Virtual)", "Intel(R) Core(TM) i9-9980HK CPU @ 2.40GHz", ""):
            with self.subTest(brand=brand):
                self.assertIsNone(plan.host_gpu_architecture(brand))

    def test_the_gpu_lane_gets_the_hosts_gpu_only_in_a_vm_whose_gpu_metal_calls_air64(self):
        cases = (
            # Metal's name, the CPU brand string, the processes' MLX_METAL_GPU_ARCH, the log
            (*self.VM, "applegpu_g15d", "::notice "),
            ("air64_v27", "Apple M4 Pro (Virtual)", "applegpu_g16s", "::notice "),
            ("applegpu_g15d", "Apple M3 Ultra", None, ""),  # a Mac
            ("applegpu_g16s", "Apple M4 Max (Virtual)", None, ""),  # a VM whose GPU Metal names itself
            ("air64_v27", "Apple M6 Max (Virtual)", None, "::warning "),  # a chip the table does not name
            ("", "Apple M3 Ultra (Virtual)", None, "unavailable"),  # no Metal device or no Swift
        )
        for metal, brand, host, log in cases:
            with self.subTest(metal=metal, brand=brand):
                environment, printed, _ = self.architecture("nonblocking", metal, brand)
                self.assertEqual(environment, {"MLX_METAL_GPU_ARCH": host} if host else {})
                if log:
                    self.assertIn(log, printed)
                else:
                    self.assertEqual(printed, "")

    def test_a_vm_on_an_m5_keeps_metals_name_because_the_hosts_would_turn_on_nax(self):
        for chip, name in plan.HOST_GPU_ARCHITECTURES.items():
            with self.subTest(chip=chip):
                environment, printed, _ = self.architecture("nonblocking", "air64_v27", f"Apple {chip} (Virtual)")
                if chip.startswith("M5"):
                    self.assertEqual(environment, {})
                    self.assertIn("NAX kernels", printed)
                else:
                    self.assertEqual(environment, {"MLX_METAL_GPU_ARCH": name})

    def test_a_callers_value_and_the_other_lanes_keep_mlxs_own_reading(self):
        for value in ("applegpu_g17s", ""):
            with self.subTest(MLX_METAL_GPU_ARCH=value):
                self.assertEqual(self.architecture("nonblocking", *self.VM, {"MLX_METAL_GPU_ARCH": value}),
                                 ({}, "", False))
        for lane in ("blocking", "focused"):
            with self.subTest(lane=lane):
                self.assertEqual(self.architecture(lane, *self.VM), ({}, "", False))

    def test_every_gpu_lane_process_in_a_vm_starts_with_the_hosts_gpu(self):
        def environments(lane, shard):
            started = []

            def start(argv, cwd, env):
                started.append(env)
                return subprocess.CompletedProcess(argv, 0)
            with tempfile.TemporaryDirectory() as output, \
                    mock.patch.object(plan.tempfile, "mkdtemp", return_value=output), \
                    mock.patch.object(plan.subprocess, "run", start), \
                    mock.patch.object(plan, "metal_architecture", return_value=self.VM[0]), \
                    mock.patch.object(plan, "cpu_brand", return_value=self.VM[1]), \
                    mock.patch.dict(os.environ), contextlib.redirect_stdout(io.StringIO()):
                for name in ("MLX_METAL_GPU_ARCH", "GITHUB_STEP_SUMMARY"):
                    os.environ.pop(name, None)
                self.assertEqual(plan.run(lane, shard), 0)
            return started
        for lane in plan.LANES:
            for shard in plan.shards(lane):
                with self.subTest(lane=lane, shard=shard):
                    expected = "applegpu_g15d" if lane == "nonblocking" else None
                    started = environments(lane, shard)
                    self.assertEqual(len(started), len([selection for selection in plan.SELECTIONS
                                                        if (selection.lane, selection.shard) == (lane, shard)]))
                    self.assertEqual({env.get("MLX_METAL_GPU_ARCH") for env in started}, {expected})

    @unittest.skipUnless(sys.platform == "darwin" and shutil.which("swift"), "reads this Mac's GPU and CPU")
    def test_the_probes_read_metals_name_and_the_cpu_brand_string(self):
        self.assertRegex(plan.metal_architecture(), r"^(?:applegpu_g\d\d[a-z]|air64_v\d+)$")
        self.assertRegex(plan.cpu_brand(), r"^Apple M\d")


if __name__ == "__main__":
    unittest.main()
