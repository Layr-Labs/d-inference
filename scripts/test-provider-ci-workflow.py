#!/usr/bin/env python3
"""Offline CI lane/gate checks; actionlint validates the complete YAML syntax."""

from collections import Counter
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest


ROOT = Path(__file__).resolve().parent.parent
_SPEC = importlib.util.spec_from_file_location("provider_test_shards", ROOT / "scripts/provider-test-shards.py")
shards = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(shards)
# The test jobs live in the reusable provider-tests.yml; Release Integrity and
# Docs Lint are CI (master)'s own jobs. CI (dev) runs only the test jobs.
WORKFLOW = ROOT / ".github/workflows/provider-tests.yml"
MASTER_WORKFLOW = ROOT / ".github/workflows/ci-master.yml"
DEV_WORKFLOW = ROOT / ".github/workflows/ci-dev.yml"


def workflow_text():
    """The test workflow, then CI (master): every job CI runs, each once."""
    return WORKFLOW.read_text() + "\n" + MASTER_WORKFLOW.read_text()

ACTION = ROOT / ".github/actions/provider-ci-build/action.yml"
BUILD_ACTION = "./.github/actions/provider-ci-build"
PROVIDER_TEST_COMMAND = ('python3 ../scripts/run-provider-test-watchdog.py \\\n'
                         '  --output-dir "$RUNNER_TEMP/provider-test-diagnostics" \\\n'
                         '  --diagnostic-after-seconds 900 --timeout-seconds 1800 \\\n'
                         '  -- ../scripts/run-provider-tests.sh')
READY = "${{ !cancelled() && steps.provider-ci-build.outcome == 'success' }}"
MIMO_READY = "${{ !cancelled() && steps.provider-ci-build.outcome == 'success' && steps.mimo-fixtures.outcome == 'success' }}"
SDK_CONDITION = "github.event_name == 'push' || needs.changes.outputs.sdk == 'true'"
# Steps that run once, in the last provider shard.
LAST_SHARD = "matrix.shard == strategy.job-total"
LAST_SHARD_READY = READY.replace("!cancelled() && ", f"!cancelled() && {LAST_SHARD} && ")
LAST_SHARD_MIMO_READY = MIMO_READY.replace("!cancelled() && ", f"!cancelled() && {LAST_SHARD} && ")
PROVIDER_MIMO_READY = "${{ !cancelled() && steps.provider-ci-build.outcome == 'success' && steps.mimo-prompt-fixtures.outcome == 'success' && steps.mimo-fixtures.outcome == 'success' }}"
MIMO_METADATA_CACHE = '--cache "$RUNNER_TEMP/mimo-metadata-cache"'
MIMO_PREPARE = ('python3 scripts/prepare-mimo-prompt-fixtures.py '
                '--output "$RUNNER_TEMP/mimo-prompt-fixtures" --github-env "$GITHUB_ENV" ' + MIMO_METADATA_CACHE)
MIMO_HTTP_PREPARE = ('python3 scripts/test-prepare-mimo-image-http-fixtures.py\n'
                     + MIMO_PREPARE + '\n'
                     + 'python3 scripts/prepare-mimo-image-http-fixtures.py '
                     '--output "$RUNNER_TEMP/mimo-image-http-fixtures" --github-env "$GITHUB_ENV" ' + MIMO_METADATA_CACHE)
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
}
PROVIDER_SHARDS = [1, 2]
# Each shard runs this many selections at the same time (scripts/run-provider-tests.sh),
# so the planner splits the suite into len(PROVIDER_SHARDS) * PROVIDER_PROCESSES selections.
PROVIDER_PROCESSES = 3
# Prompt Parity runs in the provider shard that holds selection
# PARITY_SHARD (scripts/provider-test-shards.py).
PARITY_STEPS = {
    "Verify public prompt golden vectors": ("./scripts/verify-prompt-parity.sh", "ProductionPromptParityTests", "prompt"),
    "Verify pinned Nemotron prompts and numeric cache plans":
        ("./scripts/verify-nemotron-prompt-parity.sh", "NemotronTemplateParityLiveTests", "nemotron"),
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


CHECKOUT = "actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2"
CACHE_RESTORE = "actions/cache/restore@1bd1e32a3bdc45362d1e726936510720a7c30a57 # v4.2.0"
CACHE_SAVE = "actions/cache/save@1bd1e32a3bdc45362d1e726936510720a7c30a57 # v4.2.0"
# Pushes to master and dev save caches; pull requests never do.
SAVE_POLICY = ("  SAVE_CACHES: ${{ github.event_name == 'push' && (github.ref == 'refs/heads/master' "
               "|| github.ref == 'refs/heads/dev') }}\n")
SAVE_CACHES = "env.SAVE_CACHES == 'true'"
SAVE_INPUT = "inputs.save-caches == 'true'"
VALIDATE_GIT = """if [ -d .git ] && ! { git rev-parse --verify -q HEAD >/dev/null &&
    git fsck --connectivity-only --no-progress >/dev/null 2>&1; }; then
  echo "::warning title=.git cache::git fsck rejected the restored .git; checking out without it."
  rm -rf .git
fi"""
SPARSE_PATTERNS = ("/*", "!/docs/reports/evidence/**/*.gz", "!/landing/public/media/")
GIT_CACHE_STEPS = ("Select today's .git cache", "Restore the newest saved .git",
                   "Discard a damaged cached .git", None, "Save .git for later runs")


def uses(step):
    """The action a step uses, whether `uses:` opens the step or follows `name:`."""
    return field(step, "uses") or field(step, "uses", indent=6)


def checkout_options(step):
    lines = step.split("        with:\n", 1)[1].splitlines()
    return [line.split(" #", 1)[0].strip() for line in lines if line.startswith("          ")]


def work_steps(job):
    """The steps after the shared .git cache and checkout steps."""
    return [step for step in step_blocks(job) if field(step, "name", indent=6) not in GIT_CACHE_STEPS]


class ProviderCIWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.workflow = workflow_text()
        self.jobs = {**job_blocks(WORKFLOW.read_text().split("\njobs:\n", 1)[1]),
                     **job_blocks(MASTER_WORKFLOW.read_text().split("\njobs:\n", 1)[1])}

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
                if job_id == "test-provider":
                    # Shards are independent: a failed shard never cancels
                    # another, and each shard reads a route lane of its own.
                    self.assertIn("    strategy:\n      # A failed shard does not cancel the other shards.\n"
                                  "      fail-fast: false\n      matrix:\n        shard: %s\n" % PROVIDER_SHARDS, job)
                    route_lanes = [f"test-provider-{shard}" for shard in PROVIDER_SHARDS]
                    lane_key = "format('test-provider-{0}', matrix.shard)"
                else:
                    self.assertNotRegex(job, re.compile(r"^    strategy:", re.MULTILINE), msg=job)
                    route_lanes = [job_id]
                    lane_key = f"'{job_id}'"
                # A Darkbloom macOS sandbox when granted, otherwise the same
                # dedicated Blacksmith runner; requested only when the job runs.
                self.assertIn("    runs-on: ${{ fromJSON(needs.route.outputs.routes)[%s] }}\n" % lane_key, job)
                # The SDK lane runs on every push and on pull requests that change its inputs.
                condition = (SDK_CONDITION if job_id == "test-provider-sdk"
                             else "needs.changes.outputs.provider == 'true'")
                requested = f"({condition})" if "||" in condition else condition
                for route_lane in route_lanes:
                    self.assertIn("        %s macos_arm64 blacksmith-12vcpu-macos-27 "
                                  "${{ %s && 1 || 0 }}\n" % (route_lane, requested), self.jobs["route"])
                self.assertIn("    timeout-minutes: 60\n", job)
                self.assertIn("    needs: [changes, route]\n", job)
                self.assertIn("    if: ${{ %s }}\n" % condition, job)
                self.assertNotIn("continue-on-error:", job)
                self.assertNotIn("DARKBLOOM_EXCLUSIVE_NATIVE_GPU_TEST:", job)
        self.assertIn("    name: Provider Unit Tests (shard ${{ matrix.shard }})\n", self.jobs["test-provider"])

    def test_route_requests_exactly_one_lane_per_provider_shard(self):
        # The plane grants a lane whole: one lane for all shards would need a
        # free Mac for every shard at once and otherwise fall back entirely.
        # test_lanes_are_independent_on_dedicated_supported_mac_runners pins
        # the matrix to PROVIDER_SHARDS.
        self.assertEqual(re.findall(r"(?m)^        (test-provider(?:-[0-9]+)?) ", self.jobs["route"]),
                         [f"test-provider-{shard}" for shard in PROVIDER_SHARDS])

    def test_existing_required_check_requires_every_lane_even_after_failures(self):
        job = self.jobs["provider-test-gate"]
        self.assertIn("    name: Provider Tests\n", job)
        self.assertIn("    needs: [changes, test-provider, test-provider-summary, test-cluster, test-cluster-focused]\n", job)
        # Provider SDK Tests notifies after merge and never blocks this gate.
        self.assertNotIn("test-provider-sdk", job)
        self.assertIn("    if: ${{ always() }}\n", job)
        self.assertNotIn("continue-on-error:", job)
        step = step_blocks(job)[0]
        command = run_command(step)
        # Prompt Parity is a step of a provider shard: its failure is UNIT_RESULT's.
        self.assertNotIn("test-provider-parity", job)
        lanes = ("UNIT_RESULT", "SUMMARY_RESULT", "CLUSTER_RESULT", "CLUSTER_FOCUSED_RESULT")
        for failed in (None, *lanes):
            for outcome in ("failure", "skipped", "cancelled"):
                results = {lane: outcome if lane == failed else "success" for lane in lanes}
                result = subprocess.run(["bash", "-e", "-c", command],
                                        env={**os.environ, "CHANGES_RESULT": "success", "PROVIDER_CHANGED": "true", "CLUSTER_CHANGED": "true",
                                             **results},
                                        capture_output=True, timeout=5)
                self.assertEqual(result.returncode == 0, failed is None, results)

    def test_each_lane_checks_out_recursive_sources_before_its_build(self):
        for job_id, lane in LANES.items():
            with self.subTest(lane=lane):
                steps = step_blocks(self.jobs[job_id])
                checkout = next(step for step in steps if uses(step) == CHECKOUT)
                self.assertEqual(uses(checkout), CHECKOUT)
                self.assertEqual(field(checkout, "submodules", indent=10), "recursive")
                builds = [step for step in steps if field(step, "uses") == BUILD_ACTION]
                self.assertEqual(len(builds), 1)
                self.assertGreater(steps.index(builds[0]), steps.index(checkout))
                self.assertEqual(field(builds[0], "lane", indent=10), lane)
                self.assertEqual(field(builds[0], "id"), "provider-ci-build")
                self.assertIsNone(field(builds[0], "if"))
                if lane == "sdk":
                    self.assertEqual(field(builds[0], "timeout-minutes"), "35")
                restores = [step for step in steps
                            if "actions/cache/restore@" in step and field(step, "id") != "git-cache"]
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
        # The summary merges every shard's profile against a build of the same
        # commit (the shards' own on master pushes) and writes the report; the
        # gate requires it.
        summary = self.jobs["test-provider-summary"]
        self.assertIn("    name: Provider Unit Tests Summary\n", summary)
        self.assertIn("    needs: [changes, route, test-provider]\n", summary)
        self.assertIn("    if: ${{ !cancelled() && needs.changes.outputs.provider == 'true' }}\n", summary)
        self.assertIn("    runs-on: ${{ fromJSON(needs.route.outputs.routes)['test-provider-summary'] }}\n", summary)
        self.assertIn("        test-provider-summary macos_arm64 blacksmith-12vcpu-macos-27 "
                      "${{ needs.changes.outputs.provider == 'true' && 1 || 0 }}\n", self.jobs["route"])
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
        self.assertNotIn("LLVM_PROFILE_FILE", self.jobs["test-provider-sdk"])
        self.assertNotIn("PROVIDER_COVERAGE_DIR", self.jobs["test-provider-sdk"])
        build_step = next(step for step in step_blocks(ACTION.read_text(), indent=4)
                          if field(step, "id", indent=6) == "provider-build")
        self.assertEqual(textwrap.dedent(build_step.split("run: |\n", 1)[1]).strip(),
                         "build() {\n"
                         "  swift build --build-tests --enable-code-coverage &&\n"
                         "    swift build --product darkbloom-fan-helper --enable-code-coverage\n"
                         "}\n"
                         "build || { ../scripts/provider-ci-cold-retry.sh && build; }")

    def test_provider_entrypoint_and_resource_installer_checks_are_retained(self):
        steps = work_steps(self.jobs["test-provider"])
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
                if field(step, "run") and field(step, "name", indent=6) not in (*COVERAGE_STEPS, *PARITY_STEPS)]
        self.assertEqual(runs, list(expected))
        test_step = next(step for step in steps if run_command(step) == PROVIDER_TEST_COMMAND)
        self.assertEqual(field(test_step, "id"), "provider-unit-tests")
        self.assertEqual(field(test_step, "timeout-minutes"), "35")
        self.assertEqual(field(test_step, "PROVIDER_TEST_SHARD", indent=10),
                         "${{ matrix.shard }}/${{ strategy.job-total }}")
        self.assertEqual(field(test_step, "PROVIDER_TEST_PROCESSES", indent=10), f"'{PROVIDER_PROCESSES}'")
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
        steps = work_steps(self.jobs["test-provider-sdk"])
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
        for step in work_steps(self.jobs["test-provider-sdk"]):
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
        commands = Counter(run_command(step) for job in self.jobs.values() for step in step_blocks(job))
        self.assertEqual(commands["../../scripts/run-paged-kernel-tests.sh"], 1)
        self.assertEqual(commands[PROVIDER_TEST_COMMAND], 1)
        workflow = workflow_text()
        for script, _, _ in PARITY_STEPS.values():
            self.assertEqual(workflow.count(script), 1, script)

    def test_parity_retains_public_swift_golden_vector_scripts(self):
        steps = step_blocks(self.jobs["test-provider"])
        self.assertEqual([step for step in steps if "actions/setup-go@" in step], [])
        names = [field(step, "name", indent=6) for step in steps]
        tests = names.index("Run Swift tests")
        shard = f"matrix.shard == {(shards.PARITY_SHARD - 1) // PROVIDER_PROCESSES + 1}"
        conditions = {
            "Verify public prompt golden vectors":
                "${{ !cancelled() && %s && steps.provider-ci-build.outcome == 'success' && "
                "steps.mimo-prompt-fixtures.outcome == 'success' }}" % shard,
            "Verify pinned Nemotron prompts and numeric cache plans":
                "${{ !cancelled() && %s && steps.provider-ci-build.outcome == 'success' }}" % shard,
        }
        self.assertEqual(sorted(filter_ for _, filter_, _ in PARITY_STEPS.values()),
                         sorted(shards.PARITY_FILTERS))
        for name, (script, filter_, label) in PARITY_STEPS.items():
            with self.subTest(step=name):
                step = steps[names.index(name)]
                # Parity runs in one shard, after its suite, and fails that shard
                # (no continue-on-error), which fails the Provider Tests gate.
                self.assertGreater(names.index(name), tests)
                self.assertEqual(field(step, "if"), conditions[name])
                self.assertNotIn("continue-on-error:", step)
                command = run_command(step)
                self.assertTrue(command.startswith("set -o pipefail\n"), command)
                self.assertIn(f'{script} 2>&1 | tee "$report/parity-{label}.log"', command)
                self.assertIn(f"provider-test-shards.py counts parity {filter_} \\\n"
                              f'  "$report/parity-{label}.log" "$report/shard-parity-{label}.json"', command)
                # Each script still runs exactly its suite, with its artifacts required.
                source = (ROOT / script).read_text()
                self.assertIn("PROMPT_PARITY_REQUIRED=1", source)
                self.assertIn(filter_, source)
        prompt = steps[names.index("Verify public prompt golden vectors")]
        self.assertEqual(field(prompt, "id"), "prompt-parity")
        self.assertEqual(field(prompt, "PROMPT_PARITY_SKIP_BUILD", indent=10), "'1'")
        # Without the opt-in (the release qualification lane), the script builds as before.
        source = (ROOT / "scripts/verify-prompt-parity.sh").read_text()
        self.assertIn('[[ "${PROMPT_PARITY_SKIP_BUILD:-0}" == 0 ]] || skip_build=(--skip-build)', source)
        self.assertIn("run-nested-suite.sh NemotronTemplateParityLiveTests",
                      (ROOT / "scripts/verify-nemotron-prompt-parity.sh").read_text())

    def test_fixture_prerequisites_are_fail_closed_in_provider(self):
        steps = step_blocks(self.jobs["test-provider"])
        fixtures = [step for step in steps if run_command(step) == MIMO_HTTP_PREPARE]
        self.assertEqual(len(fixtures), 1)
        self.assertEqual(field(fixtures[0], "id"), "mimo-prompt-fixtures")
        self.assertEqual(field(fixtures[0], "if"), READY)
        # The HTTP preparation includes the plain prompt-fixture preparation.
        self.assertIn(MIMO_PREPARE, MIMO_HTTP_PREPARE)

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
        # The 1.87 GB codec is fetched only when the gate's inputs changed;
        # the gate needs the fixture, so it skips with it.
        audio_ready = LAST_SHARD_READY.replace(" }}", " && needs.changes.outputs.mimo_audio == 'true' }}")
        self.assertEqual(field(fixture, "if"), audio_ready)
        restore = next(s for s in steps if field(s, "id") == "mimo-audio-cache")
        self.assertEqual(field(restore, "if"), audio_ready)
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
        self.assertIn("    if: ${{ needs.changes.outputs.cluster == 'true' }}\n", job)
        self.assertIn("    runs-on: ${{ fromJSON(needs.route.outputs.routes)['test-cluster-checks'] }}\n", job)
        self.assertIn("        test-cluster-checks macos_arm64 blacksmith-12vcpu-macos-27 "
                      "${{ needs.changes.outputs.cluster == 'true' && 1 || 0 }}\n", self.jobs["route"])
        for forbidden in ("continue-on-error:", "secrets.", "DARKBLOOM_EXCLUSIVE_NATIVE_GPU_TEST:"):
            self.assertNotIn(forbidden, job)
        steps = step_blocks(job)
        checkout = next(step for step in steps if uses(step) == CHECKOUT)
        self.assertEqual(uses(checkout), CHECKOUT)
        self.assertEqual(field(checkout, "submodules", indent=10), "recursive")
        toolchain = next(step for step in steps if field(step, "id") == "toolchain")
        self.assertEqual(run_command(toolchain), "./scripts/prepare-provider-release-toolchain.sh")
        runners = {
            "Run worker capability checks": "bash libs/darkbloom-cluster-worker/Tests/CapabilityChecks/run.sh",
            "Run prefill schedule checks": "bash libs/darkbloom-cluster/Tests/PrefillScheduleChecks/run.sh",
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
        # The prefill schedule runner builds its bootstrap product in the same
        # retained build, before that build is recorded and saved.
        for name in ("Run worker capability checks", "Run prefill schedule checks"):
            native = named[name]
            self.assertEqual(field(native, "DARKBLOOM_CLUSTER_METADATA_BUILD_JOBS", indent=10), "'12'")
            # Its release build is restored with timestamps only for unchanged
            # sources, keyed by toolchain, manifests, submodule pins and paths.
            self.assertEqual(field(native, "DARKBLOOM_CLUSTER_METADATA_BUILD_ROOT", indent=10),
                             "${{ runner.temp }}/cluster-native-metadata")
        order = [field(step, "name", indent=6) for step in steps]
        self.assertLess(order.index("Run prefill schedule checks"),
                        order.index("Record source timestamps for the cluster build"))
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
        pins = "git submodule status --recursive | awk '{print $1, $2}'"
        for component in ("swift --version", "xcodebuild -version", pins,
                          "$GITHUB_WORKSPACE $RUNNER_TEMP $MANIFESTS", "native-metadata.sh"):
            self.assertIn(component, key)
        # `git describe` text depends on the refs a restored .git holds; the
        # key keeps only each submodule's state, pin and path.
        status = " 0123abc libs/mlx (heads/main)\n+4567def libs/mlx-swift (v0.30.0-2-g4567def)\n"
        pinned = subprocess.run(["awk", "{print $1, $2}"], input=status, capture_output=True, text=True, check=True)
        self.assertEqual(pinned.stdout, "0123abc libs/mlx\n+4567def libs/mlx-swift\n")
        for step in (steps[record], steps[upload]):
            self.assertIn("steps.capability-checks.outcome == 'success'", field(step, "if"))
            # Only pushes to a saving branch save; a pull request never does.
            self.assertIn(SAVE_CACHES + " && ", field(step, "if"))
            self.assertIn("steps.cluster-build-cache.outputs.cache-hit != 'true'", field(step, "if"))
        support = (ROOT / "libs/darkbloom-cluster/Tests/Support/native-metadata.sh").read_text()
        self.assertIn('task_jobs="${DARKBLOOM_CLUSTER_METADATA_BUILD_JOBS:-4}"', support)
        self.assertIn('--jobs "$task_jobs"', support)

    def test_parity_has_no_backend_caches_or_credentials(self):
        # Prompt Parity now runs in the provider shards; besides .git, the only
        # caches that job saves directly are the verified MiMo downloads.
        steps = step_blocks(self.jobs["test-provider"])
        saves = [step for step in steps if "actions/cache/save@" in step]
        self.assertEqual([field(step, "name", indent=6) for step in saves],
                         ["Save .git for later runs", "Save verified MiMo metadata downloads",
                          "Cache verified MiMo audio codec"])
        self.assertNotIn("test-provider-parity", workflow_text())
        for forbidden in ("coordinator/", "cargo ", "rust-key", "secrets.", "darkbloom-platform"):
            self.assertNotIn(forbidden, self.jobs["test-provider"])

    def test_obsolete_self_consuming_cache_warmer_is_absent(self):
        # cache-swift saved a release build that only its own next run restored.
        self.assertNotIn("cache-swift", self.jobs)
        self.assertNotIn("spm-v4-blacksmith-macos27-native-", workflow_text())

    def test_offline_workflow_test_runs_in_release_integrity(self):
        self.assertIn("python3 provider-swift/Tests/test_protocol_fixture_resources.py", self.jobs["release-integrity"])
        self.assertIn("python3 scripts/test-provider-ci-cache.py", self.jobs["release-integrity"])
        self.assertIn("python3 scripts/test-provider-ci-workflow.py", self.jobs["release-integrity"])
        self.assertIn("python3 scripts/test-provider-test-shards.py", self.jobs["release-integrity"])
        self.assertIn("python3 scripts/test-native-gpu-ci.py", self.jobs["release-integrity"])

    def test_only_pushes_to_master_and_dev_save_caches(self):
        # A pull request's entry is scoped to its merge ref, where nothing else
        # restores it, and evicts its base branch's entries from the quota.
        tests = WORKFLOW.read_text()
        self.assertIn("\nenv:\n  DARKBLOOM_RELEASE_ENVIRONMENT: prod\n", tests)
        self.assertIn(SAVE_POLICY, tests.split("\njobs:\n", 1)[0])
        # CI (master)'s own jobs run only for master, so only master pushes save theirs.
        self.assertIn("  SAVE_CACHES: ${{ github.event_name == 'push' && github.ref == 'refs/heads/master' }}\n",
                      MASTER_WORKFLOW.read_text().split("\njobs:\n", 1)[0])
        saves = [(job_id, field(step, "name", indent=6), field(step, "if"))
                 for job_id, job in self.jobs.items() for step in step_blocks(job) if "actions/cache/save@" in step]
        self.assertTrue(saves)
        for job_id, name, condition in saves:
            with self.subTest(job=job_id, step=name):
                self.assertIn(SAVE_CACHES + " && ", condition)
        # The composite saves only when its caller passes the same switch.
        action = ACTION.read_text()
        self.assertIn("  save-caches:\n", action.split("\nruns:\n", 1)[0])
        self.assertIn("\n    default: 'false'\nruns:\n", action)
        composite = {field(step, "name", indent=4): field(step, "if", indent=6)
                     for step in step_blocks(action, indent=4) if "actions/cache/save@" in step}
        self.assertEqual(set(composite), {"Save lane-specific Swift test build", "Save SwiftPM repositories",
                                          "Save validated source-matched Metal cache"})
        for name, condition in composite.items():
            with self.subTest(step=name):
                self.assertIn(SAVE_INPUT + " && ", condition)
        calls = [step for job in self.jobs.values() for step in step_blocks(job) if field(step, "uses") == BUILD_ACTION]
        self.assertEqual(len(calls), 5)
        for call in calls:
            self.assertEqual(field(call, "save-caches", indent=10), "${{ env.SAVE_CACHES }}")

    def test_every_checkout_reuses_master_git_and_falls_back_to_a_cold_checkout(self):
        checkouts = {job_id: job for job_id, job in self.jobs.items() if "actions/checkout@" in job}
        self.assertEqual(set(checkouts), {"release-integrity", "docs", *LANES, "test-provider-summary",
                                          "test-cluster-checks", "test-cluster", "test-cluster-gpu",
                                          "test-cluster-focused"})
        for job_id, job in checkouts.items():
            with self.subTest(job=job_id):
                steps = step_blocks(job)
                self.assertEqual([field(step, "name", indent=6) for step in steps[:5]], list(GIT_CACHE_STEPS))
                day, restore, validate, checkout, save = steps[:5]
                self.assertEqual(run_command(day).splitlines()[:3], ['day=$(date -u +%F)', 'echo "day=$day" >> "$GITHUB_OUTPUT"',
                                                                 'echo "month=${day%-*}" >> "$GITHUB_OUTPUT"'])
                self.assertIn("command -v zstd >/dev/null && echo zstd || echo gzip", day)
                # Full history never seeds, or is restored by, a shallow job.
                family = ("git-full-v1" if job_id == "docs" else "git-v1") + "-${{ runner.os }}-"
                # One entry per day and branch; restore the newest earlier day.
                monthly = family + "${{ steps.git-day.outputs.month }}-"
                self.assertEqual(field(restore, "uses"), CACHE_RESTORE)
                self.assertEqual(field(restore, "path", indent=10), ".git")
                self.assertEqual(field(restore, "key", indent=10), family + "${{ steps.git-day.outputs.day }}")
                self.assertIn(f"restore-keys: |\n            {monthly}\n            {family}\n", restore)
                # The validation cannot fail and nothing may continue on error:
                # one ordinary checkout follows, and its failure fails the job.
                self.assertEqual(run_command(validate), VALIDATE_GIT)
                for step in (validate, checkout):
                    self.assertIsNone(field(step, "if"))
                self.assertFalse(any("continue-on-error" in step for step in steps[:5]))
                self.assertEqual(uses(checkout), CHECKOUT)
                self.assertEqual(sum(uses(step) == CHECKOUT for step in steps), 1)
                # Each job keeps its checkout options; a persisted token would
                # be saved with .git/config.
                sparse = ["sparse-checkout: ${{ env.CHECKOUT_SPARSE }}", "sparse-checkout-cone-mode: false"]
                options = {"release-integrity": ["persist-credentials: false", *sparse],
                           "docs": ["fetch-depth: 0", "filter: blob:none", "persist-credentials: false"]
                           }.get(job_id, ["submodules: recursive", "persist-credentials: false", *sparse])
                self.assertEqual(checkout_options(checkout), options)
                self.assertEqual(field(save, "if"), SAVE_CACHES + " && steps.git-cache.outputs.cache-hit != 'true'")
                self.assertEqual(field(save, "uses"), CACHE_SAVE)
                self.assertEqual(field(save, "path", indent=10), ".git")
                self.assertEqual(field(save, "key", indent=10), "${{ steps.git-cache.outputs.cache-primary-key }}")

    def test_git_validation_keeps_healthy_and_partial_clones_and_discards_damage(self):
        with tempfile.TemporaryDirectory() as work:
            def git(cwd, *args):
                return subprocess.run(["git", "-C", str(cwd), "-c", "user.name=t", "-c", "user.email=t@t",
                                       "-c", "commit.gpgsign=false", "-c", "protocol.file.allow=always", *args],
                                      check=True, capture_output=True, text=True).stdout.strip()
            origin = Path(work, "origin")
            origin.mkdir()
            git(origin, "init", "-q")
            for name in ("a", "b"):
                (origin / name).write_text(name * 1000)
                git(origin, "add", name)
                git(origin, "commit", "-q", "-m", name)
            git(origin, "config", "uploadpack.allowFilter", "true")
            cases = {"healthy": True, "blobless": True, "damaged": False}
            for case in cases:
                options = ["--filter=blob:none", "--no-checkout"] if case == "blobless" else []
                git(work, "clone", "-q", *options, f"file://{origin}", case)
            loose = Path(work, "damaged", ".git", "objects")
            tree = git(Path(work, "damaged"), "rev-parse", "HEAD^{tree}")
            git(Path(work, "damaged"), "repack", "-q", "-a", "-d")
            for pack in (loose / "pack").glob("*.pack"):
                pack.unlink()
            Path(work, "empty").mkdir()
            for case, kept in {**cases, "empty": False}.items():
                with self.subTest(case=case):
                    result = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", VALIDATE_GIT],
                                            cwd=Path(work, case), capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(Path(work, case, ".git").is_dir(), kept, result.stdout)
                    self.assertEqual("::warning" in result.stdout, case == "damaged")
            self.assertTrue(tree)

    def test_sparse_checkouts_skip_only_evidence_tarballs_and_landing_media(self):
        for path in (WORKFLOW, MASTER_WORKFLOW):
            with self.subTest(workflow=path.name):
                env = path.read_text().split("\njobs:\n", 1)[0]
                self.assertIn("  CHECKOUT_SPARSE: |\n" + "".join(f"    {pattern}\n" for pattern in SPARSE_PATTERNS),
                              env)
        self.assertEqual(self.workflow.count("sparse-checkout: ${{ env.CHECKOUT_SPARSE }}"), 8)
        docs_impact = (ROOT / ".github/workflows/docs-impact.yml").read_text()
        self.assertIn("          filter: blob:none\n          sparse-checkout: |\n"
                      + "".join(f"            {pattern}\n" for pattern in SPARSE_PATTERNS)
                      + "          sparse-checkout-cone-mode: false\n", docs_impact)
        # Real git decides what the patterns keep: every file a job may read,
        # including the report a provider test hashes and the evidence harness
        # manifest the provider CI cache hashes, but no evidence tarball or media.
        kept = ["Makefile", "docs/reports/report.md", "docs/reports/archive.tar.gz",
                "docs/reports/evidence/run/cpu-harness/Package.swift", "docs/reports/evidence/notes.json",
                "provider-swift/Tests/Fixtures/clip.mp4", "fixtures/data.gz", "landing/src/page.tsx",
                "landing/README.md", "landing/public/favicon.svg",
                "docs/reports/2026-10-31-public-cluster-models.md"]
        skipped = ["docs/reports/evidence/run/packets.jsonl.gz", "docs/reports/evidence/payloads.tar.gz",
                   "landing/public/media/demo.mp4", "landing/public/media/poster.png"]
        with tempfile.TemporaryDirectory() as work:
            def git(*args):
                subprocess.run(["git", "-C", work, "-c", "user.name=t", "-c", "user.email=t@t",
                                "-c", "commit.gpgsign=false", *args], check=True, capture_output=True)
            git("init", "-q")
            for path in kept + skipped:
                (Path(work) / path).parent.mkdir(parents=True, exist_ok=True)
                (Path(work) / path).write_text(path)
            git("add", "-A")
            git("commit", "-q", "-m", "tree")
            git("sparse-checkout", "set", "--no-cone", *SPARSE_PATTERNS)
            self.assertEqual([path for path in kept if not (Path(work) / path).is_file()], [])
            self.assertEqual([path for path in skipped if (Path(work) / path).exists()], [])
        self.assertTrue((ROOT / "docs/reports/2026-10-31-public-cluster-models.md").is_file())
        # scripts/provider-ci-cache.py hashes every tracked Package.swift,
        # Package.resolved and .gitmodules; the patterns must keep each one.
        tracked = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-z"], check=True,
                                 capture_output=True, text=True).stdout.split("\0")
        manifests = [path for path in tracked if Path(path).name in {"Package.swift", "Package.resolved", ".gitmodules"}]
        self.assertIn("docs/reports/evidence/ssd-read-coordination-runtime-2026-09-06/cpu-harness/Package.swift", manifests)
        self.assertEqual([path for path in manifests
                          if path.endswith(".gz") or path.startswith("landing/public/media/")], [])

    def test_composite_action_cannot_bypass_build_and_metallib_on_cache_hits(self):
        action = ACTION.read_text()
        self.assertIn("using: composite", action)
        self.assertNotIn("continue-on-error:", action)
        self.assertIn("provider-ci-cache.py", action)
        steps = step_blocks(action, indent=4)
        by_id = {field(step, "id", indent=6): step for step in steps if field(step, "id", indent=6)}
        provider = by_id["provider-build"]
        sdk = by_id["sdk-build"]
        cluster = by_id["cluster-build"]
        metallib = by_id["metallib"]
        self.assertEqual(field(provider, "if", indent=6), "inputs.lane == 'provider'")
        self.assertEqual(field(provider, "working-directory", indent=6), "provider-swift")
        self.assertIn("swift build --build-tests", provider)
        self.assertIn("swift build --product darkbloom-fan-helper", provider)
        self.assertEqual(field(sdk, "if", indent=6), "inputs.lane == 'sdk'")
        self.assertEqual(field(sdk, "working-directory", indent=6), "libs/mlx-swift-lm")
        self.assertIn("swift package edit --path ../mlx-swift mlx-swift", sdk)
        self.assertIn("swift build --build-tests", sdk)
        self.assertEqual(field(cluster, "if", indent=6), "inputs.lane == 'cluster'")
        self.assertEqual(field(cluster, "working-directory", indent=6), "libs/darkbloom-cluster")
        self.assertIn("swift build --build-tests", cluster)
        self.assertIsNone(field(metallib, "if", indent=6))
        self.assertIn('./scripts/stage-test-metallib.sh "$bin"', metallib)
        for step in (provider, sdk, cluster, metallib):
            self.assertNotIn("--filter", step)
            self.assertNotIn("--skip", step)
            self.assertNotIn("cache-hit", step)

    def test_composite_cache_keys_retain_swift_and_metal_without_backend_work(self):
        action = ACTION.read_text()
        steps = step_blocks(action, indent=4)
        by_id = {field(step, "id", indent=6): step for step in steps if field(step, "id", indent=6)}
        swift_cache = by_id["swift-cache"]
        self.assertIn("key: ${{ steps.build-key.outputs.key }}", swift_cache)
        # This recipe's entries first, then any recipe's with the same toolchain,
        # dependencies and checkout path.
        self.assertIn("restore-keys: |\n          ${{ steps.keys.outputs.swift-prefix }}\n"
                      "          ${{ steps.keys.outputs.swift-loose-prefix }}\n", swift_cache)
        save = next(step for step in steps if field(step, "name", indent=4) == "Save lane-specific Swift test build")
        self.assertIn("key: ${{ steps.build-key.outputs.key }}", save)
        # Every build step builds once more from nothing only through the retry
        # helper, which reads the matched key and this recipe's prefix.
        for step_id in ("provider-build", "sdk-build", "cluster-build"):
            with self.subTest(step=step_id):
                step = by_id[step_id]
                self.assertIn("provider-ci-cold-retry.sh && ", step)
                self.assertEqual(field(step, "PROVIDER_CI_MATCHED_KEY", indent=8),
                                 "${{ steps.swift-cache.outputs.cache-matched-key }}")
                self.assertEqual(field(step, "PROVIDER_CI_STRICT_PREFIX", indent=8),
                                 "${{ steps.keys.outputs.swift-prefix }}")
        metal_cache = by_id["metallib-cache"]
        self.assertIn("key: ${{ steps.keys.outputs.metallib-key }}", metal_cache)
        self.assertNotIn("restore-keys:", metal_cache)
        rust_steps = [step for step in steps if "install-release-rust.sh" in step
                      or "cargo +1.88.0 clean" in step or field(step, "id", indent=6) == "rust-cache"]
        self.assertEqual(rust_steps, [])
        self.assertNotIn("rust-key:", action)
        self.assertNotIn("rust-cache-hit:", action)
        self.assertEqual(sum("actions/cache/save@" in step for step in steps), 3)

    def test_darkbloom_hosts_save_one_build_per_lane_and_day(self):
        steps = step_blocks(ACTION.read_text(), indent=4)
        step = next(step for step in steps if field(step, "id", indent=6) == "build-key")
        script = textwrap.dedent(step.split("run: |\n", 1)[1])
        day = time.strftime("%Y-%m-%d", time.gmtime())
        for runner, expected in (("darkbloom-5ab1e68d", f"prefix-day-{day}"), ("blacksmith-12vcpu-macos-27-x", "prefix-commit"),
                                 ("", "prefix-commit")):
            with self.subTest(runner=runner), tempfile.TemporaryDirectory() as work:
                output = Path(work) / "output"
                result = subprocess.run(["bash", "-eo", "pipefail", "-c", script], text=True, capture_output=True,
                                        env={"PATH": os.environ["PATH"], "RUNNER_NAME": runner,
                                             "PREFIX": "prefix-", "COMMIT_KEY": "prefix-commit",
                                             "GITHUB_OUTPUT": str(output)}, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(output.read_text(), f"key={expected}\n")

    def test_cold_retry_deletes_only_a_loose_tier_build(self):
        helper = ROOT / "scripts/provider-ci-cold-retry.sh"
        builds = ("provider-swift/.build", "libs/mlx-swift-lm/.build", "libs/darkbloom-cluster/.build")
        for matched, retries in (("", False), ("strict-abc-commit", False), ("strict-abc-day-2026-11-04", False),
                                 ("strict-other-commit", True)):
            with self.subTest(matched=matched), tempfile.TemporaryDirectory() as work:
                for build in builds:
                    Path(work, build).mkdir(parents=True)
                result = subprocess.run(["bash", str(helper)], text=True, capture_output=True, timeout=30,
                                        env={"PATH": os.environ["PATH"], "GITHUB_WORKSPACE": work,
                                             "PROVIDER_CI_MATCHED_KEY": matched,
                                             "PROVIDER_CI_STRICT_PREFIX": "strict-abc-"})
                self.assertEqual(result.returncode, 0 if retries else 1, result.stdout + result.stderr)
                self.assertEqual([Path(work, build).exists() for build in builds], [not retries] * 3)
                self.assertEqual("::warning title=Build cache::" in result.stdout, retries)

    def test_composite_restores_swiftpm_repositories_per_lane_and_runner_layout(self):
        steps = step_blocks(ACTION.read_text(), indent=4)
        by_id = {field(step, "id", indent=6): step for step in steps if field(step, "id", indent=6)}
        names = [field(step, "name", indent=4) for step in steps]
        restore = by_id["spm-repos"]
        save = next(step for step in steps if field(step, "name", indent=4) == "Save SwiftPM repositories")
        # actions/cache archives this home path relative to the workspace, so
        # the key binds the runner layout as well as the lane and the pins.
        self.assertIn('echo "home-layout=$(printf \'%s\\n\' "$HOME" "$GITHUB_WORKSPACE" | shasum -a 256',
                      by_id["keys"])
        self.assertIn("command -v zstd >/dev/null && echo zstd || echo gzip", by_id["keys"])
        prefix = "spm-repos-v1-${{ runner.os }}-${{ steps.keys.outputs.home-layout }}-${{ inputs.lane }}-"
        for step in (restore, save):
            self.assertEqual(field(step, "path", indent=8), "~/Library/Caches/org.swift.swiftpm/repositories")
        self.assertEqual(field(restore, "uses", indent=6), CACHE_RESTORE)
        self.assertEqual(field(restore, "key", indent=8),
                         prefix + "${{ hashFiles('**/Package.resolved', '!**/.build/**') }}")
        self.assertEqual(field(restore, "restore-keys", indent=8), prefix)
        self.assertLess(steps.index(restore), steps.index(by_id["provider-build"]))
        self.assertLess(steps.index(restore), steps.index(by_id["sdk-build"]))
        self.assertLess(steps.index(restore), steps.index(by_id["cluster-build"]))
        self.assertEqual(field(save, "uses", indent=6), CACHE_SAVE)
        self.assertEqual(field(save, "key", indent=8), "${{ steps.spm-repos.outputs.cache-primary-key }}")
        self.assertEqual(field(save, "if", indent=6),
                         "${{ !cancelled() && " + SAVE_INPUT + " && steps.timestamps.outcome == 'success' "
                         "&& steps.spm-repos.outputs.cache-hit != 'true' }}")
        self.assertGreater(names.index("Save SwiftPM repositories"), names.index("Record timestamps for successfully built sources"))


if __name__ == "__main__":
    unittest.main()
