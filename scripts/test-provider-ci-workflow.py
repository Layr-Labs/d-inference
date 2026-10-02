#!/usr/bin/env python3
"""Offline CI lane/gate checks; actionlint validates the complete YAML syntax."""

from collections import Counter
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = ROOT / ".github/workflows/ci.yml"
ACTION = ROOT / ".github/actions/provider-ci-build/action.yml"
BUILD_ACTION = "./.github/actions/provider-ci-build"
READY = "${{ !cancelled() && steps.provider-ci-build.outcome == 'success' }}"
MIMO_READY = "${{ !cancelled() && steps.provider-ci-build.outcome == 'success' && steps.mimo-fixtures.outcome == 'success' }}"
PROVIDER_MIMO_READY = "${{ !cancelled() && steps.provider-ci-build.outcome == 'success' && steps.mimo-prompt-fixtures.outcome == 'success' && steps.mimo-fixtures.outcome == 'success' }}"
MIMO_PREPARE = ('python3 scripts/prepare-mimo-prompt-fixtures.py '
                '--output "$RUNNER_TEMP/mimo-prompt-fixtures" --github-env "$GITHUB_ENV"')
MIMO_PROVIDER_PREPARE = ('python3 scripts/prepare-mimo-provider-fixtures.py '
                         '--output "$RUNNER_TEMP/mimo-provider-fixtures" --github-env "$GITHUB_ENV"\n'
                         'python3 scripts/prepare-mimo-provider-fixtures.py '
                         '--output "$RUNNER_TEMP/mimo-prefix-fixtures" --asymmetric')
SDK_MIMO_PREPARE_NAME = "Prepare tiny MiMo fixture for media-to-text isolation"
SDK_MIMO_GATE_NAME = "Verify media refusal leaves the native text engine usable"
SDK_MIMO_READY = "${{ !cancelled() && steps.provider-ci-build.outcome == 'success' && steps.sdk-mimo-isolation-fixture.outcome == 'success' }}"
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
}
LANES = {
    "test-provider": "provider",
    "test-provider-sdk": "sdk",
    "test-provider-parity": "parity",
}
SDK_COMMANDS = {
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
                self.assertIn("    runs-on: blacksmith-12vcpu-macos-27", job)
                self.assertNotRegex(job, re.compile(r"^    (needs|if|strategy):", re.MULTILINE), msg=job)
                self.assertNotIn("continue-on-error:", job)
                self.assertNotIn("DARKBLOOM_EXCLUSIVE_NATIVE_GPU_TEST:", job)
        self.assertIn("    name: Provider Unit Tests\n", self.jobs["test-provider"])

    def test_existing_required_check_requires_every_lane_even_after_failures(self):
        job = self.jobs["provider-test-gate"]
        self.assertIn("    name: Provider Tests\n", job)
        self.assertIn("    needs: [test-provider, test-provider-sdk, test-provider-parity]\n", job)
        self.assertIn("    if: ${{ always() }}\n", job)
        self.assertNotIn("continue-on-error:", job)
        step = step_blocks(job)[0]
        command = run_command(step)
        for unit, sdk, parity in (("success", "success", "success"),
                                  ("failure", "success", "success"),
                                  ("success", "failure", "success"),
                                  ("success", "success", "failure"),
                                  ("skipped", "success", "success"),
                                  ("success", "cancelled", "success")):
            result = subprocess.run(["bash", "-e", "-c", command],
                                    env={**os.environ, "UNIT_RESULT": unit,
                                         "SDK_RESULT": sdk, "PARITY_RESULT": parity},
                                    capture_output=True, timeout=5)
            self.assertEqual(result.returncode == 0, unit == sdk == parity == "success")

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

    def test_provider_entrypoint_and_resource_installer_checks_are_retained(self):
        steps = step_blocks(self.jobs["test-provider"])
        expected = (
            "python3 scripts/test-qwen4-packaged-resources.py",
            "python3 scripts/test-profile-inventory-auth.py",
            MIMO_PREPARE,
            MIMO_PROVIDER_PREPARE,
            "../scripts/run-provider-tests.sh",
            *MIMO_NATIVE_COMMANDS.values(),
            'python3 scripts/prepare-mimo-audio-fixtures.py --cache "$RUNNER_TEMP/mimo-audio-source" --output "$RUNNER_TEMP/mimo-audio-fixtures" --github-env "$GITHUB_ENV"',
            "../scripts/run-nested-suite.sh testNativeAudioRelease --no-parallel",
            "./scripts/test-install-atomic.sh",
        )
        self.assertEqual([run_command(step) for step in steps if field(step, "run")], list(expected))
        test_step = next(step for step in steps if run_command(step) == "../scripts/run-provider-tests.sh")
        self.assertEqual(field(test_step, "working-directory"), "provider-swift")
        self.assertEqual(field(test_step, "if"), PROVIDER_MIMO_READY)
        self.assertEqual(field(test_step, "MIMO_V26_PROVIDER_LIFETIME_METADATA_TESTS", indent=10), "'1'")
        installer = next(step for step in steps if run_command(step) == "./scripts/test-install-atomic.sh")
        self.assertEqual(field(installer, "if"), "${{ !cancelled() }}")
        self.assertEqual(field(installer, "timeout-minutes"), "2")
        self.assertNotIn("rustup", self.jobs["test-provider"])
        self.assertNotIn("actions/setup-go@", self.jobs["test-provider"])

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
        for step in step_blocks(self.jobs["test-provider-sdk"]):
            if field(step, "run"):
                with self.subTest(gate=field(step, "name", indent=6)):
                    name = field(step, "name", indent=6)
                    self.assertEqual(field(step, "if"), SDK_MIMO_READY if name == SDK_MIMO_GATE_NAME else READY)
                    expected_directory = None if name == SDK_MIMO_PREPARE_NAME else "libs/mlx-swift-lm"
                    self.assertEqual(field(step, "working-directory"), expected_directory)
                    self.assertNotIn("continue-on-error:", step)

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
        self.assertEqual(commands["../scripts/run-provider-tests.sh"], 1)
        self.assertEqual(commands["./scripts/verify-prompt-parity.sh"], 1)

    def test_parity_retains_pinned_go_and_original_script(self):
        steps = step_blocks(self.jobs["test-provider-parity"])
        go = [step for step in steps if "actions/setup-go@" in step]
        self.assertEqual(len(go), 1)
        self.assertIn("actions/setup-go@f111f3307d8850f501ac008e886eec1fd1932a34", go[0])
        self.assertEqual(field(go[0], "go-version-file", indent=10), "go.mod")
        runs = [step for step in steps if field(step, "run")]
        self.assertEqual([run_command(step) for step in runs],
                         [MIMO_PREPARE, "./scripts/verify-prompt-parity.sh",
                          "./scripts/verify-nemotron-prompt-parity.sh"])
        self.assertEqual(field(runs[-2], "if"), MIMO_READY)
        self.assertEqual(field(runs[-1], "if"), READY)

    def test_fixture_prerequisites_are_fail_closed_in_provider_and_parity(self):
        for job_id in ("test-provider", "test-provider-parity"):
            steps = step_blocks(self.jobs[job_id])
            fixtures = [step for step in steps if run_command(step) == MIMO_PREPARE]
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

    def test_audio_qualification_uses_real_codec_and_no_skip_gate(self):
        steps = step_blocks(self.jobs["test-provider"])
        fixture = next(s for s in steps if field(s, "id") == "mimo-audio-fixtures")
        self.assertIn("prepare-mimo-audio-fixtures.py", run_command(fixture))
        self.assertEqual(field(fixture, "if"), READY)
        gate = next(s for s in steps if field(s, "name", indent=6) == "Run isolated native MiMo audio gate")
        self.assertIn("testNativeAudioRelease", run_command(gate))
        self.assertIn("run-nested-suite.sh", run_command(gate))
        self.assertIn("steps.mimo-audio-fixtures.outcome == 'success'", field(gate, "if"))
        self.assertEqual(field(gate, "MIMO_V26_MANAGED_AUDIO_PROVIDER_TESTS", indent=10), "'1'")
        self.assertNotIn("continue-on-error:", gate)

    def test_rust_cache_is_saved_only_after_successful_parity(self):
        steps = step_blocks(self.jobs["test-provider-parity"])
        parity = next(step for step in steps if run_command(step) == "./scripts/verify-prompt-parity.sh")
        saves = [step for step in steps if "actions/cache/save@" in step]
        self.assertEqual(len(saves), 1)
        self.assertEqual(field(parity, "id"), "prompt-parity")
        self.assertGreater(steps.index(saves[0]), steps.index(parity))
        self.assertEqual(field(saves[0], "if"), "${{ !cancelled() && steps.prompt-parity.outcome == 'success' && steps.provider-ci-build.outputs.rust-cache-hit != 'true' }}")
        self.assertIn("key: ${{ steps.provider-ci-build.outputs.rust-key }}", saves[0])
        for path in ("~/.cargo/registry", "~/.cargo/git/db", "coordinator/promptsidecar/target"):
            self.assertIn(path, saves[0])

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
        self.assertIn("python3 scripts/test-provider-ci-cache.py", self.jobs["release-integrity"])
        self.assertIn("python3 scripts/test-provider-ci-workflow.py", self.jobs["release-integrity"])
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

    def test_composite_cache_keys_and_rust_work_stay_in_their_lanes(self):
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
        self.assertEqual(len(rust_steps), 3)
        for step in rust_steps:
            self.assertEqual(field(step, "if", indent=6), "inputs.lane == 'parity'")
        self.assertIn("rust-key:", action)
        self.assertIn("rust-cache-hit:", action)
        self.assertEqual(sum("actions/cache/save@" in step for step in steps), 2)


if __name__ == "__main__":
    unittest.main()
