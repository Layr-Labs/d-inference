import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from gptoss_profile.control_design import load_design, schedule
from gptoss_profile.control_report import summarize_controls
from gptoss_profile.control_metrics import row_latencies
from gptoss_profile.controls import execute_controls
from gptoss_profile.provenance import digest, model_pin, write_json
from gptoss_profile.tests.test_integrity import fixture


HIGH = {"power": {"source": "AC Power", "acPowerMode": 2},
        "foundationThermalState": {"value": 1, "name": "fair"}}


def make_design(root):
    binary = root / "binary"
    binary.write_text("fixture executable")
    binary.chmod(0o700)
    (root / "mlx.metallib").write_text("fixture library")
    (root / "receipt.json").write_text('{}')
    model = root / "model"
    model.mkdir()
    (model / "weights.safetensors").write_bytes(b"fixture weights")
    data = {"schemaVersion": 1, "modelID": "test-model", "modelDirectory": "model", "decodeTokens": 64,
            "arms": [{"name": arm, "label": f"B{batch}", "binary": "binary", "metallib": "mlx.metallib",
                      "buildRecord": "receipt.json", "cell": {"context": 512, "batch": batch}}
                     for arm, batch in (("A", 2), ("B", 4))]}
    path = root / "design.json"
    write_json(path, data)
    return path


def fake_run(command, cwd, environment, directory, timeout, required_ac_power_mode):
    spec = json.loads((directory / "spec.json").read_text())
    _, _, report = fixture(spec["cell"]["batch"])
    report["modelPath"] = str(directory.parents[2] / "model")
    write_json(directory / "stdout.raw", report)
    write_json(directory / "process.json", {"returncode": 0, "command": command})
    write_json(directory / "host-before.json", HIGH)
    write_json(directory / "host-after.json", HIGH)
    return {"returncode": 0}


class ControlTests(unittest.TestCase):
    def test_prefill_design_requires_matched_single_request_phase(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = make_design(Path(tmp))
            raw = json.loads(path.read_text())
            for arm in raw["arms"]:
                arm["cell"] = {"phase": "prefill", "context": 8192}
            write_json(path, raw)
            design = load_design(path)
            self.assertEqual(design["arms"][0]["cell"]["batch"], 1)
            self.assertEqual(design["arms"][1]["cell"]["name"], "prefill-8192")
            raw["arms"][1]["cell"]["batch"] = 2
            write_json(path, raw)
            with self.assertRaisesRegex(ValueError, "Prefill requires"):
                load_design(path)
            raw["arms"][1]["cell"] = {"phase": "decode", "context": 8192, "batch": 1}
            write_json(path, raw)
            with self.assertRaisesRegex(ValueError, "share phase"):
                load_design(path)

    def test_prefill_abba_reports_paired_ttft_without_invented_token_parity(self):
        with tempfile.TemporaryDirectory() as tmp, contextlib.redirect_stdout(io.StringIO()):
            root = Path(tmp)
            path = make_design(root)
            raw = json.loads(path.read_text())
            for arm in raw["arms"]:
                arm["cell"] = {"phase": "prefill", "context": 8192}
            write_json(path, raw)
            output = root / "result"

            def prefill_run(command, cwd, environment, directory, timeout, required_ac_power_mode):
                spec = json.loads((directory / "spec.json").read_text())
                ttft = 400 if spec["control"]["arm"] == "A" else 200
                report = {"schemaVersion": 4, "modelID": "test-model", "modelPath": str(root / "model"),
                          "kvBackend": {"selection": "contiguous", "resolved": ["contiguous"]},
                          "promptLengths": [8192], "iterations": 1,
                          "samples": [{"promptTokens": 8192, "iteration": 1, "ttftMs": ttft,
                                       "peakMemoryBytes": 1024, "resolvedKVBackend": "contiguous"}]}
                write_json(directory / "stdout.raw", report)
                write_json(directory / "process.json", {"returncode": 0, "command": command})
                write_json(directory / "host-before.json", HIGH)
                write_json(directory / "host-after.json", HIGH)
                return {"returncode": 0}

            with patch("gptoss_profile.controls.source_pin", return_value={}), \
                    patch("gptoss_profile.controls.host_snapshot", return_value=HIGH), \
                    patch("gptoss_profile.controls.run", side_effect=prefill_run) as launch:
                self.assertEqual(execute_controls(path, output, cycles=1), 0)
                self.assertEqual(launch.call_count, 4)
                for invocation in launch.call_args_list:
                    self.assertIn("--scheduler-prefill", invocation.args[0])
                    self.assertNotIn("--sweep", invocation.args[0])
                    self.assertNotIn("--decode-tokens", invocation.args[0])
            report = json.loads((output / "comparison.json").read_text())
            self.assertEqual(report["primaryMetric"], "ttftMedianMs")
            self.assertIsNone(report["tokenParityPassed"])
            self.assertEqual(report["tokenParityStatus"], "not_available_prefill_report")
            self.assertTrue(report["validForPerformanceComparison"])
            self.assertNotIn("aggregateDecodeTPS", report["arms"]["A"])
            self.assertNotIn("batchEndToEndMs", report["arms"]["A"])
            cycle = report["cycleComparisons"][0]
            self.assertEqual(cycle["ratioBOverA"], .5)
            self.assertEqual(cycle["metrics"]["ttftMedianMs"]["improvementPercent"], 50)
            self.assertEqual(report["arms"]["B"]["promptTokensPerSecond"]["median"], 40960)
            self.assertIn("not a correctness verdict", report["latency"])

    def test_abba_order_and_design_controls(self):
        self.assertEqual([run["arm"] for run in schedule(3)], list("ABBAABBAABBA"))
        with tempfile.TemporaryDirectory() as tmp:
            path = make_design(Path(tmp))
            design = load_design(path)
            self.assertEqual(design["arms"][0]["environment"]["DARKBLOOM_PREFIX_CACHE"], "0")
            raw = json.loads(path.read_text())
            raw["arms"][1]["environment"] = {"MLX_TRACE_ENABLED": "1"}
            write_json(path, raw)
            with self.assertRaisesRegex(ValueError, "instrumentation disabled"):
                load_design(path)
            raw["arms"][1]["environment"] = {}
            raw["arms"][1]["cell"]["context"] = 8192
            write_json(path, raw)
            with self.assertRaisesRegex(ValueError, "share context"):
                load_design(path)

    def test_model_hashed_once_12_fresh_runs_and_cycle_ratios(self):
        with tempfile.TemporaryDirectory() as tmp, contextlib.redirect_stdout(io.StringIO()):
            root = Path(tmp)
            design = make_design(root)
            output = root / "result"
            with patch("gptoss_profile.controls.source_pin", return_value={}), \
                    patch("gptoss_profile.controls.host_snapshot", return_value=HIGH), \
                    patch("gptoss_profile.controls.model_pin", wraps=model_pin) as pin, \
                    patch("gptoss_profile.controls.run", side_effect=fake_run) as launch:
                self.assertEqual(execute_controls(design, output, cycles=3), 0)
                self.assertEqual(pin.call_count, 1)
                self.assertEqual(launch.call_count, 12)
                self.assertEqual([call.args[3].name[-1] for call in launch.call_args_list], list("ABBAABBAABBA"))
            report = json.loads((output / "comparison.json").read_text())
            self.assertTrue(report["validForPerformanceComparison"])
            self.assertEqual(report["comparisonKind"], "batch-scaling")
            self.assertEqual([cycle["ratioBOverA"] for cycle in report["cycleComparisons"]], [2, 2, 2])
            self.assertEqual(report["arms"]["A"]["runs"], 6)
            self.assertEqual(report["arms"]["A"]["rowTTFTMs"]["median"], 100)
            self.assertEqual(report["arms"]["A"]["rowEndToEndMs"]["median"], 165)
            self.assertEqual(report["cycleComparisons"][0]["metrics"]["ttftMedianMs"]["direction"], "lower_is_better")
            self.assertEqual(report["cycleComparisons"][0]["metrics"]["aggregateDecodeTPS"]["direction"], "higher_is_better")
            self.assertEqual(report["cycleComparisons"][0]["distributionsByArm"]["B"]["peakMemoryBytes"]["median"], 1000)
            self.assertTrue((output / "comparison.csv").exists())

    def test_row_latency_uses_each_submission_and_batch_extrema(self):
        rows = [{"row": 0, "submittedAtMs": 0, "tokenArrivalMs": [10, 25], "finishedAtMs": 30},
                {"row": 1, "submittedAtMs": 3, "tokenArrivalMs": [20, 35], "finishedAtMs": 40}]
        metrics = row_latencies(rows)
        self.assertEqual(metrics["rowTTFTMs"], [10, 17])
        self.assertEqual(metrics["ttftMedianMs"], 13.5)
        self.assertEqual(metrics["rowEndToEndMs"], [30, 37])
        self.assertEqual(metrics["endToEndMedianMs"], 33.5)
        self.assertEqual(metrics["batchEndToEndMs"], 40)
        rows[1]["finishedAtMs"] = 34
        with self.assertRaisesRegex(ValueError, "precede"):
            row_latencies(rows)

    def test_comparison_rejects_output_parity_failure_and_changed_power(self):
        with tempfile.TemporaryDirectory() as tmp, contextlib.redirect_stdout(io.StringIO()):
            root = Path(tmp)
            design = make_design(root)
            output = root / "result"
            with patch("gptoss_profile.controls.source_pin", return_value={}), \
                    patch("gptoss_profile.controls.host_snapshot", return_value=HIGH), \
                    patch("gptoss_profile.controls.run", side_effect=fake_run):
                self.assertEqual(execute_controls(design, output, cycles=1), 0)
            run = output / "runs" / "cycle-01-2-B"
            raw = json.loads((run / "stdout.raw").read_text())
            raw["decode"][0]["decodeTiming"]["rows"][0]["tokenIDs"][4] = 999
            write_json(run / "stdout.raw", raw)
            write_json(run / "validation.json", {"valid": True, "rawSHA256": digest(run / "stdout.raw")})
            report = summarize_controls(output)
            self.assertTrue(report["complete"])
            self.assertFalse(report["tokenParityPassed"])
            self.assertFalse(report["validForPerformanceComparison"])
            write_json(run / "host-after.json", {"power": {"source": "AC Power", "acPowerMode": 1}})
            report = summarize_controls(output)
            self.assertFalse(report["complete"])
            self.assertIn("after power invalid", report["failures"][0]["error"])


if __name__ == "__main__":
    unittest.main()
