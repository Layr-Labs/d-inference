"""CPU characterization of the existing launcher, receipts, and report oracle.

Set MTP_BENCHMARK_MODULE to a saved pre-refactor launcher to run the same
assertions against it. No Swift process or model is started by these tests.
"""
from __future__ import annotations

import argparse
import contextlib
from copy import deepcopy
from datetime import datetime, timezone
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import Mock, patch

SCRIPT = Path(__file__).resolve().parents[2] / "run-mtp-benchmark.py"
spec = importlib.util.spec_from_file_location(
    "mtp_launcher_under_test", os.environ.get("MTP_BENCHMARK_MODULE", SCRIPT)
)
launcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launcher)


def zero_metrics():
    return dict(active=False, rounds=0, seedRows=0, proposedTokens=0,
                acceptedDraftTokens=0, committedTokens=0,
                acceptanceByPosition=[], conditionalAcceptance=[], skippedRows={},
                depthSelections={}, controllerFallbacks={}, costInputs=[])


def report_fixture(mode="raw-parity", inactive=False):
    timestamp = datetime.now(timezone.utc).isoformat()
    expected = dict(modelID="example/qat", resolvedPath="/cache/model", revision=None,
                    configSizeBytes=1, configSHA256="a" * 64, weightFiles=[],
                    artifactFingerprint="b" * 64,
                    configMetadata=dict(model_type="gemma4_text", dtype="float16",
                                        effective_quantization_bits=4, has_quantization=True))
    artifact = {key: value for key, value in expected.items() if key != "configMetadata"}
    artifact.update(modelType="gemma4_text", dtype="float16", quantization={"bits": 4})
    expectation = launcher.expected_mtp_expectation(inactive)
    report = dict(schemaVersion=5, runFingerprint=f"release:{expectation['kind']}:launch",
                  buildConfiguration="release", mtpExpectation=expectation, complete=True,
                  expectedCaseCount=40, maxTokensPerRow=16, warmupIterations=0,
                  measurementRepetitions=1, modeOrderSeed=123,
                  target=artifact, assistant=deepcopy(artifact),
                  purpose="raw_parity_stress" if mode == "raw-parity" else "production_performance",
                  stopPolicy=dict(kind="raw_fixed_length_no_stop" if mode == "raw-parity"
                                  else "production_target_eos",
                                  configuredTokenCount=0 if mode == "raw-parity" else 2),
                  startedAt=timestamp, generatedAt=timestamp, completedAt=timestamp, cases=[])
    for kind, widths in (("target_only", [None]), ("fixed", range(1, 9)), ("adaptive", [None])):
        for width in widths:
            for batch in (1, 2, 4, 8):
                metrics = zero_metrics()
                if kind != "target_only":
                    if inactive:
                        metrics["inactiveReason"] = launcher.LEGACY_M5_INACTIVE_REASON_PREFIX + ": fixture"
                    else:
                        depth = width - 1 if kind == "fixed" else 2
                        metrics.update(active=True, decodeRowBucket=batch,
                                       depthSelections={str(depth): 1},
                                       rounds=int(depth > 0), proposedTokens=depth,
                                       verificationMode="automatic", maxAutomaticRectangularTokens=128,
                                       costInputs=[dict(decodeRowBucket=batch, draftDepth=depth, sampleCount=1)])
                case = dict(mode=dict(kind=kind, verificationWidth=width), batchSize=batch,
                            measurementRepetitions=1, tokenParity=True, parityMismatchRows=[],
                            rows=[dict(promptName=f"row-{index}", tokenCount=16,
                                       opaqueTokenDigest=f"{index:064x}", finishReason="length")
                                  for index in range(batch)], metrics=metrics)
                if mode != "raw-parity":
                    case["medianAggregateDecodeTokensPerSecond"] = 20.0
                report["cases"].append(case)
    if mode != "raw-parity":
        report["elapsedMs"] = 100.0
    report["coverage"] = launcher.expected_coverage(report)
    return report, expected


class ReportContractTests(unittest.TestCase):
    def validate(self, report, artifact, mode="raw-parity", inactive=False):
        run = launcher.SecureRunDirectory.create(Path(tempfile.gettempdir()) / "mtp-oracle-test.json")
        try:
            run.atomic_write(launcher.REPORT_NAME, json.dumps(report).encode())
            launcher.validate_report(
                run, fingerprint="launch", launch_time=time.time() - 2, mode=mode,
                build_configuration="release", target=artifact, assistant=artifact,
                max_tokens=16, warmup=0, repetitions=1, seed=123, expect_mtp_inactive=inactive)
        finally:
            run.close()
            for child in run.path.iterdir():
                child.unlink()
            run.path.rmdir()

    def test_complete_matrix_modes(self):
        for mode, inactive in (("raw-parity", False), ("raw-parity", True),
                               ("production-performance", False)):
            with self.subTest(mode=mode, inactive=inactive):
                self.validate(*report_fixture(mode, inactive), mode=mode, inactive=inactive)

    def test_exact_failure_contract(self):
        mutations = [
            (lambda r: r.update(complete=False), "report is only a partial checkpoint"),
            (lambda r: r.update(runFingerprint="stale"), "run fingerprint does not match this launch"),
            (lambda r: r["target"].update(dtype="bf16"), "report target dtype does not match launch config.json"),
            (lambda r: r.update(extra={"tokenIDs": [1]}), "report recursively exposes raw token IDs"),
            (lambda r: r.update(extra={"elapsedMs": 1}), "non-performance report recursively exposes performance keys: ['elapsedMs']"),
            (lambda r: r["cases"][4]["rows"][0].update(opaqueTokenDigest="f" * 64), "case fixed/1/B1 opaque evidence differs from baseline"),
            (lambda r: r["cases"][4]["metrics"].update(active=False), "fixed L1/B1 did not prove activation"),
            (lambda r: r["cases"][36]["metrics"].update(active=False), "adaptive B1 did not prove activation/bucket"),
            (lambda r: r["cases"][0]["metrics"].update(rounds=1), "target-only B1 reported speculative work in rounds"),
            (lambda r: r["coverage"].update(toolTemplateDecodeParity="covered"), "coverage.toolTemplateDecodeParity is not dynamically labeled not_in_this_report"),
        ]
        for mutate, message in mutations:
            with self.subTest(message=message):
                report, artifact = report_fixture()
                mutate(report)
                with self.assertRaises(ValueError) as caught:
                    self.validate(report, artifact)
                self.assertEqual(str(caught.exception), message)

    def test_inactive_and_automatic_failure_order(self):
        for index, label in ((4, "fixed L1/B1"), (36, "adaptive B1")):
            for change, suffix in (({"active": True}, "unexpectedly reported MTP active"),
                                   ({"inactiveReason": "other"}, "inactive reason is not allowed"),
                                   ({"rounds": 1}, "expected-inactive reported speculative work in rounds")):
                with self.subTest(index=index, change=change):
                    report, artifact = report_fixture(inactive=True)
                    report["cases"][index]["metrics"].update(change)
                    with self.assertRaises(ValueError) as caught:
                        self.validate(report, artifact, inactive=True)
                    self.assertEqual(str(caught.exception), f"{label} {suffix}")
            report, artifact = report_fixture("production-performance")
            report["cases"][index]["metrics"].update(verificationMode="serial")
            with self.assertRaises(ValueError) as caught:
                self.validate(report, artifact, mode="production-performance")
            self.assertEqual(str(caught.exception), f"{label} production evidence requires the automatic verifier")

    def test_automatic_zero_fit_evidence(self):
        metrics = zero_metrics()
        metrics.update(active=True, verificationMode="automatic", maxAutomaticRectangularTokens=0,
                       selectedDepth=0, depthSelections={"0": 1},
                       controllerFallbacks={"automatic_rectangular_limit": 1})
        self.assertTrue(launcher.validate_automatic_fixed_fallback(metrics, 8, 2, "fixed"))
        metrics["assistantTimeNanos"] = 1
        with self.assertRaisesRegex(ValueError, "^fixed reported uncategorized work$"):
            launcher.validate_automatic_fixed_fallback(metrics, 8, 2, "fixed")


class LauncherContractTests(unittest.TestCase):
    def test_existing_cpu_self_tests(self):
        with contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(launcher.self_test_output_safety(), 0)
            self.assertEqual(launcher.self_test_artifact_provenance(), 0)
        self.assertEqual(output.getvalue(), "secure output symlink-replacement self-test passed\n"
                         "artifact provenance symlink self-test passed\n")

    def test_secure_directory_identity_and_read_bounds(self):
        run = launcher.SecureRunDirectory.create(Path(tempfile.gettempdir()) / "mtp-security-test.json")
        try:
            run.atomic_write("proof.json", b"1234")
            with self.assertRaisesRegex(ValueError, "proof.json size is invalid: 4"):
                run.read_regular("proof.json", 3)
            with self.assertRaisesRegex(SystemExit, "benchmark run directory identity changed"):
                launcher.SecureRunDirectory.reopen(run.path, run.device, run.inode + 1)
            with self.assertRaisesRegex(ValueError, "invalid run-directory filename"):
                run.create_file("../escape")
        finally:
            run.close()
            (run.path / "proof.json").unlink()
            run.path.rmdir()

    def test_cli_validation_does_not_launch(self):
        cases = [(["--mode", "production-performance", "--debug"], "production-performance mode requires a release build"),
                 (["--mode", "production-performance", "--expect-mtp-inactive"], "production-performance mode rejects --expect-mtp-inactive"),
                 (["--_worker-log-fd", "3"], "incomplete internal worker contract"),
                 (["--warmup", "-1"], "--warmup must be nonnegative and --repetitions positive")]
        for arguments, message in cases:
            with self.subTest(arguments=arguments), patch.object(launcher.sys, "argv", ["run-mtp-benchmark.py", *arguments]), patch.object(launcher.subprocess, "Popen") as popen, contextlib.redirect_stderr(io.StringIO()) as output:
                with self.assertRaises(SystemExit) as caught:
                    launcher.main()
                self.assertIn(message, output.getvalue() + str(caught.exception))
                popen.assert_not_called()

    def test_supervisor_preserves_command_manifest_and_cleanup(self):
        args = argparse.Namespace(output=Path(tempfile.gettempdir()) / "mtp-supervisor-test.json",
                                  debug=False, mode="raw-parity", expect_mtp_inactive=False,
                                  test_filter=launcher.DEFAULT_TEST_FILTER, timeout_seconds=7)
        process = Mock()
        process.wait.return_value = 9
        with patch.object(launcher.subprocess, "Popen", return_value=process) as popen, patch.object(launcher, "terminate_group") as terminate, patch.object(launcher.sys, "argv", ["run-mtp-benchmark.py", "--timeout-seconds", "7"]):
            result = launcher.supervisor_main(args, 0, 1)
        command = popen.call_args.args[0]
        path = Path(command[command.index("--_worker-run-directory") + 1])
        try:
            self.assertEqual(result, 9)
            self.assertEqual(command[2:4], ["--timeout-seconds", "7"])
            self.assertTrue(popen.call_args.kwargs["start_new_session"])
            self.assertEqual(len(popen.call_args.kwargs["pass_fds"]), 1)
            process.wait.assert_called_once_with(timeout=7)
            terminate.assert_called_once_with(process)
            manifest = json.loads((path / "run.json").read_text())
            self.assertEqual(manifest["timeout_seconds"], 7)
            self.assertEqual(manifest["mtp_expectation"], launcher.expected_mtp_expectation(False))
            self.assertEqual(set(p.name for p in path.iterdir()), {"run.json", "benchmark.log"})
        finally:
            for child in path.iterdir():
                child.unlink()
            path.rmdir()


if __name__ == "__main__":
    unittest.main()
