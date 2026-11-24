#!/usr/bin/env python3
"""Offline CI lane/gate checks; actionlint validates the complete YAML syntax."""

from collections import Counter
import importlib.util
import itertools
import json
import os
from pathlib import Path
import re
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
# The plan the callers share: the classifier, the tree lookup and the route.
PLAN_WORKFLOW = ROOT / ".github/workflows/provider-plan.yml"
DEV_WORKFLOW = ROOT / ".github/workflows/ci-dev.yml"


def workflow_text():
    """The test workflow, then CI (master): every job CI runs, each once."""
    return WORKFLOW.read_text() + "\n" + MASTER_WORKFLOW.read_text()

ACTION = ROOT / ".github/actions/provider-ci-build/action.yml"
BUILD_ACTION = "./.github/actions/provider-ci-build"
# Each lane builds once; its test jobs download its products (scripts/ci-test-products.py).
PRODUCTS = ROOT / ".github/actions/provider-ci-products/action.yml"
PRODUCTS_ACTION = "./.github/actions/provider-ci-products"
BUILD_JOBS = {"build-provider": "provider", "build-cluster": "cluster"}
# The jobs that run each lane's products, and the build job each needs.
PRODUCT_JOBS = {"test-provider": "build-provider", "test-provider-gates": "build-provider",
                "test-cluster": "build-cluster", "test-cluster-gpu": "build-cluster"}
FIXED_PATH_STEP = "Work at the fixed build path"
FIXED_PATH = "\n".join(('cd /', 'rm -rf /private/tmp/dinf /private/tmp/dinf-ci "$GITHUB_WORKSPACE"',
                        'mkdir -p /private/tmp/dinf /private/tmp/dinf-ci', 'ln -s /private/tmp/dinf "$GITHUB_WORKSPACE"'))
# Where those jobs keep every cache outside the workspace (FIXED_PATH's comment).
CI_CACHE_ROOT = "/private/tmp/dinf-ci"
SAMPLER_STEPS = ("Start the resource sampler", "Report the resource samples", "Upload the resource samples")
# Every macOS job: the build jobs, the test jobs and the release build checks.
MAC_JOBS = (*BUILD_JOBS, *PRODUCT_JOBS, "cluster-release-checks", "test-cluster-focused")
BLACKSMITH_MAC = "blacksmith-12vcpu-macos-27"
# The placement and size at the end of a route lane line;
# scripts/test-darkbloom-route.py pins each lane's size.
LANE_PLACEMENT_AND_SIZE = r"balanced [1-9][0-9]*x[1-9][0-9]*"
PROVIDER_TEST_COMMAND = ('python3 ../scripts/run-provider-test-watchdog.py \\\n'
                         '  --output-dir "$RUNNER_TEMP/provider-test-diagnostics" \\\n'
                         '  --diagnostic-after-seconds 900 --timeout-seconds 1800 \\\n'
                         '  -- ../scripts/run-provider-tests.sh')
READY = "${{ !cancelled() && steps.test-products.outcome == 'success' }}"
MIMO_READY = "${{ !cancelled() && steps.test-products.outcome == 'success' && steps.mimo-fixtures.outcome == 'success' }}"
# The provider checks that run once beside the suite: Provider Gates, a job of
# their own that starts beside the build as the shards do.
GATES = "test-provider-gates"
PROVIDER_MIMO_READY = "${{ !cancelled() && steps.test-products.outcome == 'success' && steps.mimo-prompt-fixtures.outcome == 'success' && steps.mimo-fixtures.outcome == 'success' }}"
MIMO_METADATA_CACHE = '--cache /private/tmp/dinf-ci/mimo-metadata-cache'
MIMO_PREPARE = ('python3 scripts/prepare-mimo-prompt-fixtures.py '
                '--output "$RUNNER_TEMP/mimo-prompt-fixtures" --github-env "$GITHUB_ENV" ' + MIMO_METADATA_CACHE)
MIMO_HTTP_PREPARE = ('python3 scripts/test-prepare-mimo-image-http-fixtures.py\n'
                     + MIMO_PREPARE + '\n'
                     + 'python3 scripts/prepare-mimo-image-http-fixtures.py '
                     '--output "$RUNNER_TEMP/mimo-image-http-fixtures" --github-env "$GITHUB_ENV" ' + MIMO_METADATA_CACHE)
# Every provider test job runs MIMO_HTTP_PREPARE's commands, in their order, as
# one background command started before the products. The scripts write their
# variables to a file in the command's directory, which `start` creates afresh;
# the wait step, where the preparation stood, adds that file to the job's
# environment once the command has succeeded.
MIMO_METADATA_START_STEP = "Start the pinned MiMo metadata downloads"
MIMO_METADATA_WAIT_STEP = "Wait for the pinned MiMo metadata downloads"
MIMO_METADATA_DOWNLOADS = '"$RUNNER_TEMP/mimo-metadata-downloads"'
MIMO_METADATA_ENV = '"$RUNNER_TEMP/mimo-metadata-downloads/github-env"'
MIMO_METADATA_START = ("python3 scripts/ci-background-step.py start " + MIMO_METADATA_DOWNLOADS + " bash -e -c '\n"
                       + textwrap.indent(MIMO_HTTP_PREPARE.replace('--github-env "$GITHUB_ENV"', '--github-env "$1"'), "  ")
                       + "\n' mimo-metadata " + MIMO_METADATA_ENV)
MIMO_METADATA_WAIT = ("python3 scripts/ci-background-step.py wait " + MIMO_METADATA_DOWNLOADS + "\n"
                      "cat " + MIMO_METADATA_ENV + ' >> "$GITHUB_ENV"')
MIMO_PROVIDER_PREPARE = ('python3 scripts/prepare-mimo-provider-fixtures.py '
                         '--output "$RUNNER_TEMP/mimo-provider-fixtures" --github-env "$GITHUB_ENV"\n'
                         'python3 scripts/prepare-mimo-provider-fixtures.py '
                         '--output "$RUNNER_TEMP/mimo-prefix-fixtures" --asymmetric')
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
GATES_COVERAGE_STEPS = ("Collect provider coverage profiles", "Merge coverage profiles")
# Every provider test job reports the coverage of its own processes with one script.
COVERAGE_REPORT = ROOT / "scripts/report-provider-coverage.sh"
# Each shard's own audit and coverage report (test_only_the_provider_lane_collects_and_reports_coverage).
SHARD_CHECK_STEPS = ("Check this shard's selections against the suite list", "Report provider coverage")
SHARD_UPLOAD = "Upload shard counts, timings and coverage"
LANES = {
    "test-provider": "provider",
    GATES: "provider",
}
PROVIDER_SHARDS = [1, 2, 3, 4, 5]
# Each shard runs this many selections at the same time (scripts/run-provider-tests.sh),
# so the planner splits the suite into len(PROVIDER_SHARDS) * PROVIDER_PROCESSES selections.
PROVIDER_PROCESSES = 3
# Every check of Release Integrity, which runs them at the same time
# (scripts/run-concurrent-checks.py).
RELEASE_INTEGRITY_CHECKS = (
    "python3 scripts/test-provider-build-default.py",
    'python3 scripts/provider-build-default.py --branch "$TARGET_BRANCH"',
    "python3 scripts/test-changelog.py", "make changelog-check", "./scripts/check-release-version.sh",
    "python3 scripts/test-provider-release-resolution.py", "python3 scripts/test-provider-release-resume.py",
    "python3 scripts/test-provider-release-toolchain.py", "python3 scripts/test-provider-release-cache.py",
    "python3 scripts/test-prepare-metal-toolchain.py", "python3 scripts/test-provider-release-pipeline.py",
    "python3 scripts/test-provider-release-publication.py", "python3 scripts/test-provider-release-notes.py",
    "python3 scripts/test-provider-cluster-runtime-models.py", "python3 scripts/test-release-dev-branch.py",
    "python3 scripts/test-signing-keychain.py", "python3 scripts/test-desktop-release.py",
    "python3 scripts/test-sign-desktop-app.py", "python3 scripts/test-provider-release-artifact.py",
    "python3 scripts/test-provider-signing-validation.py", "python3 scripts/test-provider-identity.py",
    "python3 scripts/test-signing-certificate-pins.py", "python3 scripts/test-provider-test-watchdog.py",
    "python3 scripts/test-stage-test-metallib.py", "python3 scripts/test-provider-ci-cache.py",
    "python3 scripts/test-provider-ci-workflow.py", "python3 scripts/test-provider-test-shards.py",
    "python3 scripts/test-cluster-test-plan.py", "python3 scripts/test-ci-component-paths.py",
    "python3 scripts/test-darkbloom-route.py", "python3 scripts/test-ci-tested-tree.py",
    "python3 scripts/test-prepare-prompt-fixtures.py", "python3 provider-swift/Tests/test_protocol_fixture_resources.py",
    "python3 scripts/test-app-attest-entitlements.py", "./scripts/test-setup-macos-homebrew.sh",
    "python3 scripts/test-run-concurrent-checks.py",
    "python3 scripts/test-check-date-comparisons.py", "python3 scripts/test-check-provider-weak-imports.py",
    "python3 scripts/check-date-comparisons.py",
    "python3 .github/scripts/test-threat-model-review.py", "python3 .github/scripts/test-threat-full-scan.py",
    "python3 .github/scripts/test-threat-ensemble.py", "python3 .github/scripts/test-threat-budget.py",
    "python3 .github/scripts/test-threat-bedrock.py", "python3 .github/scripts/test-threat-diagnostics.py",
    "python3 .github/scripts/test-threat-integration-scope.py",
    "python3 scripts/test-native-gpu-ci.py", "python3 scripts/test_model_registry_workflow.py",
    "python3 scripts/test-prepare-mimo-provider-fixtures.py",
    "python3 -m unittest discover -s scripts/serving_performance -t scripts -p 'test_*.py'",
    "python3 -m unittest discover -s scripts/benchmarks -p test_radix_forward_shapes.py",
    "python3 reports/runtime-kv-path-2026-10-09/qualification/test_curate_runs.py",
    "python3 reports/runtime-kv-path-2026-10-09/qualification/test_run_suite.py",
)
# Prompt Parity runs in the provider shard that holds selection
# PARITY_SHARD (scripts/provider-test-shards.py).
PARITY_STEPS = {
    "Verify public prompt golden vectors": ("./scripts/verify-prompt-parity.sh", "ProductionPromptParityTests", "prompt"),
    "Verify pinned Nemotron prompts and numeric cache plans":
        ("./scripts/verify-nemotron-prompt-parity.sh", "NemotronTemplateParityLiveTests", "nemotron"),
}
# Shard 1 downloads Prompt Parity's pinned artifacts in the background while the
# build runs, one download per parity step (its manifests), and each parity step
# waits for its own: parity step -> (wait step, its id, its manifest directory).
PARITY_DOWNLOAD_START = "Start the pinned prompt fixture downloads"
PARITY_DOWNLOADS = {
    "Verify public prompt golden vectors":
        ("Wait for the pinned v1 prompt fixture downloads", "prompt-fixture-downloads-v1", "v1"),
    "Verify pinned Nemotron prompts and numeric cache plans":
        ("Wait for the pinned Nemotron prompt fixture downloads", "prompt-fixture-downloads-nemotron", "nemotron"),
}



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
# Pushes to master and dev, and dispatches on dev (the hourly full run),
# save caches; pull requests never do.
SAVE_POLICY = ("  SAVE_CACHES: ${{ (github.event_name == 'push' && (github.ref == 'refs/heads/master' "
               "|| github.ref == 'refs/heads/dev')) || (github.event_name == 'workflow_dispatch' "
               "&& github.ref == 'refs/heads/dev') }}\n")
SAVE_CACHES = "env.SAVE_CACHES == 'true'"
SAVE_INPUT = "inputs.save-caches == 'true'"
VALIDATE_GIT = r"""[ -e .git ] || [ -L .git ] || exit 0
# Checked before git reads it: a restored .git must be a directory
# that runs nothing. No symbolic link, no hook but git's samples (here
# or in a submodule) and no config that sets a hook directory or a
# file system monitor or includes another file; git config --file
# only parses. Names ignore case, as macOS does.
if [ -L .git ] || [ ! -d .git ]; then
  reason="it is not a directory"
elif [ -n "$(find .git -type l 2>/dev/null || true)" ]; then
  reason="it holds a symbolic link"
elif [ -n "$(find .git -ipath '*/hooks/*' ! -type d ! -iname '*.sample' 2>/dev/null || true)" ]; then
  reason="it holds a hook"
elif [ -n "$(find .git \( -iname config -o -iname config.worktree \) ! -type d \
    -exec git config --file {} --name-only --list \; 2>/dev/null |
    grep -i -E '^(core\.(fsmonitor|hookspath)|include\.|includeif\.)' || true)" ]; then
  reason="its config sets core.fsmonitor, core.hooksPath or an include"
elif ! { git rev-parse --verify -q HEAD >/dev/null &&
    git fsck --connectivity-only --no-progress >/dev/null 2>&1; }; then
  reason="git fsck rejected it"
else
  exit 0
fi
echo "::warning title=.git cache::Discarded the restored .git ($reason); checking out without it."
rm -rf .git"""
# A Darkbloom Sandbox the plane gave no Darkbloom cache (no DARKBLOOM_CACHE_URL
# from the guest) would reach GitHub's own Actions cache: there this first step
# sets CI_ACTIONS_CACHE=off, and every cache step's condition starts with
# CACHE_GATE (test_every_cache_step_is_skipped_on_darkbloom_without_its_cache).
CACHE_GATE_STEP = "Choose this job's Actions cache"
CACHE_GATE_RUN = """if [[ ${RUNNER_NAME:-} != darkbloom-* ]]; then
  echo "Actions cache: this runner's own"
elif [[ -n ${DARKBLOOM_CACHE_URL:-} ]]; then
  echo "Actions cache: the Darkbloom cache at $DARKBLOOM_CACHE_URL"
else
  echo "CI_ACTIONS_CACHE=off" >> "$GITHUB_ENV"
  echo "::notice title=Actions cache::The plane gave this Darkbloom Sandbox no cache, so every cache step is skipped."
fi"""
CACHE_GATE = "env.CI_ACTIONS_CACHE != 'off'"


def gated(condition):
    """`condition` with CACHE_GATE in front, inside its ${{ }} if it has one."""
    if condition.startswith("${{ "):
        return "${{ " + CACHE_GATE + " && " + condition[4:]
    return CACHE_GATE + " && " + condition
SPARSE_PATTERNS = ("/*", "!/docs/reports/evidence/**/*.gz", "!/landing/public/media/")
GIT_CACHE_STEPS = ("Select today's .git cache", "Restore the newest saved .git",
                   "Discard a damaged or unsafe cached .git", None, "Save .git for later runs")
# The macOS jobs check out the submodules in a step of their own, right after
# the checkout and before .git is saved (scripts/ci-checkout-submodules.py).
SUBMODULES_STEP = "Check out the submodules"
SUBMODULES_RUN = "python3 scripts/ci-checkout-submodules.py"


def uses(step):
    """The action a step uses, whether `uses:` opens the step or follows `name:`."""
    return field(step, "uses") or field(step, "uses", indent=6)


def checkout_options(step):
    lines = step.split("        with:\n", 1)[1].splitlines()
    return [line.split(" #", 1)[0].strip() for line in lines if line.startswith("          ")]


def work_steps(job):
    """The steps besides the fixed path, the shared .git cache and checkout steps and the sampler."""
    return [step for step in step_blocks(job)
            if field(step, "name", indent=6) not in (CACHE_GATE_STEP, FIXED_PATH_STEP, *GIT_CACHE_STEPS, SUBMODULES_STEP,
                                                    *SAMPLER_STEPS)]


def continues_on_error(job):
    """The names of the job's steps that continue on error."""
    return [field(step, "name", indent=6) for step in step_blocks(job) if "continue-on-error:" in step]


class ProviderCIWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.workflow = workflow_text()
        self.jobs = {**job_blocks(WORKFLOW.read_text().split("\njobs:\n", 1)[1]),
                     **job_blocks(MASTER_WORKFLOW.read_text().split("\njobs:\n", 1)[1]),
                     **job_blocks(PLAN_WORKFLOW.read_text().split("\njobs:\n", 1)[1])}

    def test_nested_wrapper_preserves_long_filters_and_failure_gates(self):
        selector = "NativeSuite/" + "VeryLongTestName" * 30 + "|OtherSuite/testCase"
        passed, skipped = '<testcase name="a()" />', '<testcase name="b()"><skipped /></testcase>'
        # (console, Swift Testing xUnit cases or None for no report, swift exit, gate exit)
        cases = (
            ("Executed 1 test, with 0 failures", "", 0, 0),
            ("Test run with 1 test passed", passed, 0, 0),
            ("Test run with 0 tests passed", "", 0, 1),
            ("Executed 1 test, with 1 test skipped and 0 failures", "", 0, 1),
            ("Test run with 2 tests passed", passed + skipped, 0, 1),
            ("Test run with 1 test passed", None, 0, 1),
            ("Executed 1 test, with 1 failure", passed, 7, 7),
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
                if "STUB_XUNIT" in os.environ:
                    report = Path(sys.argv[sys.argv.index("--xunit-output") + 1])
                    report.with_name(report.stem + "-swift-testing.xml").write_text(
                        "<testsuites><testsuite>" + os.environ["STUB_XUNIT"] + "</testsuite></testsuites>")
                raise SystemExit(int(os.environ["STUB_EXIT"]))
                """))
            swift.chmod(0o755)
            for output, xunit, swift_exit, expected_exit in cases:
                with self.subTest(output=output, xunit=xunit):
                    environment = dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"],
                                       TMPDIR=str(root), STUB_ARGUMENTS=str(recorded),
                                       STUB_OUTPUT=output, STUB_EXIT=str(swift_exit))
                    environment.pop("STUB_XUNIT", None)
                    if xunit is not None:
                        environment["STUB_XUNIT"] = xunit
                    result = subprocess.run(
                        ["bash", str(ROOT / "scripts/run-nested-suite.sh"), selector, "--no-parallel"],
                        env=environment, text=True, capture_output=True, timeout=10)
                    self.assertEqual(result.returncode, expected_exit, result.stdout + result.stderr)
                    arguments = json.loads(recorded.read_text())
                    self.assertEqual(arguments[:-1],
                                     ["test", "--skip-build", "--filter", selector, "--no-parallel", "--xunit-output"])
                    self.assertTrue(arguments[-1].endswith("/xunit.xml"), arguments[-1])

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
                # dedicated Blacksmith runner; requested only when the job runs,
                # at its size (scripts/test-darkbloom-route.py pins each lane's
                # size).
                self.assertIn("    runs-on: ${{ fromJSON(inputs.routes)[%s] }}\n" % lane_key, job)
                # The plan's components are the classifier's, or none for a
                # tree that already passed (provider-plan.yml).
                for route_lane in route_lanes:
                    self.assertRegex(self.jobs["route"], re.escape(
                        "        %s macos_arm64 blacksmith-12vcpu-macos-27 "
                        "${{ needs.components.outputs.provider == 'true' && 1 || 0 }} " % route_lane) + LANE_PLACEMENT_AND_SIZE + r"\n")
                self.assertIn("    timeout-minutes: 60\n", job)
                # It starts beside its build job and waits for the products
                # (test_each_lane_builds_once_and_its_test_jobs_run_its_products).
                self.assertNotRegex(job, r"(?m)^    needs:")
                self.assertIn("    if: ${{ inputs.provider == 'true' }}\n", job)
                self.assertEqual(continues_on_error(job), [SAMPLER_STEPS[-1]])
                self.assertNotIn("DARKBLOOM_EXCLUSIVE_NATIVE_GPU_TEST:", job)
        self.assertIn("    name: Provider Unit Tests (shard ${{ matrix.shard }})\n", self.jobs["test-provider"])
        self.assertIn("    name: Provider Gates\n", self.jobs[GATES])

    def test_route_requests_exactly_one_lane_per_provider_shard(self):
        # The plane grants a lane whole: one lane for all shards would need a
        # free Mac for every shard at once and otherwise fall back entirely.
        # test_lanes_are_independent_on_dedicated_supported_mac_runners pins
        # the matrix to PROVIDER_SHARDS.
        self.assertEqual(sorted(re.findall(r"(?m)^        (test-provider(?:-[0-9]+)?) ", self.jobs["route"])),
                         [f"test-provider-{shard}" for shard in PROVIDER_SHARDS])

    def test_the_checked_in_weights_load_every_provider_shard_alike(self):
        # Each selection starts loaded with its job's fixed work (Prompt
        # Parity, the isolated processes), so with the
        # checked-in weights the planned shards end together: the last shard's
        # fixed work does not outgrow a selection's share. A suite is never
        # split, so a suite longer than a share would end its job last: the
        # only one, BootSecurityServeLoopTests (`.serialized`, 170 s on 4x24),
        # is the own-process class (OWN_PROCESS_SUITES). No selection plans
        # it; job 1 runs it in a process of its own beside its selections, on
        # test-provider-1's 12x32 lane. Any other suite 10 s longer than the
        # shortest job fails here, and the jobs' planned loads end within 10 s
        # of each other; job 1 also waits for that process before Prompt
        # Parity.
        # The gates run in Provider Gates, beside the shards.
        # Selections 1..N-1 need suites (`selection` refuses an empty one); the
        # last runs the unweighted suites even when the plan gives it none.
        # Weights that no longer match the suites warn in each shard's audit
        # (STALE_SELECTION_SECONDS).
        selections = len(PROVIDER_SHARDS) * PROVIDER_PROCESSES
        weights = shards.load_weights()
        assigned, loads = shards.assignment(selections, weights, PROVIDER_PROCESSES)
        jobs = [max(loads[first:first + PROVIDER_PROCESSES]) for first in range(0, selections, PROVIDER_PROCESSES)]
        self.assertLess(max(jobs) - min(jobs), 10, jobs)
        oversized = {key for key, seconds in weights.items()
                     if key.split(".", 1)[0] not in shards.PARALLEL_MODULES and seconds >= min(jobs) + 10}
        self.assertLessEqual(oversized, set(shards.own_process_suites(PROVIDER_PROCESSES)), jobs)
        self.assertEqual([key for keys in assigned for key in keys if key in shards.OWN_PROCESS_SUITES], [])
        self.assertTrue(all(assigned[:-1]), [len(keys) for keys in assigned])
        self.assertRegex(self.jobs["route"], r"(?m)^        test-provider-1 macos_arm64 .* balanced 12x32$")

    def test_existing_required_check_requires_every_lane_even_after_failures(self):
        job = self.jobs["provider-test-gate"]
        self.assertIn("    name: Provider Tests\n", job)
        self.assertIn("    needs: [test-provider, test-provider-gates, test-cluster, test-cluster-focused, "
                      "cluster-release-checks, ci-plan-checks]\n", job)
        self.assertNotIn("test-provider-sdk", job)
        self.assertIn("    if: ${{ always() }}\n", job)
        self.assertNotIn("continue-on-error:", job)
        step = step_blocks(job)[0]
        command = run_command(step)
        # Prompt Parity is a step of a provider shard: its failure is UNIT_RESULT's.
        # The gates are Provider Gates': GATES_RESULT.
        self.assertNotIn("test-provider-parity", job)
        self.assertEqual(field(step, "GATES_RESULT", indent=10), "${{ needs.test-provider-gates.result }}")
        lanes = ("UNIT_RESULT", "GATES_RESULT", "CLUSTER_RESULT", "CLUSTER_FOCUSED_RESULT", "CLUSTER_RELEASE_RESULT")
        for failed in (None, *lanes):
            for outcome in ("failure", "skipped", "cancelled"):
                results = {lane: outcome if lane == failed else "success" for lane in lanes}
                result = subprocess.run(["bash", "-e", "-c", command],
                                        env={**os.environ, "CHANGES_RESULT": "success", "PROVIDER_CHANGED": "true", "CLUSTER_CHANGED": "true",
                                             **results},
                                        capture_output=True, timeout=5)
                self.assertEqual(result.returncode == 0, failed is None, results)
        # The CI plan checks pass only when their job succeeded.
        plan_checks = {field(step, "name", indent=6): step for step in step_blocks(job)}["Require the CI plan checks"]
        self.assertEqual(field(plan_checks, "PLAN_CHECKS_RESULT", indent=10), "${{ needs.ci-plan-checks.result }}")
        self.assertIsNone(field(plan_checks, "if"))
        for outcome in ("success", "failure", "skipped", "cancelled", ""):
            result = subprocess.run(["bash", "-e", "-c", run_command(plan_checks)],
                                    env={**os.environ, "PLAN_CHECKS_RESULT": outcome}, capture_output=True, timeout=5)
            self.assertEqual(result.returncode == 0, outcome == "success", outcome)

    def test_the_gate_requires_the_ci_plan_checks_of_every_run(self):
        # dev has no Release Integrity: a job beside the test jobs audits the
        # cluster plan and runs the plan self-tests on every run, skipped or
        # not, and the gate requires it. It waits for nothing.
        job = self.jobs["ci-plan-checks"]
        self.assertIn("    name: Check the CI plans\n", job)
        # Its own lane: a Darkbloom Linux sandbox, or the GitHub-hosted
        # ubuntu-24.04 fallback (provider-plan.yml).
        self.assertIn("    runs-on: ${{ fromJSON(inputs.routes)['ci-plan-checks'] }}\n", job)
        self.assertNotRegex(job, r"(?m)^    (needs|if):")
        self.assertNotIn("continue-on-error:", job)
        self.assertNotIn("Check the CI plans", self.jobs["provider-test-gate"])
        steps = {field(step, "name", indent=6): step for step in step_blocks(job)}
        check = steps["Check the CI plans"]
        # Each runs even when an earlier one failed; only a cancel stops them.
        self.assertEqual(field(check, "if"), "${{ !cancelled() }}")
        commands = run_command(check).splitlines()
        for command in ("python3 scripts/cluster-test-plan.py audit", "python3 scripts/test-cluster-test-plan.py",
                        "python3 scripts/test-provider-test-shards.py", "python3 scripts/test-ci-component-paths.py",
                        "python3 scripts/test-ci-tested-tree.py", "python3 scripts/test-ci-test-products.py",
                        "python3 scripts/test-ci-resource-sampler.py"):
            self.assertIn(command, commands)
        # The source check for back-deployed Date >= / <= is dev's only
        # pull-request guard against them; it also runs on every run.
        dates = steps["Refuse back-deployed Date comparisons in provider source"]
        self.assertEqual(field(dates, "if"), "${{ !cancelled() }}")
        self.assertIn("python3 scripts/check-date-comparisons.py", run_command(dates).splitlines())
        # A dev push is signed and published, so dev also checks every copy of
        # the signature requirement against the signing certificate list.
        pins = steps["Check signature requirements against the signing certificate list"]
        self.assertEqual(field(pins, "if"), "${{ !cancelled() }}")
        self.assertEqual(run_command(pins).splitlines(), ["python3 scripts/test-signing-certificate-pins.py"])
        # And the rules of the lane that signs it: the signing job's steps, the
        # keychain scripts and the source gates.
        signing = steps["Check the release lane's signing rules"]
        self.assertEqual(field(signing, "if"), "${{ !cancelled() }}")
        self.assertEqual(run_command(signing).splitlines(),
                         ["python3 scripts/test-provider-release-pipeline.py", "python3 scripts/test-release-dev-branch.py",
                          "python3 scripts/test-provider-signing-validation.py",
                          "python3 scripts/test-provider-release-resume.py", "python3 scripts/test-signing-keychain.py",
                          "python3 scripts/test-desktop-release.py", "python3 scripts/test-sign-desktop-app.py"])
        # The prompt fixture downloaders' and the MiMo audio codec download's
        # self-tests need no Mac; dev runs them here.
        fixtures = steps["Test the prompt fixture downloaders offline"]
        self.assertEqual(field(fixtures, "if"), "${{ !cancelled() }}")
        self.assertEqual(run_command(fixtures).splitlines(), ["python3 scripts/test-prepare-prompt-fixtures.py",
                                                              "python3 scripts/test-prepare-mimo-prompt-fixtures.py",
                                                              "python3 scripts/test-prepare-mimo-image-http-fixtures.py",
                                                              "python3 scripts/test-prepare-mimo-audio-fixtures.py"])
        # So do the GPT-OSS tools' CPU tests (Python 3.11+); the log names the Python that ran them.
        gptoss = steps["Test the GPT-OSS checkpoint and replay tools offline"]
        self.assertEqual(field(gptoss, "if"), "${{ !cancelled() }}")
        self.assertEqual(run_command(gptoss).splitlines(),
                         ["python3 --version", "python3 -m unittest discover -s scripts -p 'test_gptoss_*.py' -v"])
        # The record names its change through the lookup's own code, and only
        # a run that tested something records.
        steps = {field(step, "name", indent=6): step for step in step_blocks(self.jobs["provider-test-gate"])}
        record = steps["Name the record of the change these tests passed"]
        self.assertIn('python3 scripts/ci-tested-tree.py name --tree "$TREE" --base "$BASE" --head "$HEAD"', record)
        self.assertIn('python3 scripts/ci-tested-tree.py tree-name --tree "$TREE" --components "$RAN"', record)
        for name in ("Name the record of the change these tests passed", "Upload the record", "Upload the tree record"):
            self.assertEqual(field(steps[name], "if"),
                             "${{ inputs.skip != 'true' && (inputs.provider == 'true' || inputs.cluster == 'true') }}")

    def test_each_lane_checks_out_recursive_sources_before_its_products(self):
        for job_id, lane in LANES.items():
            with self.subTest(lane=lane):
                steps = step_blocks(self.jobs[job_id])
                checkout = next(step for step in steps if uses(step) == CHECKOUT)
                self.assertEqual(uses(checkout), CHECKOUT)
                self.assertIsNone(field(checkout, "submodules", indent=10))
                self.assertEqual(field(steps[steps.index(checkout) + 1], "name", indent=6), SUBMODULES_STEP)
                self.assertEqual([step for step in steps if field(step, "uses") == BUILD_ACTION], [])
                builds = [step for step in steps if field(step, "uses") == PRODUCTS_ACTION]
                self.assertEqual(len(builds), 1)
                self.assertGreater(steps.index(builds[0]), steps.index(checkout))
                self.assertEqual(field(builds[0], "lane", indent=10), lane)
                self.assertEqual(field(builds[0], "direction", indent=10), "download")
                self.assertEqual(field(builds[0], "id"), "test-products")
                self.assertIsNone(field(builds[0], "if"))
                restores = [step for step in steps
                            if "actions/cache/restore@" in step and field(step, "id") != "git-cache"]
                if lane == "provider":
                    # The verified MiMo metadata downloads, shard 1's prompt
                    # fixture downloads and Provider Gates' audio codec before
                    # the products: they need none, so they are fetched while
                    # the build runs.
                    caches = {"test-provider": [("mimo-metadata-cache", "mimo-metadata-v1-"),
                                                ("prompt-fixture-cache", "prompt-fixtures-v1-")],
                              GATES: [("mimo-metadata-cache", "mimo-metadata-v1-"),
                                      ("mimo-audio-cache", "mimo-audio-source-v2-")]}
                    expected = caches[job_id]
                    self.assertEqual([field(step, "id") for step in restores], [cache for cache, _ in expected])
                    for restore, (_, key) in zip(restores, expected):
                        self.assertIn(key, restore)
                        self.assertLess(steps.index(restore), steps.index(builds[0]))
                else:
                    self.assertEqual(restores, [])
                self.assertNotIn("spm-v3-", self.jobs[job_id])

    def test_only_the_provider_lane_collects_and_reports_coverage(self):
        steps = step_blocks(self.jobs["test-provider"])
        names = [field(step, "name", indent=6) for step in steps]
        build = next(index for index, step in enumerate(steps) if field(step, "uses") == PRODUCTS_ACTION)
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
        self.assertGreater(shard_upload, merge)
        skipped_tests = "${{ !cancelled() && steps.provider-unit-tests.outcome != 'skipped' }}"
        self.assertEqual(field(steps[merge], "if"), skipped_tests)
        self.assertEqual(field(steps[shard_upload], "if"), skipped_tests)
        self.assertIn('profiles=("$PROVIDER_COVERAGE_DIR"/*.profraw)', steps[merge])
        self.assertIn("xcrun llvm-profdata merge", steps[merge])
        self.assertIn("name: provider-unit-shard-${{ matrix.shard }}", steps[shard_upload])
        self.assertIn("if-no-files-found: error", steps[shard_upload])
        # Executed counts, xUnit reports and the merged profile: a selection
        # runs once (scripts/run-provider-tests.sh), so no attempt files exist.
        self.assertEqual(re.findall(r"\$\{\{ runner\.temp \}\}/provider-unit-shard/(\S+)", steps[shard_upload]),
                         ["*.json", "*.xml", "provider.profdata"])
        for step in (steps[merge], steps[shard_upload]):
            self.assertNotIn("continue-on-error:", step)
        # Each shard audits its own selections against `swift test list` of
        # its own build (the last shard also checks that the plans cover the
        # list once) and writes its own coverage report; no Mac job exists only
        # to audit (David, 2026-11-04).
        self.assertNotIn("test-provider-summary", self.jobs)
        swift_tests = names.index("Run Swift tests")
        audit = names.index("Check this shard's selections against the suite list")
        report = names.index("Report provider coverage")
        upload = names.index("Upload provider coverage report")
        self.assertLess(swift_tests, audit)
        self.assertLess(merge, report)
        self.assertLess(audit, report)
        self.assertEqual(upload, report + 1)
        self.assertLess(upload, shard_upload)
        for index in (audit, report):
            self.assertEqual(field(steps[index], "if"), skipped_tests)
            self.assertNotIn("continue-on-error:", steps[index])
        self.assertIn("swift test list --skip-build", steps[audit])
        self.assertIn('provider-test-shards.py audit-job "$RUNNER_TEMP/provider-tests.txt"', steps[audit])
        self.assertEqual(field(steps[audit], "SHARD", indent=10), "${{ matrix.shard }}/${{ strategy.job-total }}")
        self.assertEqual(field(steps[audit], "PROVIDER_TEST_PROCESSES", indent=10), f"'{PROVIDER_PROCESSES}'")
        self.assertEqual(run_command(steps[report]), '../scripts/report-provider-coverage.sh '
                         '"$RUNNER_TEMP/provider-unit-shard/provider.profdata" "$RUNNER_TEMP/provider-coverage"')
        self.assertEqual(field(steps[report], "working-directory"), "provider-swift")
        self.assertIn("name: provider-coverage-${{ matrix.shard }}", steps[upload])
        test_step = next(step for step in steps if run_command(step) == PROVIDER_TEST_COMMAND)
        self.assertEqual(field(test_step, "id"), "provider-unit-tests")
        build_step = next(step for step in step_blocks(ACTION.read_text(), indent=4)
                          if field(step, "id", indent=6) == "provider-build")
        self.assertEqual(textwrap.dedent(build_step.split("run: |\n", 1)[1]).strip(),
                         "build() {\n"
                         "  swift build --build-tests --enable-code-coverage -debug-info-format none &&\n"
                         "    swift build --product darkbloom-fan-helper --enable-code-coverage -debug-info-format none\n"
                         "}\n"
                         "build || { ../scripts/provider-ci-cold-retry.sh && build; }")

    def test_provider_gates_report_the_coverage_of_their_own_processes(self):
        # Provider Gates runs no selection, so it has no audit; it merges the
        # profiles of its gates after the last of them and reports them with
        # the shards' script, as one more provider test job.
        steps = step_blocks(self.jobs[GATES])
        names = [field(step, "name", indent=6) for step in steps]
        download = next(index for index, step in enumerate(steps) if field(step, "uses") == PRODUCTS_ACTION)
        collect, merge = (names.index(name) for name in GATES_COVERAGE_STEPS)
        report = names.index("Report provider coverage")
        upload = names.index("Upload provider coverage report")
        # The MiMo metadata preparation's self-test runs in the background
        # before the products (test_mimo_metadata_is_prepared_while_the_build_runs).
        # It runs only Python, never a provider binary, so it writes no profile.
        tests = [index for index, step in enumerate(steps)
                 if run_command(step) != MIMO_METADATA_START
                 and ("run-nested-suite.sh" in step or "scripts/test-" in (run_command(step) or ""))]
        self.assertEqual(collect, download + 1)
        shard_steps = {field(step, "name", indent=6): step for step in step_blocks(self.jobs["test-provider"])}
        self.assertEqual(run_command(steps[collect]), run_command(shard_steps[COVERAGE_STEPS[0]]))
        self.assertLess(collect, min(tests))
        self.assertGreater(merge, max(tests))
        self.assertEqual((report, upload), (merge + 1, merge + 2))
        for index in (merge, report):
            self.assertEqual(field(steps[index], "if"), READY)
            self.assertNotIn("continue-on-error:", steps[index])
        self.assertIn('profiles=("$PROVIDER_COVERAGE_DIR"/*.profraw)', steps[merge])
        self.assertIn('xcrun llvm-profdata merge -sparse -o "$RUNNER_TEMP/provider-gates/provider.profdata"', steps[merge])
        self.assertEqual(run_command(steps[report]), '../scripts/report-provider-coverage.sh '
                         '"$RUNNER_TEMP/provider-gates/provider.profdata" "$RUNNER_TEMP/provider-coverage"')
        self.assertEqual(field(steps[report], "id"), "provider-coverage")
        self.assertEqual(field(steps[report], "working-directory"), "provider-swift")
        self.assertEqual(field(steps[upload], "if"), "${{ !cancelled() && steps.provider-coverage.outcome == 'success' }}")
        self.assertIn("name: provider-coverage-gates", steps[upload])
        self.assertIn("            ${{ runner.temp }}/provider-coverage/provider.profdata\n", steps[upload])
        self.assertIn("if-no-files-found: error", steps[upload])
        # The script keeps the report's checks: a job without a test bundle
        # fails, and each job reports only its own processes.
        script = COVERAGE_REPORT.read_text()
        self.assertTrue(os.access(COVERAGE_REPORT, os.X_OK))
        self.assertIn("set -euo pipefail\n", script)
        self.assertIn('cp "$profdata" "$out/provider.profdata"', script)
        self.assertIn('echo "::error::No test bundle in $bin"', script)
        self.assertIn('>> "$GITHUB_STEP_SUMMARY"', script)
        self.assertNotIn("matrix.", self.jobs[GATES])
        self.assertNotIn("run-provider-tests.sh", self.jobs[GATES])
        self.assertNotIn("audit-job", self.jobs[GATES])

    def test_provider_entrypoint_and_resource_installer_checks_are_retained(self):
        # Every shard prepares the fixtures its suites read and runs its
        # selections; Provider Gates prepares the same fixtures and runs every
        # check that runs once beside the suite. Each command runs exactly once
        # in the workflow, and none of them in a shard only the last runs.
        gates = (
            # Provider Gates prepares the audio fixture first: it needs no
            # products, so it runs while the build does.
            'python3 scripts/prepare-mimo-audio-fixtures.py --cache /private/tmp/dinf-ci/mimo-audio-source --output "$RUNNER_TEMP/mimo-audio-fixtures" --github-env "$GITHUB_ENV"',
            "python3 scripts/test-qwen4-packaged-resources.py",
            "python3 scripts/test-stage-swiftpm-resource-bundles.py",
            "python3 scripts/test-provider-profiles-unprivileged.py",
            "for enabled in 0 1; do\n"
            '  env DARKBLOOM_GEMMA_SCHEMA_COERCION="$enabled" ../scripts/run-nested-suite.sh GemmaQuotedArgumentConformanceTests --no-parallel\n'
            "done",
            "python3 scripts/test-desktop-api.py provider-swift/.build/debug/darkbloom",
            "for enabled in 0 1; do\n"
            '  env DARKBLOOM_GEMMA_REOPENED_THOUGHTS="$enabled" ../scripts/run-nested-suite.sh GemmaReopenedThoughtRoutingTests --no-parallel\n'
            "done",
            *MIMO_NATIVE_COMMANDS.values(),
            "../scripts/run-nested-suite.sh testNativeAudioRelease --no-parallel",
            "./scripts/test-install-atomic.sh",
        )
        # The MiMo metadata preparation starts before the products and is
        # waited for where it stood (test_mimo_metadata_is_prepared_while_the_build_runs).
        expected = {"test-provider": (MIMO_METADATA_START, MIMO_METADATA_WAIT, MIMO_PROVIDER_PREPARE, PROVIDER_TEST_COMMAND),
                    GATES: (MIMO_METADATA_START, *gates[:4], MIMO_METADATA_WAIT, MIMO_PROVIDER_PREPARE, *gates[4:])}
        for job_id, commands in expected.items():
            with self.subTest(job=job_id):
                steps = work_steps(self.jobs[job_id])
                runs = [run_command(step) for step in steps
                        if field(step, "run") and field(step, "name", indent=6) not in
                        (*COVERAGE_STEPS, *GATES_COVERAGE_STEPS, *PARITY_STEPS, PARITY_DOWNLOAD_START,
                         *(wait for wait, _, _ in PARITY_DOWNLOADS.values()), *SHARD_CHECK_STEPS)]
                self.assertEqual(runs, list(commands))
        everywhere = Counter(run_command(step) for job in self.jobs.values() for step in step_blocks(job))
        for command in (*gates, PROVIDER_TEST_COMMAND):
            self.assertEqual(everywhere[command], 1, command)
        for command in (MIMO_METADATA_START, MIMO_METADATA_WAIT):
            self.assertEqual(everywhere[command], 2, command)
        # No step of a shard is the last shard's alone: the last shard differs
        # only by the isolated processes, which run-provider-tests.sh runs.
        self.assertNotIn("== strategy.job-total", self.jobs["test-provider"])
        steps = work_steps(self.jobs["test-provider"])
        test_step = next(step for step in steps if run_command(step) == PROVIDER_TEST_COMMAND)
        self.assertEqual(field(test_step, "id"), "provider-unit-tests")
        self.assertEqual(field(test_step, "timeout-minutes"), "35")
        self.assertEqual(field(test_step, "PROVIDER_TEST_SHARD", indent=10),
                         "${{ matrix.shard }}/${{ strategy.job-total }}")
        self.assertEqual(field(test_step, "PROVIDER_TEST_PROCESSES", indent=10), f"'{PROVIDER_PROCESSES}'")
        self.assertEqual(field(test_step, "PROVIDER_TEST_REPORT_DIR", indent=10),
                         "${{ runner.temp }}/provider-unit-shard")
        self.assertEqual(field(test_step, "working-directory"), "provider-swift")
        self.assertEqual(field(test_step, "if"), PROVIDER_MIMO_READY)
        self.assertEqual(field(test_step, "MIMO_V26_PROVIDER_LIFETIME_METADATA_TESTS", indent=10), "'1'")
        # Provider Gates keeps each check's own condition, without the shard.
        steps = work_steps(self.jobs[GATES])
        for command in gates[1:4]:
            step = next(step for step in steps if run_command(step) == command)
            self.assertIsNone(field(step, "if"), command)
        for command in gates[4:7]:
            step = next(step for step in steps if run_command(step) == command)
            self.assertEqual(field(step, "if"), READY, command)
        desktop = next(step for step in steps if "scripts/test-desktop-api.py" in (run_command(step) or ""))
        self.assertEqual(field(desktop, "timeout-minutes"), "3")
        for name in ("Test Gemma quoted numeric argument conformance switches",
                     "Test Gemma reopened thought conformance switches"):
            gemma = next(step for step in steps if field(step, "name", indent=6) == name)
            self.assertEqual(field(gemma, "working-directory"), "provider-swift")
            self.assertEqual(field(gemma, "timeout-minutes"), "5")
        installer = next(step for step in steps if run_command(step) == "./scripts/test-install-atomic.sh")
        self.assertEqual(field(installer, "if"), "${{ !cancelled() }}")
        self.assertEqual(field(installer, "timeout-minutes"), "2")
        for job_id in ("test-provider", GATES):
            self.assertNotIn("rustup", self.jobs[job_id])
            self.assertNotIn("actions/setup-go@", self.jobs[job_id])

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
        self.assertIn("          path: |\n            ${{ runner.temp }}/provider-test-diagnostics\n"
                      "            ${{ runner.temp }}/provider-unit-shard/slot-*.out\n", upload)
        self.assertEqual(field(upload, "retention-days", indent=10), "7")
        self.assertEqual(continues_on_error(self.jobs["test-provider"]), [SAMPLER_STEPS[-1]])

    def test_coverage_summary_preserves_weighted_rows_and_failure_checks(self):
        summary_script = COVERAGE_REPORT.read_text().split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
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

    def test_sdk_suites_run_in_the_sdks_own_fork_tests(self):
        # David, 2026-11-04: Provider SDK Tests repeated the SDK's own Fork
        # Tests (226 of its 236 test seconds), so the lane and the SDK build
        # lane are gone. Fork Tests skips the one other step,
        # MiMoV26NativeMediaDeadlineTests; un-skipping it there is the SDK's
        # (work/d-inference-test-dedup-inventory.md, class C).
        self.assertNotIn("test-provider-sdk", self.jobs)
        self.assertNotIn("test-provider-sdk", self.jobs["route"])
        for selector in ("MiMoV26NativeMediaDeadlineTests", "CBv2PagedSafetyTests", "NemotronH35MTPTests",
                         "run-paged-kernel-tests.sh", "swift package edit"):
            self.assertNotIn(selector, self.workflow)
        action = ACTION.read_text()
        self.assertIn("          provider|cluster) ;;\n", action)
        self.assertNotIn("libs/mlx-swift-lm", action)
        # Each provider entry point and parity script still runs exactly once.
        commands = Counter(run_command(step) for job in self.jobs.values() for step in step_blocks(job))
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
        # Each parity step also needs its own pinned downloads, and only those.
        downloads = {name: "steps.%s.outcome == 'success'" % wait_id for name, (_, wait_id, _) in PARITY_DOWNLOADS.items()}
        conditions = {
            "Verify public prompt golden vectors":
                "${{ !cancelled() && %s && steps.test-products.outcome == 'success' && "
                "steps.mimo-prompt-fixtures.outcome == 'success' && %s }}"
                % (shard, downloads["Verify public prompt golden vectors"]),
            "Verify pinned Nemotron prompts and numeric cache plans":
                "${{ !cancelled() && %s && steps.test-products.outcome == 'success' && %s }}"
                % (shard, downloads["Verify pinned Nemotron prompts and numeric cache plans"]),
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
                self.assertTrue(command.startswith("set -euo pipefail\n"), command)
                # The count comes from the run's xUnit report and stdout, never
                # the merged console a SwiftPM warning can split.
                self.assertIn(f'NESTED_SUITE_REPORT="$report/parity-{label}" {script}\n', command)
                self.assertNotIn("2>&1", command)
                self.assertIn(f"provider-test-shards.py counts parity {filter_} \\\n"
                              f'  "$report/parity-{label}-swift-testing.xml" "$report/parity-{label}.log" '
                              f'"$report/shard-parity-{label}.json"', command)
                # Each script still runs exactly its suite, with its artifacts required.
                source = (ROOT / script).read_text()
                self.assertIn("PROMPT_PARITY_REQUIRED=1", source)
                self.assertIn(filter_, source)
        prompt = steps[names.index("Verify public prompt golden vectors")]
        self.assertEqual(field(prompt, "id"), "prompt-parity")
        self.assertEqual(field(prompt, "PROMPT_PARITY_SKIP_BUILD", indent=10), "'1'")
        # Without the opt-in (the release qualification lane), the script builds as before.
        source = (ROOT / "scripts/verify-prompt-parity.sh").read_text()
        self.assertIn('[[ "${PROMPT_PARITY_SKIP_BUILD:-0}" != 0 ]] ||\n'
                      '  swift build --package-path "$ROOT/provider-swift" --configuration "$CONFIGURATION" --build-tests',
                      source)
        # Its suite runs through the same executed-count and skip gate.
        self.assertIn("../scripts/run-nested-suite.sh ProductionPromptParityTests", source)
        self.assertIn("run-nested-suite.sh NemotronTemplateParityLiveTests",
                      (ROOT / "scripts/verify-nemotron-prompt-parity.sh").read_text())

    def test_prompt_parity_reuses_only_verified_downloads(self):
        steps = step_blocks(self.jobs["test-provider"])
        names = [field(step, "name", indent=6) for step in steps]
        cache = CI_CACHE_ROOT + "/prompt-fixture-cache"
        restore = steps[names.index("Restore verified prompt fixture downloads")]
        save = steps[names.index("Save verified prompt fixture downloads")]
        parity = [steps[names.index(name)] for name in PARITY_STEPS]
        self.assertEqual(field(restore, "id"), "prompt-fixture-cache")
        self.assertEqual(field(restore, "uses"), CACHE_RESTORE)
        self.assertEqual(field(save, "uses"), CACHE_SAVE)
        # The key is the pinned content: every manifest both parity steps read,
        # never the run or the branch; only the exact key restores.
        manifests = ("fixtures/prompt-contract/v1/manifests/*.json",
                     "fixtures/prompt-contract/nemotron/manifests/*.json")
        self.assertEqual(field(restore, "key", indent=10),
                         "prompt-fixtures-v1-${{ hashFiles('%s', '%s') }}" % manifests)
        for manifest in manifests:
            self.assertTrue(list(ROOT.glob(manifest)), manifest)
        self.assertNotIn("restore-keys", restore)
        self.assertEqual(field(save, "key", indent=10), "${{ steps.prompt-fixture-cache.outputs.cache-primary-key }}")
        for step in (restore, save):
            self.assertEqual(field(step, "path", indent=10), cache)
        # Restored before the products, while the build runs (it needs none).
        self.assertEqual(field(restore, "if"), gated("${{ !cancelled() && matrix.shard == 1 }}"))
        # A push saves once both parity steps verified every artifact; a pull
        # request or an exact hit saves nothing.
        self.assertEqual(field(save, "if"),
                         gated("${{ !cancelled() && " + SAVE_CACHES + " && matrix.shard == 1 && "
                               "steps.prompt-parity.outcome == 'success' && steps.nemotron-parity.outcome == 'success' && "
                               "steps.prompt-fixture-cache.outputs.cache-hit != 'true' }}"))
        self.assertEqual(field(parity[1], "id"), "nemotron-parity")
        self.assertLess(steps.index(restore), steps.index(parity[0]))
        self.assertLess(steps.index(parity[1]), steps.index(save))
        for step in parity:
            self.assertEqual(field(step, "PROMPT_PARITY_DOWNLOAD_CACHE", indent=10), cache)
        # The same downloader fetches what the entry lacks into that cache in
        # the background, from the products' interpreter on, while the build
        # runs: one download per parity step, from its script's manifests and
        # CDN. Each parity step waits for its own and runs only if it succeeded.
        # Every shard starts the MiMo metadata preparation first, with the same
        # interpreter (test_mimo_metadata_is_prepared_while_the_build_runs).
        python = next(step for step in steps if (uses(step) or "").startswith("actions/setup-python@"))
        mimo_restore, mimo_start = (steps[names.index(name)] for name in
                                    ("Restore verified MiMo metadata downloads", MIMO_METADATA_START_STEP))
        start = steps[names.index(PARITY_DOWNLOAD_START)]
        products = next(step for step in steps if field(step, "uses") == PRODUCTS_ACTION)
        tests = steps[names.index("Run Swift tests")]
        self.assertEqual(field(python, "python-version", indent=10), "'3.12.10'")
        self.assertEqual([steps.index(step) for step in (python, mimo_restore, mimo_start, restore, start, products)],
                         list(range(steps.index(python), steps.index(python) + 6)))
        self.assertEqual(field(python, "if"), "${{ !cancelled() }}")
        self.assertEqual(field(start, "if"), "${{ !cancelled() && matrix.shard == 1 }}")
        self.assertEqual(field(start, "id"), "prompt-fixture-downloads")
        self.assertEqual(field(start, "PROMPT_PARITY_DOWNLOAD_CACHE", indent=10), cache)
        # The downloader refuses a path with a symbolic link in it, so both roots are physical.
        self.assertEqual(run_command(start), textwrap.dedent("""\
            root=$(pwd -P)
            work=$(cd "$RUNNER_TEMP" && pwd -P)/prompt-fixture-prefetch
            mkdir "$work"
            for contracts in v1 nemotron; do
              python3 scripts/ci-background-step.py start "$RUNNER_TEMP/prompt-fixture-downloads/$contracts" \\
                python3 scripts/prepare-prompt-fixtures.py \\
                --manifest-source-directory "$root/fixtures/prompt-contract/$contracts/manifests" \\
                --cdn-url "${PROMPT_PARITY_CDN_URL:-https://models.darkbloom.ai}" \\
                --artifact-root "$work/$contracts/artifacts" --manifest-directory "$work/$contracts/manifests" \\
                --download-cache "$PROMPT_PARITY_DOWNLOAD_CACHE"
            done"""))
        for name, (wait_name, wait_id, contracts) in PARITY_DOWNLOADS.items():
            with self.subTest(step=name):
                script = PARITY_STEPS[name][0]
                source = (ROOT / script).read_text()
                self.assertIn(f'--manifest-source-directory "$ROOT/fixtures/prompt-contract/{contracts}/manifests"', source)
                self.assertIn('--cdn-url "${PROMPT_PARITY_CDN_URL:-https://models.darkbloom.ai}"', source)
                wait = steps[names.index(wait_name)]
                self.assertEqual(steps.index(wait) + 1, names.index(name))
                self.assertLess(steps.index(tests), steps.index(wait))
                self.assertEqual(field(wait, "id"), wait_id)
                self.assertEqual(field(wait, "if"), "${{ !cancelled() && matrix.shard == 1 && "
                                                    "steps.test-products.outcome == 'success' && "
                                                    "steps.prompt-fixture-downloads.outcome == 'success' }}")
                self.assertEqual(run_command(wait), 'python3 scripts/ci-background-step.py wait '
                                                    f'"$RUNNER_TEMP/prompt-fixture-downloads/{contracts}"')
                self.assertNotIn("continue-on-error:", wait)
        for step in (python, start):
            self.assertNotIn("continue-on-error:", step)
        # Both scripts hand the cache to the one downloader, which re-verifies it.
        for script, _, _ in PARITY_STEPS.values():
            source = (ROOT / script).read_text()
            self.assertIn('[[ -z "${PROMPT_PARITY_DOWNLOAD_CACHE:-}" ]] || '
                          'download_cache=(--download-cache "$PROMPT_PARITY_DOWNLOAD_CACHE")', source)
            self.assertIn('${download_cache[@]+"${download_cache[@]}"}', source)

    def test_fixture_prerequisites_are_fail_closed_in_provider(self):
        # The shards and Provider Gates prepare the same fixtures, so each
        # gate sees the environment it had in the last shard. The metadata's
        # wait keeps the preparation's id, so every step that needs the
        # metadata still runs only once it succeeded.
        for job_id in ("test-provider", GATES):
            with self.subTest(job=job_id):
                steps = step_blocks(self.jobs[job_id])
                fixtures = [step for step in steps if run_command(step) == MIMO_METADATA_WAIT]
                self.assertEqual(len(fixtures), 1)
                self.assertEqual(field(fixtures[0], "id"), "mimo-prompt-fixtures")
                self.assertEqual(field(fixtures[0], "if"),
                                 "${{ !cancelled() && steps.test-products.outcome == 'success' && "
                                 "steps.mimo-metadata-downloads.outcome == 'success' }}")
                self.assertEqual([step for step in steps if "python3 scripts/prepare-mimo-prompt-fixtures.py" in step],
                                 [step for step in steps if run_command(step) == MIMO_METADATA_START])
                synthetic, = [step for step in steps if run_command(step) == MIMO_PROVIDER_PREPARE]
                self.assertEqual(field(synthetic, "id"), "mimo-fixtures")
                self.assertEqual(field(synthetic, "if"), READY)
        # The HTTP preparation includes the plain prompt-fixture preparation.
        self.assertIn(MIMO_PREPARE, MIMO_HTTP_PREPARE)

    def test_mimo_metadata_is_prepared_while_the_build_runs(self):
        # The metadata needs no test products. Every shard and Provider Gates
        # restores the verified downloads and starts the preparation's own
        # commands in the background before the products, with the products'
        # interpreter, and waits for it where the preparation stood: before
        # the first step that reads the metadata, and before the save, which
        # still saves only what a succeeded preparation verified.
        # The variables' file is new: `start` refuses an existing directory.
        background = (ROOT / "scripts/ci-background-step.py").read_text()
        self.assertIn("directory.mkdir(parents=True, exist_ok=False)", background)
        first_reader = {"test-provider": "Run Swift tests", GATES: "Test Gemma quoted numeric argument conformance switches"}
        for job_id, reader in first_reader.items():
            with self.subTest(job=job_id):
                steps = step_blocks(self.jobs[job_id])
                names = [field(step, "name", indent=6) for step in steps]
                python = next(step for step in steps if (uses(step) or "").startswith("actions/setup-python@"))
                restore, start, wait, save, synthetic = (steps[names.index(name)] for name in (
                    "Restore verified MiMo metadata downloads", MIMO_METADATA_START_STEP, MIMO_METADATA_WAIT_STEP,
                    "Save verified MiMo metadata downloads", "Prepare bounded synthetic MiMo provider fixtures offline"))
                products = next(step for step in steps if field(step, "uses") == PRODUCTS_ACTION)
                self.assertEqual(field(python, "if"), "${{ !cancelled() }}")
                self.assertEqual(field(python, "python-version", indent=10), "'3.12.10'")
                self.assertEqual([steps.index(step) for step in (python, restore, start)],
                                 list(range(steps.index(python), steps.index(python) + 3)))
                self.assertLess(steps.index(start), steps.index(products))
                self.assertEqual(field(restore, "id"), "mimo-metadata-cache")
                self.assertEqual(field(restore, "if"), gated("${{ !cancelled() }}"))
                self.assertEqual(field(start, "id"), "mimo-metadata-downloads")
                self.assertEqual(field(start, "if"), "${{ !cancelled() }}")
                self.assertEqual(run_command(start), MIMO_METADATA_START)
                self.assertEqual(run_command(wait), MIMO_METADATA_WAIT)
                self.assertEqual([steps.index(step) for step in (wait, save, synthetic)],
                                 list(range(steps.index(wait), steps.index(wait) + 3)))
                self.assertLess(steps.index(products), steps.index(wait))
                self.assertLess(steps.index(synthetic), names.index(reader))
                self.assertEqual(field(save, "if"),
                                 gated("${{ !cancelled() && " + SAVE_CACHES + " && steps.mimo-prompt-fixtures.outcome == 'success' "
                                       "&& steps.mimo-metadata-cache.outputs.cache-hit != 'true' }}"))
                for step in (python, restore, start, wait):
                    self.assertNotIn("continue-on-error:", step)
                    self.assertNotIn("timeout-minutes:", step)

    def test_native_mimo_gates_keep_isolated_processes_and_fixture_guards(self):
        steps = step_blocks(self.jobs[GATES])
        synthetic = next(step for step in steps if run_command(step) == MIMO_PROVIDER_PREPARE)
        self.assertEqual(field(synthetic, "id"), "mimo-fixtures")
        self.assertEqual(field(synthetic, "if"), READY)
        for name, command in MIMO_NATIVE_COMMANDS.items():
            with self.subTest(gate=name):
                gate = next(step for step in steps if field(step, "name", indent=6) == name)
                self.assertEqual(run_command(gate), command)
                self.assertEqual(field(gate, "if"), MIMO_READY)
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
        steps = step_blocks(self.jobs[GATES])
        fixture = next(s for s in steps if field(s, "id") == "mimo-audio-fixtures")
        self.assertIn("prepare-mimo-audio-fixtures.py", run_command(fixture))
        # The 1.87 GB codec is fetched only when the gate's inputs changed;
        # the gate needs the fixture, so it skips with it.
        # It needs no test products, so the codec is fetched before them,
        # while the build runs, with the interpreter the later steps use
        # (selected for the MiMo metadata too, so on every run).
        audio_ready = "${{ !cancelled() && inputs.mimo_audio == 'true' }}"
        self.assertEqual(field(fixture, "if"), audio_ready)
        restore = next(s for s in steps if field(s, "id") == "mimo-audio-cache")
        self.assertEqual(field(restore, "if"), gated(audio_ready))
        products = next(s for s in steps if field(s, "id") == "test-products")
        python = next(s for s in steps if (uses(s) or "").startswith("actions/setup-python@"))
        self.assertEqual(field(python, "if"), "${{ !cancelled() }}")
        self.assertEqual(field(python, "python-version", indent=10), "'3.12.10'")
        self.assertLess(steps.index(python), steps.index(restore))
        self.assertLess(steps.index(restore), steps.index(fixture))
        self.assertLess(steps.index(fixture), steps.index(products))
        gate = next(s for s in steps if field(s, "name", indent=6) == "Run isolated native MiMo audio gate")
        self.assertIn("testNativeAudioRelease", run_command(gate))
        self.assertIn("run-nested-suite.sh", run_command(gate))
        self.assertEqual(field(gate, "if"), "${{ !cancelled() && steps.test-products.outcome == 'success' "
                                            "&& steps.mimo-audio-fixtures.outcome == 'success' }}")
        self.assertEqual(field(gate, "MIMO_V26_MANAGED_AUDIO_PROVIDER_TESTS", indent=10), "'1'")
        self.assertNotIn("continue-on-error:", gate)

    def test_cluster_metadata_runners_run_every_runner_and_fail_on_any(self):
        # The metadata runners run in the gated cluster jobs: no Mac job runs
        # only these (David, 2026-11-04). The two that compile a release build
        # of the cluster runtime run in Cluster Release Build Checks on a large
        # runner; the others in shard 2 of Cluster Focused Checks, beside
        # shard 1's runner scripts.
        self.assertNotIn("test-cluster-checks", self.jobs)
        self.assertNotIn("test-cluster-checks", self.jobs["route"])
        focused, release = self.jobs["test-cluster-focused"], self.jobs["cluster-release-checks"]
        self.assertIn("    name: Cluster Focused Checks (shard ${{ matrix.shard }})\n", focused)
        self.assertIn("    name: Cluster Release Build Checks\n", release)
        # Both shards read the lane the approval names, requested for 2 jobs.
        # The release build checks ask with their size.
        self.assertIn("    runs-on: ${{ fromJSON(inputs.routes)['test-cluster-focused'] }}\n", focused)
        self.assertIn("      matrix:\n        shard: [1, 2]\n", focused)
        self.assertRegex(self.jobs["route"], re.escape(
            "        test-cluster-focused macos_arm64 blacksmith-12vcpu-macos-27 "
            "${{ needs.components.outputs.cluster == 'true' && 2 || 0 }} ") + LANE_PLACEMENT_AND_SIZE + r"\n")
        self.assertIn("    runs-on: ${{ fromJSON(inputs.routes)['cluster-release-checks'] }}\n", release)
        self.assertRegex(self.jobs["route"], re.escape(
            f"        cluster-release-checks macos_arm64 {BLACKSMITH_MAC} "
            "${{ needs.components.outputs.cluster == 'true' && 1 || 0 }} ") + LANE_PLACEMENT_AND_SIZE + r"\n")
        for job in (focused, release):
            self.assertIn("    if: ${{ inputs.cluster == 'true' }}\n", job)
            self.assertNotRegex(job, r"(?m)^    needs:")
            self.assertEqual(continues_on_error(job), [SAMPLER_STEPS[-1]])
            for forbidden in ("secrets.", "DARKBLOOM_EXCLUSIVE_NATIVE_GPU_TEST:", BUILD_ACTION, PRODUCTS_ACTION):
                self.assertNotIn(forbidden, job)
        runners = {
            "Run worker capability checks": (release, None, "bash libs/darkbloom-cluster-worker/Tests/CapabilityChecks/run.sh"),
            "Run prefill schedule checks": (release, None, "bash libs/darkbloom-cluster/Tests/PrefillScheduleChecks/run.sh"),
            "Run stage metadata checks": (focused, 2, 'python3 libs/darkbloom-cluster/Tests/StageMetadataChecks/run.py '
                                                      '--output "$RUNNER_TEMP/stage-metadata-checks"'),
            "Run GPT-OSS stage checks": (focused, 2, "bash libs/darkbloom-cluster/Tests/GPTOSSStageChecks/run.sh"),
            "Run Nemotron stage checks": (focused, 2, "bash libs/darkbloom-cluster/Tests/NemotronStageChecks/run.sh"),
            "Run cluster model provisioning checks":
                (focused, 2, "bash provider-swift/Tests/ClusterModelProvisioningChecks/run.sh provisioning"),
            "Run cluster onboarding checks": (focused, 2, "bash provider-swift/Tests/ClusterOnboardingChecks/run.sh"),
            "Run cluster console checks": (focused, 2, "bash provider-swift/Tests/ClusterConsoleChecks/run.sh"),
            "Run cluster qualification checks":
                (focused, 2, "bash libs/darkbloom-cluster-worker/Tests/QualificationChecks/run.sh"),
            # It also runs the provider's pairing, diagnostics and placement
            # flow runners (scripts/cluster-test-plan.py).
            "Run cluster focused checks": (focused, 1, "python3 scripts/cluster-test-plan.py run focused 1"),
        }
        for job in (focused, release):
            steps = step_blocks(job)
            checkout = next(step for step in steps if uses(step) == CHECKOUT)
            self.assertIsNone(field(checkout, "submodules", indent=10))
            self.assertEqual(field(steps[steps.index(checkout) + 1], "name", indent=6), SUBMODULES_STEP)
            toolchain = next(step for step in steps if field(step, "id") == "toolchain")
            self.assertEqual(run_command(toolchain), "./scripts/prepare-provider-release-toolchain.sh")
        for name, (job, shard, command) in runners.items():
            with self.subTest(runner=name):
                step = {field(step, "name", indent=6): step for step in step_blocks(job)}[name]
                self.assertEqual(run_command(step), command)
                # Each runner needs only the toolchain, not an earlier runner's success.
                where = f"matrix.shard == {shard} && " if shard else ""
                self.assertEqual(field(step, "if"), "${{ !cancelled() && %ssteps.toolchain.outcome == 'success' }}" % where)
                self.assertTrue((ROOT / command.split()[1]).is_file())
        # The release build uses the whole large runner. The prefill schedule
        # runner builds its bootstrap product in the same retained build,
        # before that build is recorded and saved.
        steps = step_blocks(release)
        named = {field(step, "name", indent=6): step for step in steps}
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
        # The loose tier leaves out only libs/mlx-swift-lm's pin (and any pin
        # nested in it); the C++ MLX pins stay in both tiers. The exact key and
        # the strict prefix extend the loose prefix, and CI (master) restores
        # only the strict one.
        program = '$2 != "libs/mlx-swift-lm" && index($2, "libs/mlx-swift-lm/") != 1'
        loose_filter = f"awk '{program}' <<< \"$pins\""
        self.assertIn(loose_filter, key)
        sample = ("0123abc libs/mlx\n+4567def libs/mlx-swift\n89abcde libs/mlx-swift/Source/Cmlx/mlx\n"
                  "fedcba9 libs/mlx-swift-lm\n7654321 libs/mlx-swift-lm/nested\n")
        loose = subprocess.run(["awk", program], input=sample,
                               capture_output=True, text=True, check=True)
        self.assertEqual(loose.stdout, "0123abc libs/mlx\n+4567def libs/mlx-swift\n"
                                       "89abcde libs/mlx-swift/Source/Cmlx/mlx\n")
        self.assertIn('            echo "loose-prefix=cluster-metadata-release-v2-$base-"\n'
                      '            echo "prefix=cluster-metadata-release-v2-$base-$pinned-"\n'
                      '            echo "key=cluster-metadata-release-v2-$base-$pinned-$GITHUB_SHA"\n'
                      '          } >> "$GITHUB_OUTPUT"\n', key)
        self.assertIn("          restore-keys: |\n"
                      "            ${{ steps.cluster-build-key.outputs.prefix }}\n"
                      "            ${{ !inputs.strict_cache && steps.cluster-build-key.outputs.loose-prefix || '' }}\n",
                      named["Restore cluster metadata build"])
        for step in (steps[record], steps[upload]):
            self.assertIn("steps.capability-checks.outcome == 'success'", field(step, "if"))
            # Only pushes to a saving branch save; a pull request never does.
            self.assertIn(SAVE_CACHES + " && ", field(step, "if"))
            self.assertIn("steps.cluster-build-cache.outputs.cache-hit != 'true'", field(step, "if"))
        support = (ROOT / "libs/darkbloom-cluster/Tests/Support/native-metadata.sh").read_text()
        self.assertIn('task_jobs="${DARKBLOOM_CLUSTER_METADATA_BUILD_JOBS:-4}"', support)
        self.assertIn('--jobs "$task_jobs"', support)

    def test_runtime_shard_six_runs_the_worker_lifecycle_tests_while_it_waits(self):
        # The worker package's own tests (D6's no-exit path among them), which
        # no other job runs, need no test products: shard 6 builds and runs
        # them in the background while it waits for the cluster build. They
        # fail the job, end before the runtime tests start, and the runtime
        # tests run whatever their result.
        job = self.jobs["test-cluster"]
        self.assertIn("          - {shard: 6, lane: test-cluster-2}\n", job)
        steps = step_blocks(job)
        named = {field(step, "name", indent=6): step for step in steps}
        order = [field(step, "name", indent=6) for step in steps]
        toolchain, start, wait = (named[name] for name in (
            "Select SDK 27 provider toolchain", "Start the worker's request lifecycle tests",
            "Wait for the worker's request lifecycle tests"))
        self.assertEqual(field(toolchain, "id"), "toolchain")
        self.assertEqual(field(toolchain, "if"), "${{ matrix.shard == 6 }}")
        self.assertEqual(run_command(toolchain), "./scripts/prepare-provider-release-toolchain.sh")
        self.assertEqual(field(start, "id"), "worker-lifecycle")
        self.assertEqual(field(start, "if"), "${{ matrix.shard == 6 && steps.toolchain.outcome == 'success' }}")
        self.assertEqual(run_command(start), 'python3 scripts/ci-background-step.py start "$RUNNER_TEMP/worker-lifecycle" '
                                             "bash libs/darkbloom-cluster-worker/Tests/LifecycleChecks/run.sh")
        self.assertEqual(field(start, "DARKBLOOM_WORKER_TEST_JOBS", indent=10), "'4'")
        # Built outside the checkout, beside which the cluster products unpack.
        self.assertEqual(field(start, "DARKBLOOM_WORKER_TEST_SCRATCH", indent=10),
                         "${{ runner.temp }}/worker-lifecycle-build")
        self.assertEqual(field(wait, "if"), "${{ !cancelled() && steps.worker-lifecycle.outcome == 'success' }}")
        self.assertEqual(run_command(wait), 'python3 scripts/ci-background-step.py wait "$RUNNER_TEMP/worker-lifecycle"')
        for step in (toolchain, start, wait):
            self.assertNotIn("continue-on-error:", step)
        download = next(step for step in steps if field(step, "uses") == PRODUCTS_ACTION)
        sequence = [order.index(name) for name in (
            "Select SDK 27 provider toolchain", "Start the worker's request lifecycle tests")]
        sequence += [steps.index(download)]
        sequence += [order.index(name) for name in (
            "Wait for the worker's request lifecycle tests", "Run cluster runtime tests")]
        self.assertEqual(sequence, sorted(sequence))
        self.assertEqual(field(named["Run cluster runtime tests"], "if"),
                         "${{ !cancelled() && steps.test-products.outcome == 'success' }}")
        script = ROOT / "libs/darkbloom-cluster-worker/Tests/LifecycleChecks/run.sh"
        self.assertIn('task_jobs="${DARKBLOOM_WORKER_TEST_JOBS:-4}"', script.read_text())
        self.assertIn('--scratch-path "$DARKBLOOM_WORKER_TEST_SCRATCH"', script.read_text())
        self.assertEqual([job_id for job_id, text in self.jobs.items() if "LifecycleChecks/run.sh" in text],
                         ["test-cluster"])

    def test_each_lane_builds_once_and_its_test_jobs_run_its_products(self):
        # Each lane builds once, on a large runner (its lane asks with its
        # size), and uploads its products only when its tests run; a push of a
        # tested tree skips the build jobs as well as the test jobs
        # (provider-plan.yml).
        self.assertNotIn("refresh-caches", self.jobs)
        for job_id, lane in BUILD_JOBS.items():
            with self.subTest(job=job_id):
                job = self.jobs[job_id]
                self.assertIn(f"    runs-on: ${{{{ fromJSON(inputs.routes)['{job_id}'] }}}}\n", job)
                self.assertIn(f"    if: ${{{{ inputs.{lane} == 'true' }}}}\n", job)
                # Requested exactly when the job runs: the plan's components
                # (already false when skip is true in provider-plan.yml).
                self.assertRegex(self.jobs["route"], re.escape(
                    f"        {job_id} macos_arm64 {BLACKSMITH_MAC} "
                    f"${{{{ needs.components.outputs.{lane} == 'true' && 1 || 0 }}}} ") + LANE_PLACEMENT_AND_SIZE + r"\n")
                self.assertNotRegex(job, r"(?m)^    (needs|strategy):")
                steps = step_blocks(job)
                builds = [step for step in steps if field(step, "uses") == BUILD_ACTION]
                self.assertEqual(len(builds), 1)
                self.assertEqual(field(builds[0], "lane", indent=10), lane)
                self.assertIsNone(field(builds[0], "if"))
                upload, = [step for step in steps if field(step, "uses") == PRODUCTS_ACTION]
                self.assertEqual(steps.index(upload), steps.index(builds[0]) + 1)
                self.assertEqual(field(upload, "if"), f"${{{{ inputs.{lane} == 'true' }}}}")
                self.assertEqual(field(upload, "lane", indent=10), lane)
                self.assertEqual(field(upload, "direction", indent=10), "upload")
                self.assertEqual(continues_on_error(job), [SAMPLER_STEPS[-1]])
        # The test jobs never build their products: each starts beside its
        # lane's build job (no `needs`, so its Mac, checkout and toolchain are
        # ready when the products are), waits for that job through the products action, which
        # reads the run's jobs, and runs its products at the build job's fixed
        # path. A build that did not succeed fails its test jobs, and with
        # them the gate.
        for job_id, build in PRODUCT_JOBS.items():
            with self.subTest(job=job_id):
                job = self.jobs[job_id]
                self.assertNotRegex(job, r"(?m)^    needs:")
                self.assertIn("    permissions:\n      contents: read\n      actions: read\n", job)
                self.assertNotIn(build, self.jobs["provider-test-gate"])
                self.assertNotIn(BUILD_ACTION, job)
                download, = [step for step in step_blocks(job) if field(step, "uses") == PRODUCTS_ACTION]
                self.assertEqual(field(download, "lane", indent=10), BUILD_JOBS[build])
                self.assertEqual(field(download, "direction", indent=10), "download")
        # A called workflow's job gets only what its caller's job grants;
        # GitHub refuses a run whose called job asks for more.
        for caller in (DEV_WORKFLOW, MASTER_WORKFLOW):
            with self.subTest(caller=caller.name):
                tests = job_blocks(caller.read_text().split("\njobs:\n", 1)[1])["tests"]
                self.assertIn("    permissions:\n      contents: read\n      actions: read\n", tests)
        for job_id in (*BUILD_JOBS, *PRODUCT_JOBS):
            with self.subTest(job=job_id):
                gate, first = step_blocks(self.jobs[job_id])[:2]
                self.assertEqual(field(gate, "name", indent=6), CACHE_GATE_STEP)
                self.assertEqual(field(first, "name", indent=6), FIXED_PATH_STEP)
                self.assertEqual(run_command(first), FIXED_PATH)
        for job_id in ("test-cluster-focused", "cluster-release-checks", "provider-test-gate"):
            self.assertNotIn(FIXED_PATH_STEP, self.jobs[job_id])
        # The products action: zstd archives stored as they are for one day;
        # a test job selects the toolchain, downloads, checks and unpacks.
        action = PRODUCTS.read_text()
        steps = step_blocks(action, indent=4)
        names = [field(step, "name", indent=4) or uses(step) for step in steps]
        self.assertEqual(names, ["Validate the lane and direction", "Pack the test products", "Upload the test products",
                                 "Report the upload time", None, "Select SDK 27 provider toolchain",
                                 "Wait for the build job", "Start the download clock", "Download the test products",
                                 "Check and unpack the test products"])
        wait = steps[names.index("Wait for the build job")]
        self.assertEqual(field(wait, "run", indent=6), 'python3 scripts/ci-test-products.py wait "$LANE"')
        self.assertEqual(field(wait, "GITHUB_TOKEN", indent=8), "${{ github.token }}")
        upload = steps[2]
        for option, value in (("compression-level", "0"), ("retention-days", "1"), ("if-no-files-found", "error"),
                              ("overwrite", "true"), ("name", "${{ inputs.lane }}-test-products")):
            self.assertEqual(field(upload, option, indent=8), value)
        self.assertIn('python3 scripts/ci-test-products.py pack "$LANE" "$RUNNER_TEMP/test-products/$LANE.tar.zst"',
                      steps[1])
        self.assertIn('python3 scripts/ci-test-products.py unpack "$LANE" "$RUNNER_TEMP/test-products/$LANE.tar.zst"',
                      steps[-1])
        for step in steps[1:4]:
            self.assertEqual(field(step, "if", indent=6), "inputs.direction == 'upload'")
        for step in steps[4:]:
            self.assertEqual(field(step, "if", indent=6), "inputs.direction == 'download'")
        for forbidden in ("install-release-cmake.sh", "prepare-metal-toolchain.py", "swift build", "continue-on-error:"):
            self.assertNotIn(forbidden, action)

    def test_every_mac_job_samples_its_resources_without_failing(self):
        for job_id in MAC_JOBS:
            with self.subTest(job=job_id):
                steps = step_blocks(self.jobs[job_id])
                names = [field(step, "name", indent=6) for step in steps]
                start = names.index(SAMPLER_STEPS[0])
                # After the checkout that brings the script; reported last, always.
                self.assertGreater(start, next(index for index, step in enumerate(steps) if uses(step) == CHECKOUT))
                self.assertEqual(run_command(steps[start]),
                                 'python3 scripts/ci-resource-sampler.py start "$RUNNER_TEMP/resource-samples"')
                report, upload = steps[-2:]
                self.assertEqual(names[-2:], list(SAMPLER_STEPS[1:]))
                self.assertEqual(run_command(report), 'python3 scripts/ci-resource-sampler.py report '
                                                      '"$RUNNER_TEMP/resource-samples" || true')
                for step in (report, upload):
                    self.assertEqual(field(step, "if"), "${{ always() }}")
                self.assertIn("continue-on-error: true", upload)
                self.assertEqual(field(upload, "name", indent=10),
                                 "resource-samples-${{ github.job }}-${{ strategy.job-index }}")
                self.assertEqual(field(upload, "if-no-files-found", indent=10), "ignore")

    def test_parity_has_no_backend_caches_or_credentials(self):
        # Prompt Parity now runs in the provider shards; besides .git, the only
        # caches the provider test jobs save directly are the verified fixture
        # downloads: the shards' prompt fixtures, Provider Gates' audio codec
        # (saved before its products, as it is fetched while the build runs).
        saved = {"test-provider": ["Save .git for later runs", "Save verified MiMo metadata downloads",
                                   "Save verified prompt fixture downloads"],
                 GATES: ["Save .git for later runs", "Cache verified MiMo audio codec",
                         "Save verified MiMo metadata downloads"]}
        for job_id, names in saved.items():
            with self.subTest(job=job_id):
                saves = [step for step in step_blocks(self.jobs[job_id]) if "actions/cache/save@" in step]
                self.assertEqual([field(step, "name", indent=6) for step in saves], names)
                for forbidden in ("coordinator/", "cargo ", "rust-key", "secrets.", "darkbloom-platform"):
                    self.assertNotIn(forbidden, self.jobs[job_id])
        self.assertNotIn("test-provider-parity", workflow_text())

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

    def test_release_integrity_runs_every_check_at_the_same_time(self):
        steps = {field(step, "name", indent=6): step for step in work_steps(self.jobs["release-integrity"])}
        self.assertEqual(list(steps), ["Run the release integrity checks"])
        step = steps["Run the release integrity checks"]
        self.assertEqual(field(step, "TARGET_BRANCH", indent=10), "${{ github.base_ref || github.ref_name }}")
        self.assertIsNone(field(step, "if"))
        self.assertNotIn("continue-on-error:", self.jobs["release-integrity"])
        script = run_command(step)
        # One runner, with no --jobs: one check per CPU of the runner.
        self.assertTrue(script.startswith("python3 scripts/run-concurrent-checks.py <<'CHECKS'\n"), script)
        self.assertTrue(script.endswith("\nCHECKS"), script)
        commands = [line.strip() for line in script.splitlines()[1:-1]
                    if line.strip() and not line.strip().startswith("#")]
        # Every check runs once; none may hide its own failure.
        self.assertEqual(len(commands), len(set(commands)))
        self.assertEqual(set(commands), set(RELEASE_INTEGRITY_CHECKS))
        for command in commands:
            self.assertNotRegex(command, r"\|\| *true|; *true$|&")
        # The longest suites start first.
        self.assertEqual(commands[:2], ["python3 .github/scripts/test-threat-budget.py",
                                        "python3 scripts/test-darkbloom-route.py"])

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
        # One build job per lane; the test jobs build nothing.
        self.assertEqual(len(calls), len(BUILD_JOBS))
        for call in calls:
            self.assertEqual(field(call, "save-caches", indent=10), "${{ env.SAVE_CACHES }}")
            self.assertEqual(field(call, "strict-cache", indent=10), "${{ inputs.strict_cache }}")

    def test_master_restores_only_the_strict_cache_tier(self):
        # Master runs (pushes and pull requests into master) restore only an
        # entry of this exact recipe; dev may restore the looser tiers.
        self.assertIn("      strict_cache: {type: boolean, default: false}\n",
                      WORKFLOW.read_text().split("\njobs:\n", 1)[0])
        self.assertIn("      strict_cache: true\n", MASTER_WORKFLOW.read_text())
        self.assertIn("      strict_cache: false\n", DEV_WORKFLOW.read_text())
        self.assertIn("  strict-cache:\n", ACTION.read_text().split("\nruns:\n", 1)[0])

    def test_every_checkout_reuses_master_git_and_falls_back_to_a_cold_checkout(self):
        # The gate checks out only the tree lookup's script, the plan job the
        # full blobless history its classifier diffs (the lookup script with
        # it), and the CI plan checks the files they read (blobs on demand),
        # all without the .git cache.
        gate = self.jobs["provider-test-gate"]
        self.assertEqual(gate.count("actions/checkout@"), 1)
        self.assertIn("sparse-checkout: scripts/ci-tested-tree.py\n", gate)
        plan = self.jobs["components"]
        self.assertEqual(plan.count("actions/checkout@"), 1)
        self.assertEqual([option for option in checkout_options(step_blocks(plan)[0]) if option],
                         ["fetch-depth: 0", "filter: blob:none", "persist-credentials: false"])
        self.assertNotIn("actions/cache", plan)
        plan_checks = self.jobs["ci-plan-checks"]
        self.assertEqual(plan_checks.count("actions/checkout@"), 1)
        self.assertIn("          filter: blob:none\n          sparse-checkout: ${{ env.CHECKOUT_SPARSE }}\n", plan_checks)
        # The dispatch's ref resolver fetches every branch's commits, no trees.
        commit = self.jobs["commit"]
        self.assertEqual(commit.count("actions/checkout@"), 1)
        self.assertIn("          fetch-depth: 0\n          filter: tree:0\n          persist-credentials: false\n", commit)
        self.assertIn("          ref: ${{ inputs.sha }}\n          persist-credentials: false\n          filter: blob:none\n",
                      plan_checks)
        checkouts = {job_id: job for job_id, job in self.jobs.items()
                     if "actions/checkout@" in job
                     and job_id not in ("components", "provider-test-gate", "ci-plan-checks", "commit")}
        self.assertEqual(set(checkouts), {"release-integrity", "docs", *MAC_JOBS})
        for job_id, job in checkouts.items():
            with self.subTest(job=job_id):
                steps = step_blocks(job)
                # Each first chooses its Actions cache; the jobs of the test
                # products then move to the fixed build path.
                self.assertEqual(field(steps.pop(0), "name", indent=6), CACHE_GATE_STEP)
                if job_id in (*BUILD_JOBS, *PRODUCT_JOBS):
                    self.assertEqual(field(steps.pop(0), "name", indent=6), FIXED_PATH_STEP)
                if job_id in MAC_JOBS:
                    # The submodule checkout runs between the checkout and
                    # the .git save, so a saved .git holds the submodules.
                    submodules = steps.pop(4)
                    self.assertEqual(field(submodules, "name", indent=6), SUBMODULES_STEP)
                    self.assertEqual(run_command(submodules), SUBMODULES_RUN)
                    self.assertIsNone(field(submodules, "if"))
                    self.assertNotIn("continue-on-error", submodules)
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
                self.assertEqual(field(restore, "if"), CACHE_GATE)
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
                # Every checkout of the tested tree takes the dispatch's commit
                # (empty otherwise: the event's default).
                planned = "ref: ${{ needs.plan.outputs.sha }}"
                options = {"release-integrity": [planned, "persist-credentials: false", *sparse],
                           "docs": [planned, "fetch-depth: 0", "filter: blob:none", "persist-credentials: false"]
                           }.get(job_id, ["ref: ${{ inputs.sha }}", "persist-credentials: false", *sparse])
                self.assertEqual(checkout_options(checkout), options)
                self.assertEqual(field(save, "if"), gated(SAVE_CACHES + " && steps.git-cache.outputs.cache-hit != 'true'"))
                self.assertEqual(field(save, "uses"), CACHE_SAVE)
                self.assertEqual(field(save, "path", indent=10), ".git")
                self.assertEqual(field(save, "key", indent=10), "${{ steps.git-cache.outputs.cache-primary-key }}")

    def test_git_validation_keeps_healthy_and_partial_clones_and_discards_damaged_or_unsafe_ones(self):
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
            # A healthy .git that could run something at checkout: a hook, in
            # the repository or in a submodule's .git/modules directory, under
            # any case; a config that sets a hook directory or a file system
            # monitor, or includes another file; a symbolic link; or a .git
            # that is not a directory. Each is discarded before git reads it.
            def write(path, text):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text)
            unsafe = {
                "hook": lambda git_dir: write(git_dir / "hooks/post-checkout", "#!/bin/sh\ntouch ran\n"),
                "submodule-hook": lambda git_dir: write(git_dir / "modules/sub/hooks/post-checkout", "#!/bin/sh\n"),
                "hook-case": lambda git_dir: write(git_dir / "hooks/Post-Checkout", "#!/bin/sh\n"),
                "fsmonitor": lambda git_dir: git(git_dir.parent, "config", "core.fsmonitor", "touch ran"),
                "hooks-path": lambda git_dir: git(git_dir.parent, "config", "core.hooksPath", "/tmp"),
                "submodule-hooks-path": lambda git_dir: write(git_dir / "modules/sub/config",
                                                              "[core]\n\tHooksPath = /tmp\n"),
                "include": lambda git_dir: git(git_dir.parent, "config", "include.path", "/tmp/other"),
                "include-if": lambda git_dir: git(git_dir.parent, "config", "includeIf.gitdir:/.path", "/tmp/other"),
                "symlink": lambda git_dir: (git_dir / "info").mkdir(exist_ok=True)
                or (git_dir / "info/linked").symlink_to("/"),
            }
            for case, plant in unsafe.items():
                git(work, "clone", "-q", f"file://{origin}", case)
                plant(Path(work, case, ".git"))
                cases[case] = False
            Path(work, "git-file").mkdir()
            Path(work, "git-file", ".git").write_text(f"gitdir: {Path(work, 'healthy', '.git')}\n")
            cases["git-file"] = False
            # A healthy clone keeps git's sample hooks, which never run.
            write(Path(work, "healthy", ".git", "hooks", "post-checkout.sample"), "#!/bin/sh\ntouch ran\n")
            for case, kept in {**cases, "empty": False}.items():
                with self.subTest(case=case):
                    result = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", VALIDATE_GIT],
                                            cwd=Path(work, case), capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(Path(work, case, ".git").is_dir(), kept, result.stdout)
                    self.assertFalse(Path(work, case, ".git").exists() and not kept, result.stdout)
                    self.assertEqual("::warning" in result.stdout, not kept and case != "empty", result.stdout)
                    self.assertFalse(Path(work, case, "ran").exists())
            self.assertTrue(tree)

    def test_sparse_checkouts_skip_only_evidence_tarballs_and_landing_media(self):
        for path in (WORKFLOW, MASTER_WORKFLOW):
            with self.subTest(workflow=path.name):
                env = path.read_text().split("\njobs:\n", 1)[0]
                self.assertIn("  CHECKOUT_SPARSE: |\n" + "".join(f"    {pattern}\n" for pattern in SPARSE_PATTERNS),
                              env)
        # The macOS checkouts, Release Integrity's and the CI plan checks'.
        self.assertEqual(self.workflow.count("sparse-checkout: ${{ env.CHECKOUT_SPARSE }}"), len(MAC_JOBS) + 2)
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
        cluster = by_id["cluster-build"]
        metallib = by_id["metallib"]
        self.assertEqual(field(provider, "if", indent=6), "inputs.lane == 'provider'")
        self.assertEqual(field(provider, "working-directory", indent=6), "provider-swift")
        self.assertIn("swift build --build-tests", provider)
        self.assertIn("swift build --product darkbloom-fan-helper", provider)
        self.assertEqual(field(cluster, "if", indent=6), "inputs.lane == 'cluster'")
        self.assertEqual(field(cluster, "working-directory", indent=6), "libs/darkbloom-cluster")
        self.assertIn("swift build --build-tests", cluster)
        self.assertIsNone(field(metallib, "if", indent=6))
        self.assertIn('./scripts/stage-test-metallib.sh "$bin"', metallib)
        # In the provider lane the matched Metal library builds beside the
        # Swift build, after the Metal cache restore and the final source
        # timestamps; staging first waits for it and fails when it failed.
        names = [field(step, "name", indent=4) for step in steps]
        start = steps[names.index("Start the matched Metal library build")]
        self.assertEqual(field(start, "if", indent=6), "inputs.lane == 'provider'")
        self.assertEqual(field(start, "run", indent=6),
                         'python3 scripts/ci-background-step.py start "$RUNNER_TEMP/metallib-build" '
                         './scripts/fetch-metallib.sh "$RUNNER_TEMP/metallib-build/library"')
        self.assertEqual(field(start, "METALLIB_CACHE_DIR", indent=8), field(metallib, "METALLIB_CACHE_DIR", indent=8))
        self.assertLess(names.index("Restore source-matched Metal cache"), steps.index(start))
        self.assertLess(names.index("Revalidate source timestamps and discard cached runtime resources"), steps.index(start))
        self.assertLess(steps.index(start), min(steps.index(provider), steps.index(cluster)))
        self.assertEqual([line.strip() for line in metallib.split("      run: |\n", 1)[1].splitlines()[:3]],
                         ['if [ "$LANE" = provider ]; then',
                          'python3 scripts/ci-background-step.py wait "$RUNNER_TEMP/metallib-build"', 'fi'])
        for step in (provider, cluster, metallib, start):
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
        # dependencies and checkout path, then any with the same MLX pins.
        # With strict-cache (master), only this recipe's entries: the looser
        # tiers evaluate to empty lines, which actions/cache ignores.
        self.assertIn("restore-keys: |\n          ${{ steps.keys.outputs.swift-prefix }}\n"
                      "          ${{ inputs.strict-cache != 'true' && steps.keys.outputs.swift-loose-prefix || '' }}\n"
                      "          ${{ inputs.strict-cache != 'true' && steps.keys.outputs.swift-mlx-prefix || '' }}\n",
                      swift_cache)
        self.assertIn("strict-cache:\n", action.split("\nruns:\n", 1)[0])
        save = next(step for step in steps if field(step, "name", indent=4) == "Save lane-specific Swift test build")
        self.assertIn("key: ${{ steps.build-key.outputs.key }}", save)
        # Every build step builds once more from nothing only through the retry
        # helper, which reads the matched key and this recipe's prefix.
        for step_id in ("provider-build", "cluster-build"):
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
        builds = ("provider-swift/.build", "libs/darkbloom-cluster/.build")
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
                self.assertEqual([Path(work, build).exists() for build in builds], [not retries] * len(builds))
                self.assertEqual("::warning title=Build cache::" in result.stdout, retries)

    def test_caches_of_the_fixed_path_jobs_survive_the_workspace_link(self):
        # actions/cache stores a path relative to the workspace and unpacks it
        # with `tar -C <workspace>`; under the link to /private/tmp/dinf, a
        # path sharing more than `/` with the workspace (runner.temp, the home
        # directory) lands elsewhere (run 42065297991: "../../_temp: Cannot
        # mkdir"). Their caches are in the workspace or in CI_CACHE_ROOT.
        blocks = [(job_id, step, 8) for job_id in (*BUILD_JOBS, *PRODUCT_JOBS) for step in step_blocks(self.jobs[job_id])]
        blocks += [(ACTION.name, step, 6) for step in step_blocks(ACTION.read_text(), indent=4)]
        paths = []
        for owner, step, indent in blocks:
            if "actions/cache/" not in step:
                continue
            lines = step.split(f"{' ' * indent}  path:", 1)[1].splitlines()
            value = lines[0].strip()
            entries = [value]
            if value == "|":
                block = itertools.takewhile(lambda line: line.startswith(" " * (indent + 4)), lines[1:])
                entries = [line.strip() for line in block]
            paths += [(owner, entry) for entry in entries]
        self.assertTrue(paths)
        for owner, path in paths:
            with self.subTest(owner=owner, path=path):
                self.assertNotRegex(path, r"runner\.temp|RUNNER_TEMP|^~|HOME|^\$\{\{")
                self.assertTrue(not path.startswith("/") or path.startswith(CI_CACHE_ROOT + "/"), path)
        # Each moved cache: the metallib, SwiftPM's repositories, the MiMo
        # downloads and codec and the prompt fixture downloads, restored and
        # saved at one path.
        self.assertEqual(sorted({path for _, path in paths if path.startswith(CI_CACHE_ROOT)}),
                         [CI_CACHE_ROOT + "/" + name for name in
                          ("metallib-cache", "mimo-audio-source", "mimo-metadata-cache", "prompt-fixture-cache",
                           "swiftpm-repositories")])
        self.assertIn("METALLIB_CACHE_DIR: " + CI_CACHE_ROOT + "/metallib-cache", ACTION.read_text())

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
            self.assertEqual(field(step, "path", indent=8), CI_CACHE_ROOT + "/swiftpm-repositories")
        # SwiftPM reads its repositories from the home directory, through a
        # link made before the restore and before either build.
        link = next(step for step in steps
                    if field(step, "name", indent=4) == "Link SwiftPM's repository cache into the CI cache directory")
        self.assertIn('ln -s /private/tmp/dinf-ci/swiftpm-repositories "$HOME/Library/Caches/org.swift.swiftpm/repositories"',
                      link)
        self.assertLess(steps.index(link), steps.index(restore))
        self.assertEqual(field(restore, "uses", indent=6), CACHE_RESTORE)
        self.assertEqual(field(restore, "key", indent=8),
                         prefix + "${{ hashFiles('**/Package.resolved', '!**/.build/**') }}")
        self.assertEqual(field(restore, "restore-keys", indent=8), prefix)
        self.assertLess(steps.index(restore), steps.index(by_id["provider-build"]))
        self.assertLess(steps.index(restore), steps.index(by_id["cluster-build"]))
        self.assertEqual(field(save, "uses", indent=6), CACHE_SAVE)
        self.assertEqual(field(save, "key", indent=8), "${{ steps.spm-repos.outputs.cache-primary-key }}")
        self.assertEqual(field(save, "if", indent=6),
                         gated("${{ !cancelled() && " + SAVE_INPUT + " && steps.timestamps.outcome == 'success' "
                               "&& steps.spm-repos.outputs.cache-hit != 'true' }}"))
        self.assertGreater(names.index("Save SwiftPM repositories"), names.index("Record timestamps for successfully built sources"))


    def test_every_cache_step_is_skipped_on_darkbloom_without_its_cache(self):
        # On a Darkbloom Sandbox the plane gave no Darkbloom cache, the guest
        # sets no DARKBLOOM_CACHE_URL and actions/cache would read and write
        # GitHub's own cache through the gateway (job 127018716621 saved .git
        # and a 1.69 GiB Swift build to refs/heads/master). Every cache step in
        # every workflow and action skips while CI_ACTIONS_CACHE is off; an
        # unset value keeps the cache, so the Blacksmith-only release jobs keep
        # theirs. Each routed job sets it first, before any cache step.
        github = ROOT / ".github"
        files = sorted([*github.glob("workflows/*.yml"), *github.glob("actions/*/action.yml")])
        cache_steps = 0
        for path in files:
            text = path.read_text()
            indent = 4 if path.name == "action.yml" else 6
            for step in step_blocks(text, indent=indent):
                if not re.search(r"(?m)^\s+(?:- )?uses: actions/cache(?:/restore|/save)?@", step):
                    continue
                cache_steps += 1
                condition = field(step, "if", indent=indent + 2)
                with self.subTest(file=path.name, step=field(step, "name", indent=indent)):
                    self.assertIsNotNone(condition)
                    self.assertTrue(condition.startswith(CACHE_GATE) or condition.startswith("${{ " + CACHE_GATE + " && "),
                                    condition)
        self.assertGreater(cache_steps, 30)
        cache_users = (BUILD_ACTION, "./.github/actions/provider-release-build")
        routed = []
        for path in sorted(github.glob("workflows/*.yml")):
            text = path.read_text()
            if "\njobs:\n" not in text:
                continue
            # A workflow that pins CI_ACTIONS_CACHE off at its top (the release
            # workflows) never uses a cache, so its routed jobs need no gate
            # step; nothing in it may turn the cache back on.
            code = re.sub(r"(?m)^\s*#.*\n", "", text)
            pinned_off = re.search(r"(?m)^env:\n(?:  \S.*\n)*?  CI_ACTIONS_CACHE: 'off'\n", code) is not None
            if pinned_off:
                self.assertEqual(code.count("CI_ACTIONS_CACHE"), 1, path.name)
            for job_id, job in job_blocks(text.split("\njobs:\n", 1)[1]).items():
                steps = step_blocks(job)
                users = [index for index, step in enumerate(steps)
                         if "actions/cache" in (uses(step) or "") or uses(step) in cache_users
                         or field(step, "cache", indent=10)]
                runs_on = field(job, "runs-on", indent=4) or ""
                if not users or "fromJSON(" not in runs_on:
                    # A job on a literal Blacksmith label never runs on Darkbloom.
                    self.assertTrue(not users or "darkbloom" not in runs_on, (path.name, job_id))
                    continue
                if pinned_off:
                    self.assertNotIn(CACHE_GATE_STEP, [field(step, "name", indent=6) for step in steps])
                    continue
                routed.append(job_id)
                with self.subTest(workflow=path.name, job=job_id):
                    names = [field(step, "name", indent=6) for step in steps]
                    self.assertEqual(names.count(CACHE_GATE_STEP), 1)
                    gate = steps[names.index(CACHE_GATE_STEP)]
                    self.assertEqual(run_command(gate), CACHE_GATE_RUN)
                    self.assertIsNone(field(gate, "if"))
                    self.assertLess(names.index(CACHE_GATE_STEP), users[0])
                    for index in users:
                        setup_cache = field(steps[index], "cache", indent=10)
                        if setup_cache:
                            self.assertEqual(setup_cache, "${{ " + CACHE_GATE + " && 'npm' || '' }}")
        # At least these; Cluster GPU Tests is routed only where its shards ask.
        self.assertLessEqual({"release-integrity", "docs", "frontend", "desktop-package", "check", "warm", *BUILD_JOBS,
                              "test-provider", GATES, "test-cluster", "cluster-release-checks", "test-cluster-focused"},
                             set(routed))
        # The step itself: off only on a Darkbloom runner without the guest's
        # cache URL.
        for runner, cache_url, off in (("darkbloom-41", "", True), ("darkbloom-41", "http://127.0.0.1:3129/", False),
                                       ("blacksmith-4vcpu-ubuntu-2404-abc", "", False),
                                       ("GitHub Actions 7", "", False), ("", "", False)):
            with self.subTest(runner=runner, cache_url=cache_url), tempfile.TemporaryDirectory() as work:
                env_file = Path(work, "env")
                env_file.touch()
                env = {"PATH": os.environ["PATH"], "GITHUB_ENV": str(env_file), "RUNNER_NAME": runner}
                if cache_url:
                    env["DARKBLOOM_CACHE_URL"] = cache_url
                result = subprocess.run(["bash", "-e", "-c", CACHE_GATE_RUN], env=env,
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(env_file.read_text(), "CI_ACTIONS_CACHE=off\n" if off else "")
                self.assertEqual("::notice title=Actions cache::" in result.stdout, off)

if __name__ == "__main__":
    unittest.main()
