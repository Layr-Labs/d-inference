#!/usr/bin/env python3
"""Offline CI lane/gate checks; actionlint validates the complete YAML syntax."""

from collections import Counter
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = ROOT / ".github/workflows/ci.yml"
ACTION = ROOT / ".github/actions/provider-ci-build/action.yml"
BUILD_ACTION = "./.github/actions/provider-ci-build"
PROVIDER_TEST_COMMAND = ('python3 ../scripts/run-provider-test-watchdog.py \\\n'
                         '  --output-dir "$RUNNER_TEMP/provider-test-diagnostics" \\\n'
                         '  --diagnostic-after-seconds 900 --timeout-seconds 1800 \\\n'
                         '  -- ../scripts/run-provider-tests.sh')
READY = "${{ !cancelled() && steps.provider-ci-build.outcome == 'success' }}"
MIMO_READY = "${{ !cancelled() && steps.provider-ci-build.outcome == 'success' && steps.mimo-fixtures.outcome == 'success' }}"
# Steps that run once, in the last provider shard.
LAST_SHARD = "matrix.shard == strategy.job-total"
LAST_SHARD_READY = READY.replace("!cancelled() && ", f"!cancelled() && {LAST_SHARD} && ")
LAST_SHARD_MIMO_READY = MIMO_READY.replace("!cancelled() && ", f"!cancelled() && {LAST_SHARD} && ")
PROVIDER_MIMO_READY = "${{ !cancelled() && steps.provider-ci-build.outcome == 'success' && steps.mimo-prompt-fixtures.outcome == 'success' && steps.mimo-fixtures.outcome == 'success' }}"
MIMO_PREPARE = ('python3 scripts/prepare-mimo-prompt-fixtures.py '
                '--output "$RUNNER_TEMP/mimo-prompt-fixtures" --github-env "$GITHUB_ENV"')
MIMO_HTTP_PREPARE = ('python3 scripts/test-prepare-mimo-image-http-fixtures.py\n'
                     + MIMO_PREPARE + '\n'
                     + 'python3 scripts/prepare-mimo-image-http-fixtures.py '
                     '--output "$RUNNER_TEMP/mimo-image-http-fixtures" --github-env "$GITHUB_ENV"')
MIMO_PROVIDER_PREPARE = ('python3 scripts/prepare-mimo-provider-fixtures.py '
                         '--output "$RUNNER_TEMP/mimo-provider-fixtures" --github-env "$GITHUB_ENV"\n'
                         'python3 scripts/prepare-mimo-provider-fixtures.py '
                         '--output "$RUNNER_TEMP/mimo-prefix-fixtures" --asymmetric')
SDK_MIMO_PREPARE_NAME = "Prepare tiny MiMo fixture for media-to-text isolation"
SDK_MIMO_GATE_NAME = "Verify media refusal leaves the native text engine usable"
SDK_MIMO_READY = "${{ !cancelled() && steps.provider-ci-build.outcome == 'success' && steps.sdk-mimo-isolation-fixture.outcome == 'success' }}"
SDK_RETENTION_PREPARE_NAME = "Prepare asymmetric tiny MiMo fixture for native retention"
SDK_RETENTION_GATE_NAME = "Verify native retained frontier after donor retirement"
SDK_RETENTION_READY = "${{ !cancelled() && steps.provider-ci-build.outcome == 'success' && steps.sdk-mimo-retention-fixture.outcome == 'success' }}"
SDK_RETENTION_HOST_COMMANDS = {
    "Verify native historical retention policy":
        "../../scripts/run-nested-suite.sh CBv2NativeHistoricalRetentionTests --no-parallel",
    "Verify demanded checkpoint scheduling and projection":
        "../../scripts/run-nested-suite.sh CBv2DemandedCheckpointPartitionTests --no-parallel",
    "Verify demanded long range continuation and projection":
        "../../scripts/run-nested-suite.sh CBv2DemandedCheckpointContinuationTests --no-parallel",
}
MIMO_NATIVE_COMMANDS = {
    "Run isolated native MiMo startup gates":
        "../scripts/run-nested-suite.sh 'MiMoV26StandaloneLifecycleTests.test(ActualScannerPreloadStartsListenerWithSameNativeOwner|StartRefusesActualUnpublishedPreloadWithoutReplacingOwner)' --no-parallel",
    "Run isolated native MiMo memory admission gates":
        "../scripts/run-nested-suite.sh 'testNativeMemoryAdmission|testNativeShutdownActivitySurvivesPendingHostUntilRealQuiescentDrain' --no-parallel",
    "Run isolated native MiMo media admission gates":
        "../scripts/run-nested-suite.sh 'testNativeMediaRelease|testAuthenticatedChatResponsesActuallyRouteEncodedImageThroughNativeBridge|testActualMemoryBackedVideoIndicesAndAuthenticatedNativeRoute|testNativeIdleBootstrapLearnsRealTargetRateAndKeepsTextRateIsolated|testNativePreparedSealReachesRealAtomicDeadlineRejectionWithoutLosingCharge|testTypedDeadlineGatePreservesRawTextAndOffPolicyAndRefusesForeignCapability|MiMoMediaDecodeMemoryTests' --no-parallel",
    "Run isolated native MiMo complete-prefix gates":
        "../scripts/run-nested-suite.sh 'MiMoV26NativeLoadTransactionTests.testNativeCompletePrefix' --no-parallel",
    "Run isolated native MiMo retained-fault gate":
        "../scripts/run-nested-suite.sh testNativeFenceRefusalKeepsActualBundlePermitAndBlocksOtherOwnerReclaim --no-parallel",
    "Run isolated native MiMo lifecycle drain gate":
        "../scripts/run-nested-suite.sh testGracefulDrainAfterServedRequestRetiresNativeOwnerWithinDeadline --no-parallel",
}
COVERAGE_STEPS = ("Collect provider coverage profiles", "Merge shard coverage profiles")
SHARD_UPLOAD = "Upload shard counts, timings and coverage"
LANES = {
    "test-provider": "provider",
    "test-provider-sdk": "sdk",
    "test-provider-parity": "parity",
}
SDK_COMMANDS = {
    **SDK_RETENTION_HOST_COMMANDS,
    SDK_RETENTION_PREPARE_NAME:
        'python3 scripts/prepare-mimo-provider-fixtures.py --output "$RUNNER_TEMP/mimo-native-retention" --asymmetric',
    SDK_RETENTION_GATE_NAME:
        "../../scripts/run-nested-suite.sh MiMoV26NativeHistoricalRetentionTests.testDemandedMiddleFrontierSurvivesNativePublicationAndReopenedFork --no-parallel",
    "Verify DiffusionGemma artifact and expert reduction":
        "../../scripts/run-nested-suite.sh 'DiffusionGemma(ArtifactFixture|ExpertReduction)Tests' --no-parallel",
    "Run nested MiMo media decode tests":
        "../../scripts/run-nested-suite.sh 'MiMoV26(OpenRouterMedia|VisionWorkingSet|AudioWorkingSet|VisualDecodeMemory|EncodedVisualDecoder|EncodedAudioDecoder|EncodedAACAudio|EncodedAudiovisualDecoder)Tests|MiMoV26PixelsTests.test(RGB|Temporal|Invalid|Explicit)' --no-parallel",
    SDK_MIMO_PREPARE_NAME:
        'python3 scripts/prepare-mimo-provider-fixtures.py --output "$RUNNER_TEMP/mimo-media-isolation"',
    SDK_MIMO_GATE_NAME:
        "../../scripts/run-nested-suite.sh MiMoV26NativeMediaDeadlineTests --no-parallel",
    "Run nested paged safety tests":
        "../../scripts/run-nested-suite.sh CBv2PagedSafetyTests",
    "Run nested prompt-hash tests":
        "../../scripts/run-nested-suite.sh CBv2PrefixCacheHasherTests",
    "Run nested paged eligibility tests":
        "../../scripts/run-nested-suite.sh CBv2PagedEligibilityTests",
    "Run nested paged backend tests":
        "../../scripts/run-nested-suite.sh CBv2PagedBackendTests",
    "Run nested paged kernel parity tests":
        "../../scripts/run-paged-kernel-tests.sh",
    "Run nested KV-sharing contiguous/paged parity tests":
        "../../scripts/run-nested-suite.sh CBv2KVSharingParityTests",
}
SDK_ONBOARDING_SUITES = (
    "SSMDecodeBoundsTests", "NemotronHTests",
    "NemotronH35BackendParityTests", "NemotronH35StorageParityTests",
    "NemotronH35MTPTests", "NemotronH35MTPPrimingTests",
    "MutableInputKernelTests", "MutableInputExportTests",
    "CBv2QwenMTPIntegrationTests", "CBv2MTPDepthControllerTests",
    "PagedMTPBatchedColumnsTests", "CBv2CompleteCheckpointEngineTests",
    "NemotronH35ProductionDefaultsTests", "OpenAIServiceTests",
    "ToolCallParserIntegrationTests",
)


def job_blocks(workflow):
    matches = list(re.finditer(r"^  ([a-zA-Z0-9_-]+):\s*$", workflow, re.MULTILINE))
    return {
        match.group(1): workflow[match.end():matches[index + 1].start()
                                if index + 1 < len(matches) else len(workflow)]
        for index, match in enumerate(matches)
    }


def step_blocks(job, indent=6):
    return re.split(rf"(?=^ {{{indent}}}- (?:name|uses):)", job, flags=re.MULTILINE)[1:]


def field(block, name, indent=8):
    match = re.search(rf"^ {{{indent}}}(?:- )?{re.escape(name)}: (.+)$", block, re.MULTILINE)
    return match.group(1).strip() if match else None


def run_command(step):
    command = field(step, "run")
    if command != "|":
        return command
    lines = step.split("        run: |\n", 1)[1].splitlines()
    end = next((index for index, line in enumerate(lines)
                if line.strip() and not line.startswith("          ")), len(lines))
    return textwrap.dedent("\n".join(lines[:end])).strip()


class ProviderCIWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.workflow = WORKFLOW.read_text()
        self.jobs = job_blocks(self.workflow)

    def test_nested_wrapper_preserves_long_filters_and_failure_gates(self):
        selector = "NativeSuite/" + "VeryLongTestName" * 30 + "|OtherSuite/testCase"
        cases = (
            ("Executed 1 test, with 0 failures", 0, 0),
            ("Test run with 1 test passed", 0, 0),
            ("Test run with 0 tests passed", 0, 1),
            ("Executed 1 test, with 1 test skipped and 0 failures", 0, 1),
            ("➜ Test unavailable skipped: missing fixture\nTest run with 1 test passed", 0, 1),
            ("Executed 1 test, with 1 failure", 7, 7),
        )
        with tempfile.TemporaryDirectory(prefix="nested-wrapper-") as temporary:
            root = Path(temporary)
            recorded = root / "arguments.json"
            swift = root / "swift"
            swift.write_text(textwrap.dedent("""\
                #!/usr/bin/env python3
                import json, os, sys
                from pathlib import Path
                Path(os.environ["STUB_ARGUMENTS"]).write_text(json.dumps(sys.argv[1:]))
                print(os.environ["STUB_OUTPUT"])
                raise SystemExit(int(os.environ["STUB_EXIT"]))
                """))
            swift.chmod(0o755)
            for output, swift_exit, expected_exit in cases:
                with self.subTest(output=output):
                    environment = dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"],
                                       TMPDIR=str(root), STUB_ARGUMENTS=str(recorded),
                                       STUB_OUTPUT=output, STUB_EXIT=str(swift_exit))
                    result = subprocess.run(
                        ["bash", str(ROOT / "scripts/run-nested-suite.sh"), selector, "--no-parallel"],
                        env=environment, text=True, capture_output=True, timeout=10)
                    self.assertEqual(result.returncode, expected_exit, result.stdout + result.stderr)
                    self.assertEqual(json.loads(recorded.read_text()),
                                     ["test", "--skip-build", "--filter", selector, "--no-parallel"])

    def test_lanes_are_independent_on_dedicated_supported_mac_runners(self):
        for job_id, lane in LANES.items():
            with self.subTest(lane=lane):
                job = self.jobs[job_id]
                # A Darkbloom macOS sandbox when granted, otherwise the same
                # dedicated Blacksmith runner; requested only when the lane runs.
                self.assertIn("    runs-on: ${{ fromJSON(needs.route.outputs.routes)['%s'] }}\n" % job_id, job)
                # The provider lane asks for one runner per shard.
                count = 4 if job_id == "test-provider" else 1
                self.assertIn("        %s macos_arm64 blacksmith-12vcpu-macos-27 "
                              "${{ needs.changes.outputs.provider == 'true' && %d || 0 }}\n" % (job_id, count),
                              self.jobs["route"])
                self.assertIn("    timeout-minutes: 60\n", job)
                self.assertIn("    needs: [changes, route]\n", job)
                self.assertIn("    if: ${{ needs.changes.outputs.provider == 'true' }}\n", job)
                if job_id == "test-provider":
                    # Shards are independent: a failed shard never cancels another.
                    self.assertIn("    strategy:\n      # A failed shard does not cancel the other shards.\n"
                                  "      fail-fast: false\n      matrix:\n        shard: [1, 2, 3, 4]\n", job)
                else:
                    self.assertNotRegex(job, re.compile(r"^    strategy:", re.MULTILINE), msg=job)
                self.assertNotIn("continue-on-error:", job)
                self.assertNotIn("DARKBLOOM_EXCLUSIVE_NATIVE_GPU_TEST:", job)
        self.assertIn("    name: Provider Unit Tests (shard ${{ matrix.shard }})\n", self.jobs["test-provider"])

    def test_existing_required_check_requires_every_lane_even_after_failures(self):
        job = self.jobs["provider-test-gate"]
        self.assertIn("    name: Provider Tests\n", job)
        self.assertIn("    needs: [changes, test-provider, test-provider-summary, test-provider-sdk, test-provider-parity]\n", job)
        self.assertIn("    if: ${{ always() }}\n", job)
        self.assertNotIn("continue-on-error:", job)
        step = step_blocks(job)[0]
        command = run_command(step)
        for unit, summary, sdk, parity in (("success", "success", "success", "success"),
                                           ("failure", "success", "success", "success"),
                                           ("success", "failure", "success", "success"),
                                           ("success", "success", "failure", "success"),
                                           ("success", "success", "success", "failure"),
                                           ("skipped", "success", "success", "success"),
                                           ("success", "skipped", "success", "success"),
                                           ("success", "success", "cancelled", "success")):
            result = subprocess.run(["bash", "-e", "-c", command],
                                    env={**os.environ, "CHANGES_RESULT": "success", "PROVIDER_CHANGED": "true", "UNIT_RESULT": unit,
                                         "SUMMARY_RESULT": summary, "SDK_RESULT": sdk, "PARITY_RESULT": parity},
                                    capture_output=True, timeout=5)
            self.assertEqual(result.returncode == 0, unit == summary == sdk == parity == "success")

    def test_each_lane_checks_out_recursive_sources_before_its_build(self):
        for job_id, lane in LANES.items():
            with self.subTest(lane=lane):
                steps = step_blocks(self.jobs[job_id])
                self.assertIn("actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683", steps[0])
                self.assertEqual(field(steps[0], "submodules", indent=10), "recursive")
                builds = [step for step in steps if field(step, "uses") == BUILD_ACTION]
                self.assertEqual(len(builds), 1)
                self.assertEqual(field(builds[0], "lane", indent=10), lane)
                self.assertEqual(field(builds[0], "id"), "provider-ci-build")
                self.assertIsNone(field(builds[0], "if"))
                if lane == "sdk":
                    self.assertEqual(field(builds[0], "timeout-minutes"), "35")
                restores = [step for step in steps if "actions/cache/restore@" in step]
                if lane == "provider":
                    self.assertEqual(len(restores), 1)
                    self.assertEqual(field(restores[0], "id"), "mimo-audio-cache")
                    self.assertIn("mimo-audio-source-v2-", restores[0])
                    self.assertGreater(steps.index(restores[0]), steps.index(builds[0]))
                else:
                    self.assertEqual(restores, [])
                self.assertNotIn("spm-v3-", self.jobs[job_id])

    def test_only_the_provider_lane_collects_and_reports_coverage(self):
        steps = step_blocks(self.jobs["test-provider"])
        names = [field(step, "name", indent=6) for step in steps]
        build = next(index for index, step in enumerate(steps) if field(step, "uses") == BUILD_ACTION)
        collect = names.index(COVERAGE_STEPS[0])
        merge = names.index(COVERAGE_STEPS[1])
        shard_upload = names.index(SHARD_UPLOAD)
        tests = [index for index, step in enumerate(steps)
                 if "run-provider-tests.sh" in step or "run-nested-suite.sh" in step]
        # Profiles go to one directory from the first provider process on;
        # each shard merges them after every test step, which cannot change
        # the test results, and uploads them with its executed counts.
        self.assertEqual(collect, build + 1)
        self.assertIn('echo "LLVM_PROFILE_FILE=$profiles/%p-%m.profraw" >> "$GITHUB_ENV"', steps[collect])
        self.assertIn('echo "PROVIDER_COVERAGE_DIR=$profiles" >> "$GITHUB_ENV"', steps[collect])
        self.assertGreater(merge, max(tests))
        self.assertEqual(shard_upload, merge + 1)
        skipped_tests = "${{ !cancelled() && steps.provider-unit-tests.outcome != 'skipped' }}"
        self.assertEqual(field(steps[merge], "if"), skipped_tests)
        self.assertEqual(field(steps[shard_upload], "if"), skipped_tests)
        self.assertIn('profiles=("$PROVIDER_COVERAGE_DIR"/*.profraw)', steps[merge])
        self.assertIn("xcrun llvm-profdata merge", steps[merge])
        self.assertIn("name: provider-unit-shard-${{ matrix.shard }}", steps[shard_upload])
        self.assertIn("if-no-files-found: error", steps[shard_upload])
        for step in (steps[merge], steps[shard_upload]):
            self.assertNotIn("continue-on-error:", step)
        # The summary merges every shard's profile against the shards' cached
        # build and writes the report; the gate requires it.
        summary = self.jobs["test-provider-summary"]
        self.assertIn("    name: Provider Unit Tests Summary\n", summary)
        self.assertIn("    needs: [changes, route, test-provider]\n", summary)
        self.assertIn("    if: ${{ !cancelled() && needs.changes.outputs.provider == 'true' }}\n", summary)
        self.assertIn("    runs-on: ${{ fromJSON(needs.route.outputs.routes)['test-provider-summary'] }}\n", summary)
        self.assertNotIn("continue-on-error:", summary)
        summary_steps = step_blocks(summary)
        summary_names = [field(step, "name", indent=6) for step in summary_steps]
        summary_build = next(index for index, step in enumerate(summary_steps)
                             if field(step, "uses") == BUILD_ACTION)
        self.assertEqual(field(summary_steps[summary_build], "lane", indent=10), "provider")
        download = summary_names.index("Download shard reports")
        audit = summary_names.index("Check that the shards executed the full provider suite")
        report = summary_names.index("Report provider coverage")
        upload = summary_names.index("Upload provider coverage report")
        self.assertLess(summary_build, download)
        self.assertLess(download, audit)
        self.assertLess(audit, report)
        self.assertEqual(upload, report + 1)
        self.assertIn("pattern: provider-unit-shard-*", summary_steps[download])
        self.assertEqual(field(summary_steps[report], "if"), READY)
        self.assertEqual(field(summary_steps[audit], "if"), READY)
        self.assertIn('profiles=("$RUNNER_TEMP"/provider-unit-shards/*/provider.profdata)', summary_steps[report])
        self.assertIn("xcrun llvm-profdata merge", summary_steps[report])
        self.assertIn("name: provider-coverage", summary_steps[upload])
        test_step = next(step for step in steps if run_command(step) == PROVIDER_TEST_COMMAND)
        self.assertEqual(field(test_step, "id"), "provider-unit-tests")
        self.assertNotIn("LLVM_PROFILE_FILE", summary)
        for job_id in ("test-provider-sdk", "test-provider-parity"):
            self.assertNotIn("LLVM_PROFILE_FILE", self.jobs[job_id])
            self.assertNotIn("PROVIDER_COVERAGE_DIR", self.jobs[job_id])
        build_step = next(step for step in step_blocks(ACTION.read_text(), indent=4)
                          if field(step, "id", indent=6) == "provider-build")
        self.assertIn('if [ "$LANE" = provider ]; then\n  coverage=(--enable-code-coverage)',
                      textwrap.dedent(build_step.split("run: |\n", 1)[1]))

    def test_provider_entrypoint_and_resource_installer_checks_are_retained(self):
        steps = step_blocks(self.jobs["test-provider"])
        expected = (
            "python3 scripts/test-qwen4-packaged-resources.py",
            "python3 scripts/test-stage-swiftpm-resource-bundles.py",
            "python3 scripts/test-profile-inventory-auth.py",
            MIMO_HTTP_PREPARE,
            MIMO_PROVIDER_PREPARE,
            PROVIDER_TEST_COMMAND,
            "python3 scripts/test-desktop-api.py provider-swift/.build/debug/darkbloom",
            *MIMO_NATIVE_COMMANDS.values(),
            'python3 scripts/prepare-mimo-audio-fixtures.py --cache "$RUNNER_TEMP/mimo-audio-source" --output "$RUNNER_TEMP/mimo-audio-fixtures" --github-env "$GITHUB_ENV"',
            "../scripts/run-nested-suite.sh testNativeAudioRelease --no-parallel",
            "./scripts/test-install-atomic.sh",
        )
        runs = [run_command(step) for step in steps
                if field(step, "run") and field(step, "name", indent=6) not in COVERAGE_STEPS]
        self.assertEqual(runs, list(expected))
        test_step = next(step for step in steps if run_command(step) == PROVIDER_TEST_COMMAND)
        self.assertEqual(field(test_step, "id"), "provider-unit-tests")
        self.assertEqual(field(test_step, "timeout-minutes"), "35")
        self.assertEqual(field(test_step, "PROVIDER_TEST_SHARD", indent=10),
                         "${{ matrix.shard }}/${{ strategy.job-total }}")
        self.assertEqual(field(test_step, "PROVIDER_TEST_REPORT_DIR", indent=10),
                         "${{ runner.temp }}/provider-unit-shard")
        # Every shard prepares the fixtures its suites read; every other check
        # in this job runs once, in the last shard.
        every_shard = {MIMO_HTTP_PREPARE, MIMO_PROVIDER_PREPARE, PROVIDER_TEST_COMMAND}
        for step in steps:
            command = run_command(step) if field(step, "run") else None
            if command in every_shard:
                self.assertNotIn("matrix.shard", field(step, "if") or "")
            elif command in expected:
                with self.subTest(step=field(step, "name", indent=6)):
                    self.assertIn(LAST_SHARD, field(step, "if"))

        self.assertEqual(field(test_step, "working-directory"), "provider-swift")
        self.assertEqual(field(test_step, "if"), PROVIDER_MIMO_READY)
        self.assertEqual(field(test_step, "MIMO_V26_PROVIDER_LIFETIME_METADATA_TESTS", indent=10), "'1'")
        desktop = next(step for step in steps if "scripts/test-desktop-api.py" in (run_command(step) or ""))
        self.assertEqual(field(desktop, "if"), LAST_SHARD_READY)
        self.assertEqual(field(desktop, "timeout-minutes"), "3")
        installer = next(step for step in steps if run_command(step) == "./scripts/test-install-atomic.sh")
        self.assertEqual(field(installer, "if"), "${{ !cancelled() && %s }}" % LAST_SHARD)
        self.assertEqual(field(installer, "timeout-minutes"), "2")
        self.assertNotIn("rustup", self.jobs["test-provider"])
        self.assertNotIn("actions/setup-go@", self.jobs["test-provider"])

    def test_atomic_installer_checks_use_only_the_canonical_public_script(self):
        script = (ROOT / "scripts/test-install-atomic.sh").read_text()
        self.assertIn('INSTALLER="$REPO_ROOT/scripts/install.sh"', script)
        self.assertNotIn("coordinator/api/install.sh", script)
        self.assertNotIn("sync-install-embed.sh", script)
        for safeguard in ("assert_no_clt_tools", "assert_no_privileged_install",
                          "assert_fan_variants_rejected", "assert_flat_only_rejected",
                          "assert_pre_paged_rejected", "run_install_without_hashes",
                          'run_install "$DIVERGED"', 'run_install "$TAMPERED"',
                          "DARKBLOOM_TEST_SMOKE_NO_ATTEST=1"):
            self.assertIn(safeguard, script)

    def test_provider_watchdog_diagnostics_survive_test_failure_not_cancellation(self):
        steps = step_blocks(self.jobs["test-provider"])
        upload = next(step for step in steps if field(step, "name", indent=6) == "Upload provider test diagnostics")
        self.assertEqual(field(upload, "if"), "${{ !cancelled() && steps.provider-unit-tests.outcome != 'skipped' }}")
        self.assertEqual(field(upload, "uses"), "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1")
        self.assertEqual(field(upload, "path", indent=10), "${{ runner.temp }}/provider-test-diagnostics")
        self.assertEqual(field(upload, "retention-days", indent=10), "7")
        self.assertNotIn("continue-on-error:", self.jobs["test-provider"])

    def test_coverage_summary_preserves_weighted_rows_and_failure_checks(self):
        report = next(step for step in step_blocks(self.jobs["test-provider-summary"])
                      if field(step, "id") == "provider-coverage")
        summary_script = run_command(report).split("<<'PY'\n", 1)[1].split("\nPY", 1)[0]
        source_root = "/fixture/provider-swift/Sources"
        metrics = ("lines", "regions", "functions")

        def summary(covered, count):
            return {metric: {"covered": covered, "count": count} for metric in metrics}

        # Unequal file sizes pin weighted coverage, rather than an average
        # of percentages. Only the total includes the helper target.
        files = [
            {"filename": f"{source_root}/{target}/File.swift", "summary": summary(covered, count)}
            for target, covered, count in (
                ("ProviderCore", 1, 2), ("ProviderCoreFoundation", 2, 8),
                ("ProviderAppAttest", 1, 5), ("DarkbloomFanCore", 1, 5),
                ("darkbloom", 3, 10), ("ProviderBenchmark", 4, 10),
                ("darkbloom-fan-helper", 8, 10),
            )
        ]
        baseline = {"data": [{"files": files, "totals": summary(20, 50)}]}
        with tempfile.TemporaryDirectory(prefix="provider-coverage-summary-") as temporary:
            export = Path(temporary) / "coverage.json"
            for scenario in ("valid", "missing metric", "empty row"):
                with self.subTest(scenario=scenario):
                    payload = json.loads(json.dumps(baseline))
                    if scenario == "missing metric":
                        del payload["data"][0]["files"][0]["summary"]["regions"]
                    elif scenario == "empty row":
                        payload["data"][0]["files"] = [entry for entry in payload["data"][0]["files"]
                                                        if "/darkbloom/" not in entry["filename"]]
                    export.write_text(json.dumps(payload))
                    result = subprocess.run(
                        [sys.executable, "-c", summary_script, str(export), source_root],
                        capture_output=True, text=True, timeout=5)
                    if scenario != "valid":
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn("regions" if scenario == "missing metric" else
                                      "No lines for Provider CLI (`darkbloom`)", result.stderr)
                        continue
                    self.assertEqual(result.returncode, 0, result.stderr)
                    rows = [line for line in result.stdout.splitlines() if line.startswith("| Provider")]
                    self.assertEqual(rows, [
                        "| Provider (Swift) product | 25.00% of 20 lines | 25.00% regions | 25.00% | 80% (report-only) |",
                        "| Provider CLI (`darkbloom`) | 30.00% of 10 lines | 30.00% regions | 30.00% | 80% (report-only) |",
                        "| Provider benchmark (`ProviderBenchmark`) | 40.00% of 10 lines | 40.00% regions | 40.00% | 80% (report-only) |",
                        "| Provider (Swift) total | 40.00% of 50 lines | 40.00% regions | 40.00% | 80% (report-only) |",
                    ])
                    self.assertIn("These targets are only in the total: `darkbloom-fan-helper`.", result.stdout)

    def test_sdk_retains_every_original_gate_command(self):
        steps = step_blocks(self.jobs["test-provider-sdk"])
        gates = {field(step, "name", indent=6): step for step in steps if field(step, "run")}
        self.assertEqual(len(gates), sum(bool(field(step, "run")) for step in steps))
        self.assertEqual(set(gates), set(SDK_COMMANDS) | {"Run Nemotron production SDK gates"})
        for name, command in SDK_COMMANDS.items():
            with self.subTest(gate=name):
                self.assertEqual(run_command(gates[name]), command)
        commands = "\n".join(run_command(step) for step in gates.values())
        self.assertNotIn("swift test", commands)
        self.assertNotIn("--skip", commands)
        self.assertNotIn("rustup", self.jobs["test-provider-sdk"])

    def test_every_sdk_gate_requires_successful_build_but_not_earlier_tests(self):
        fixture_conditions = {
            SDK_MIMO_GATE_NAME: SDK_MIMO_READY,
            SDK_RETENTION_GATE_NAME: SDK_RETENTION_READY,
        }
        preparation_steps = {SDK_MIMO_PREPARE_NAME, SDK_RETENTION_PREPARE_NAME}
        for step in step_blocks(self.jobs["test-provider-sdk"]):
            if field(step, "run"):
                with self.subTest(gate=field(step, "name", indent=6)):
                    name = field(step, "name", indent=6)
                    self.assertEqual(field(step, "if"), fixture_conditions.get(name, READY))
                    expected_directory = None if name in preparation_steps else "libs/mlx-swift-lm"
                    self.assertEqual(field(step, "working-directory"), expected_directory)
                    self.assertNotIn("continue-on-error:", step)

    def test_sdk_retention_requires_asymmetric_fixture_and_non_skipping_selectors(self):
        steps = step_blocks(self.jobs["test-provider-sdk"])
        by_name = {field(step, "name", indent=6): step for step in steps}
        prepare = by_name[SDK_RETENTION_PREPARE_NAME]
        gate = by_name[SDK_RETENTION_GATE_NAME]
        self.assertEqual(field(prepare, "id"), "sdk-mimo-retention-fixture")
        self.assertEqual(run_command(prepare), SDK_COMMANDS[SDK_RETENTION_PREPARE_NAME])
        self.assertLess(steps.index(prepare), steps.index(gate))
        self.assertEqual(field(gate, "if"), SDK_RETENTION_READY)
        self.assertEqual(field(gate, "timeout-minutes"), "5")
        self.assertEqual(field(gate, "MIMO_V26_SERIAL_NATIVE_TESTS", indent=10), "'1'")
        self.assertEqual(field(gate, "MIMO_V26_SERIAL_LOAD_FIXTURES", indent=10), "${{ runner.temp }}/mimo-native-retention")
        self.assertEqual(run_command(gate), SDK_COMMANDS[SDK_RETENTION_GATE_NAME])
        for name, command in SDK_RETENTION_HOST_COMMANDS.items():
            with self.subTest(gate=name):
                host = by_name[name]
                self.assertEqual(run_command(host), command)
                self.assertEqual(field(host, "timeout-minutes"), "5")
                self.assertNotIn("\n        env:", host)

    def test_sdk_media_isolation_requires_its_fixture_and_native_lane(self):
        steps = step_blocks(self.jobs["test-provider-sdk"])
        prepare = next(step for step in steps if field(step, "name", indent=6) == SDK_MIMO_PREPARE_NAME)
        gate = next(step for step in steps if field(step, "name", indent=6) == SDK_MIMO_GATE_NAME)
        self.assertEqual(field(prepare, "id"), "sdk-mimo-isolation-fixture")
        self.assertLess(steps.index(prepare), steps.index(gate))
        self.assertEqual(field(gate, "timeout-minutes"), "5")
        self.assertEqual(field(gate, "MIMO_V26_SERIAL_NATIVE_TESTS", indent=10), "'1'")
        self.assertEqual(field(gate, "MIMO_V26_NATIVE_MEDIA_DEADLINE_TESTS", indent=10), "'1'")
        self.assertEqual(field(gate, "MIMO_V26_SERIAL_LOAD_FIXTURES", indent=10), "${{ runner.temp }}/mimo-media-isolation")

    def test_sdk_onboarding_selectors_execute_once_and_continue_after_failure(self):
        step = next(step for step in step_blocks(self.jobs["test-provider-sdk"])
                    if field(step, "name", indent=6) == "Run Nemotron production SDK gates")
        command = run_command(step)
        with tempfile.TemporaryDirectory(prefix="provider-ci-workflow-") as temporary:
            root = Path(temporary)
            package = root / "libs/mlx-swift-lm"
            package.mkdir(parents=True)
            scripts = root / "scripts"
            scripts.mkdir()
            runner = scripts / "run-nested-suite.sh"
            runner.write_text('#!/bin/bash\n'
                              'printf "%s\\n" "$*" >> "$CI_GATE_LOG"\n'
                              '[ "$1" != "${CI_FAIL_SUITE:-}" ]\n')
            runner.chmod(0o700)
            for failure in ("", *SDK_ONBOARDING_SUITES):
                with self.subTest(failure=failure):
                    log = root / "calls"
                    log.write_text("")
                    result = subprocess.run(
                        ["bash", "-e", "-o", "pipefail", "-c", command], cwd=package,
                        env={**os.environ, "CI_GATE_LOG": str(log), "CI_FAIL_SUITE": failure},
                        capture_output=True, text=True, timeout=10,
                    )
                    self.assertEqual(result.returncode, 1 if failure else 0, result.stderr)
                    self.assertEqual(log.read_text().splitlines(), list(SDK_ONBOARDING_SUITES))

    def test_required_sdk_selectors_are_not_duplicated_in_other_lanes(self):
        selectors = [shlex.split(command)[1] for command in SDK_COMMANDS.values()
                     if "run-nested-suite.sh" in command]
        selectors.extend(SDK_ONBOARDING_SUITES)
        sdk = "\n".join(run_command(step) for step in step_blocks(self.jobs["test-provider-sdk"])
                        if field(step, "run"))
        for selector in selectors:
            with self.subTest(selector=selector):
                self.assertEqual(sdk.count(selector), 1)
                self.assertNotIn(selector, self.jobs["test-provider"])
                self.assertNotIn(selector, self.jobs["test-provider-parity"])
        commands = Counter(run_command(step) for job in self.jobs.values() for step in step_blocks(job))
        self.assertEqual(commands["../../scripts/run-paged-kernel-tests.sh"], 1)
        self.assertEqual(commands[PROVIDER_TEST_COMMAND], 1)
        self.assertEqual(commands["./scripts/verify-prompt-parity.sh"], 1)

    def test_parity_retains_public_swift_golden_vector_scripts(self):
        steps = step_blocks(self.jobs["test-provider-parity"])
        go = [step for step in steps if "actions/setup-go@" in step]
        self.assertEqual(go, [])
        runs = [step for step in steps if field(step, "run")]
        self.assertEqual([run_command(step) for step in runs],
                         [MIMO_PREPARE, "./scripts/verify-prompt-parity.sh",
                          "./scripts/verify-nemotron-prompt-parity.sh"])
        self.assertEqual(field(runs[-2], "if"), MIMO_READY)
        self.assertEqual(field(runs[-1], "if"), READY)

    def test_fixture_prerequisites_are_fail_closed_in_provider_and_parity(self):
        for job_id in ("test-provider", "test-provider-parity"):
            steps = step_blocks(self.jobs[job_id])
            expected_prepare = MIMO_HTTP_PREPARE if job_id == "test-provider" else MIMO_PREPARE
            fixtures = [step for step in steps if run_command(step) == expected_prepare]
            self.assertEqual(len(fixtures), 1)
            expected_id = "mimo-prompt-fixtures" if job_id == "test-provider" else "mimo-fixtures"
            self.assertEqual(field(fixtures[0], "id"), expected_id)
            self.assertEqual(field(fixtures[0], "if"), READY)

    def test_native_mimo_gates_keep_isolated_processes_and_fixture_guards(self):
        steps = step_blocks(self.jobs["test-provider"])
        synthetic = next(step for step in steps if run_command(step) == MIMO_PROVIDER_PREPARE)
        self.assertEqual(field(synthetic, "id"), "mimo-fixtures")
        self.assertEqual(field(synthetic, "if"), READY)
        for name, command in MIMO_NATIVE_COMMANDS.items():
            with self.subTest(gate=name):
                gate = next(step for step in steps if field(step, "name", indent=6) == name)
                self.assertEqual(run_command(gate), command)
                self.assertEqual(field(gate, "if"), LAST_SHARD_MIMO_READY)
                self.assertEqual(field(gate, "working-directory"), "provider-swift")
                self.assertEqual(field(gate, "timeout-minutes"), "5")
                self.assertEqual(field(gate, "MIMO_V26_SERIAL_NATIVE_TESTS", indent=10), "'1'")
                self.assertNotIn("continue-on-error:", gate)
                self.assertNotIn("steps.run", field(gate, "if"))
        prefix = next(step for step in steps if field(step, "name", indent=6) == "Run isolated native MiMo complete-prefix gates")
        self.assertEqual(field(prefix, "MIMO_V26_SERIAL_LOAD_FIXTURES", indent=10), "${{ runner.temp }}/mimo-prefix-fixtures")
        fault = next(step for step in steps if field(step, "name", indent=6) == "Run isolated native MiMo retained-fault gate")
        self.assertEqual(field(fault, "MIMO_V26_PROVIDER_LIFETIME_NATIVE_TESTS", indent=10), "'1'")
        self.assertEqual(field(fault, "DARKBLOOM_PREFIX_CACHE", indent=10), "'0'")
        self.assertEqual(field(fault, "DARKBLOOM_PREFIX_CACHE_MEMORY", indent=10), "'0'")
        drain = next(step for step in steps if field(step, "name", indent=6) == "Run isolated native MiMo lifecycle drain gate")
        self.assertEqual(field(drain, "MIMO_V26_PROVIDER_LIFETIME_NATIVE_TESTS", indent=10), "'1'")
        self.assertEqual(field(drain, "DARKBLOOM_PREFIX_CACHE", indent=10), "'0'")
        self.assertEqual(field(drain, "DARKBLOOM_PREFIX_CACHE_MEMORY", indent=10), "'0'")
        self.assertNotIn("MIMO_V26_PROVIDER_LIFETIME_FAULT_CASE", drain)

    def test_audio_qualification_uses_real_codec_and_no_skip_gate(self):
        steps = step_blocks(self.jobs["test-provider"])
        fixture = next(s for s in steps if field(s, "id") == "mimo-audio-fixtures")
        self.assertIn("prepare-mimo-audio-fixtures.py", run_command(fixture))
        self.assertEqual(field(fixture, "if"), LAST_SHARD_READY)
        gate = next(s for s in steps if field(s, "name", indent=6) == "Run isolated native MiMo audio gate")
        self.assertIn("testNativeAudioRelease", run_command(gate))
        self.assertIn("run-nested-suite.sh", run_command(gate))
        self.assertIn("steps.mimo-audio-fixtures.outcome == 'success'", field(gate, "if"))
        self.assertIn(LAST_SHARD, field(gate, "if"))
        self.assertEqual(field(gate, "MIMO_V26_MANAGED_AUDIO_PROVIDER_TESTS", indent=10), "'1'")
        self.assertNotIn("continue-on-error:", gate)

    def test_cluster_metadata_runners_run_every_runner_and_fail_on_any(self):
        job = self.jobs["test-cluster-checks"]
        self.assertIn("    name: Cluster Metadata Checks\n", job)
        self.assertIn("    needs: [changes, route]\n", job)
        self.assertIn("    if: ${{ needs.changes.outputs.provider == 'true' }}\n", job)
        self.assertIn("    runs-on: ${{ fromJSON(needs.route.outputs.routes)['test-cluster-checks'] }}\n", job)
        self.assertIn("        test-cluster-checks macos_arm64 blacksmith-12vcpu-macos-27 "
                      "${{ needs.changes.outputs.provider == 'true' && 1 || 0 }}\n", self.jobs["route"])
        for forbidden in ("continue-on-error:", "secrets.", "DARKBLOOM_EXCLUSIVE_NATIVE_GPU_TEST:"):
            self.assertNotIn(forbidden, job)
        steps = step_blocks(job)
        self.assertIn("actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683", steps[0])
        self.assertEqual(field(steps[0], "submodules", indent=10), "recursive")
        toolchain = next(step for step in steps if field(step, "id") == "toolchain")
        self.assertEqual(run_command(toolchain), "./scripts/prepare-provider-release-toolchain.sh")
        runners = {
            "Run worker capability checks": "bash libs/darkbloom-cluster-worker/Tests/CapabilityChecks/run.sh",
            "Run stage metadata checks": 'python3 libs/darkbloom-cluster/Tests/StageMetadataChecks/run.py '
                                         '--output "$RUNNER_TEMP/stage-metadata-checks"',
            "Run GPT-OSS stage checks": "bash libs/darkbloom-cluster/Tests/GPTOSSStageChecks/run.sh",
            "Run Nemotron stage checks": "bash libs/darkbloom-cluster/Tests/NemotronStageChecks/run.sh",
            "Run cluster model provisioning checks": "bash provider-swift/Tests/ClusterModelProvisioningChecks/run.sh provisioning",
        }
        named = {field(step, "name", indent=6): step for step in steps}
        for name, command in runners.items():
            with self.subTest(runner=name):
                step = named[name]
                self.assertEqual(run_command(step), command)
                # Each runner needs only the toolchain, not an earlier runner's success.
                self.assertEqual(field(step, "if"), "${{ !cancelled() && steps.toolchain.outcome == 'success' }}")
                self.assertTrue((ROOT / command.split()[1]).is_file())
        # The capability build may use the whole dedicated runner.
        capability = named["Run worker capability checks"]
        self.assertEqual(field(capability, "DARKBLOOM_CLUSTER_METADATA_BUILD_JOBS", indent=10), "'12'")
        # Its release build is restored with timestamps only for unchanged
        # sources, keyed by toolchain, manifests, submodule pins and paths.
        self.assertEqual(field(capability, "DARKBLOOM_CLUSTER_METADATA_BUILD_ROOT", indent=10),
                         "${{ runner.temp }}/cluster-native-metadata")
        order = [field(step, "name", indent=6) for step in steps]
        restore, timestamps, record, upload = (order.index(name) for name in (
            "Restore cluster metadata build", "Restore unchanged source timestamps",
            "Record source timestamps for the cluster build", "Upload cluster metadata build cache"))
        self.assertLess(restore, timestamps)
        self.assertLess(timestamps, order.index("Run worker capability checks"))
        self.assertLess(order.index("Run worker capability checks"), record)
        self.assertEqual(upload, record + 1)
        self.assertIn("python3 scripts/provider-release-cache.py restore-mtimes", steps[timestamps])
        self.assertIn("python3 scripts/provider-release-cache.py snapshot-mtimes", steps[record])
        key = named["Resolve cluster metadata build cache key"]
        for component in ("swift --version", "xcodebuild -version", "git submodule status --recursive",
                          "$GITHUB_WORKSPACE $RUNNER_TEMP $MANIFESTS", "native-metadata.sh"):
            self.assertIn(component, key)
        for step in (steps[record], steps[upload]):
            self.assertIn("steps.capability-checks.outcome == 'success'", field(step, "if"))
        support = (ROOT / "libs/darkbloom-cluster/Tests/Support/native-metadata.sh").read_text()
        self.assertIn('task_jobs="${DARKBLOOM_CLUSTER_METADATA_BUILD_JOBS:-4}"', support)
        self.assertIn('--jobs "$task_jobs"', support)

    def test_parity_has_no_backend_caches_or_credentials(self):
        steps = step_blocks(self.jobs["test-provider-parity"])
        saves = [step for step in steps if "actions/cache/save@" in step]
        self.assertEqual(saves, [])
        for forbidden in ("coordinator/", "cargo ", "rust-key", "secrets.", "darkbloom-platform"):
            self.assertNotIn(forbidden, self.jobs["test-provider-parity"])

    def test_push_only_release_build_no_longer_warms_sdk_debug_tests(self):
        job = self.jobs["cache-swift"]
        self.assertIn("    if: github.event_name == 'push'", job)
        runs = [run_command(step) for step in step_blocks(job) if field(step, "run")]
        self.assertIn("swift build -c release --product darkbloom\n"
                      "swift build -c release --product darkbloom-fan-helper", runs)
        self.assertNotIn("swift build --build-tests", job)
        self.assertNotIn("working-directory: libs/mlx-swift-lm", job)
        self.assertIn("actions/cache/save@1bd1e32a3bdc45362d1e726936510720a7c30a57", job)

    def test_offline_workflow_test_runs_in_release_integrity(self):
        self.assertIn("python3 provider-swift/Tests/test_protocol_fixture_resources.py", self.jobs["release-integrity"])
        self.assertIn("python3 scripts/test-provider-ci-cache.py", self.jobs["release-integrity"])
        self.assertIn("python3 scripts/test-provider-ci-workflow.py", self.jobs["release-integrity"])
        self.assertIn("python3 scripts/test-provider-test-shards.py", self.jobs["release-integrity"])
        self.assertIn("python3 scripts/test-native-gpu-ci.py", self.jobs["release-integrity"])

    def test_composite_action_cannot_bypass_build_and_metallib_on_cache_hits(self):
        action = ACTION.read_text()
        self.assertIn("using: composite", action)
        self.assertNotIn("continue-on-error:", action)
        self.assertIn("provider-ci-cache.py", action)
        steps = step_blocks(action, indent=4)
        by_id = {field(step, "id", indent=6): step for step in steps if field(step, "id", indent=6)}
        provider = by_id["provider-build"]
        sdk = by_id["sdk-build"]
        metallib = by_id["metallib"]
        self.assertEqual(field(provider, "if", indent=6), "inputs.lane != 'sdk'")
        self.assertEqual(field(provider, "working-directory", indent=6), "provider-swift")
        self.assertIn("swift build --build-tests", provider)
        self.assertIn("swift build --product darkbloom-fan-helper", provider)
        self.assertEqual(field(sdk, "if", indent=6), "inputs.lane == 'sdk'")
        self.assertEqual(field(sdk, "working-directory", indent=6), "libs/mlx-swift-lm")
        self.assertIn("swift package edit --path ../mlx-swift mlx-swift", sdk)
        self.assertIn("swift build --build-tests", sdk)
        self.assertIsNone(field(metallib, "if", indent=6))
        self.assertIn('./scripts/stage-test-metallib.sh "$bin"', metallib)
        for step in (provider, sdk, metallib):
            self.assertNotIn("--filter", step)
            self.assertNotIn("--skip", step)
            self.assertNotIn("cache-hit", step)

    def test_composite_cache_keys_retain_swift_and_metal_without_backend_work(self):
        action = ACTION.read_text()
        steps = step_blocks(action, indent=4)
        by_id = {field(step, "id", indent=6): step for step in steps if field(step, "id", indent=6)}
        swift_cache = by_id["swift-cache"]
        self.assertIn("key: ${{ steps.keys.outputs.swift-key }}", swift_cache)
        self.assertIn("restore-keys: ${{ steps.keys.outputs.swift-prefix }}", swift_cache)
        metal_cache = by_id["metallib-cache"]
        self.assertIn("key: ${{ steps.keys.outputs.metallib-key }}", metal_cache)
        self.assertNotIn("restore-keys:", metal_cache)
        rust_steps = [step for step in steps if "install-release-rust.sh" in step
                      or "cargo +1.88.0 clean" in step or field(step, "id", indent=6) == "rust-cache"]
        self.assertEqual(rust_steps, [])
        self.assertNotIn("rust-key:", action)
        self.assertNotIn("rust-cache-hit:", action)
        self.assertEqual(sum("actions/cache/save@" in step for step in steps), 2)


if __name__ == "__main__":
    unittest.main()
