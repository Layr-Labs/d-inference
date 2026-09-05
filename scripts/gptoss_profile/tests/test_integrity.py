import copy
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from gptoss_profile.config import Cell, cells, command, environment
from gptoss_profile.process import run
from gptoss_profile.provenance import write_json
from gptoss_profile.runner import execute, parser
from gptoss_profile.power import parse_power, power_failure
from gptoss_profile.summary import summarize, summarize_cell
from gptoss_profile.validation import validate


def fixture(batch=2):
    spec = {"cell": Cell("decode", 512, batch).record(), "iterations": 1,
            "decodeTokens": 64, "backend": "contiguous", "provenanceID": "pin"}
    manifest = {"modelID": "test-model", "model": {"path": "/tmp/model"},
                "mode": "measurement", "provenanceID": "pin"}
    rows = [{"row": i, "tokenIDs": list(range(65)), "tokenArrivalMs": list(range(100, 165)),
             "submittedAtMs": 0, "finishedAtMs": 165, "finishReason": "length"} for i in range(batch)]
    timing = {"rows": rows, "decodePromptTokens": 512, "peakMemoryBytes": 1000, "endToEndTokensPerSecond": 700,
              "overlapAggregateTokensPerSecond": 1000 * batch, "overlapDurationMs": 64,
              "overlapDecodedTokensPerRow": [64] * batch, "overlapDecodedTokens": 64 * batch,
              "overlapMeetsMinimumSupport": True}
    report = {"schemaVersion": 6, "modelID": "test-model", "modelPath": "/tmp/model",
              "kvBackend": {"selection": "contiguous", "resolved": ["contiguous"]},
              "decodeCoverage": {"requestedBatchSizes": [batch], "unmeasured": []},
              "decode": [{"batchSize": batch, "decodeTokensPerSequence": 64,
                          "resolvedKVBackend": "contiguous", "aggregateTokensPerSecond": 900,
                          "decodeTiming": timing}]}
    return spec, manifest, report


class IntegrityTests(unittest.TestCase):
    def test_rejects_partial_batch_and_tiny_overlap(self):
        spec, manifest, report = fixture()
        validate(report, spec, manifest)
        invalid = copy.deepcopy(report)
        invalid["decode"][0]["decodeTiming"]["rows"].pop()
        with self.assertRaisesRegex(ValueError, "Missing decode rows"):
            validate(invalid, spec, manifest)
        report["decode"][0]["decodeTiming"]["overlapMeetsMinimumSupport"] = False
        with self.assertRaisesRegex(ValueError, "too few tokens"):
            validate(report, spec, manifest)

    def test_rejects_early_finish_and_backend_fallback(self):
        spec, manifest, report = fixture()
        report["decode"][0]["decodeTiming"]["rows"][0]["tokenIDs"].pop()
        with self.assertRaisesRegex(ValueError, "stopped early"):
            validate(report, spec, manifest)
        spec, manifest, report = fixture()
        report["kvBackend"]["resolved"] = ["contiguous (fallback: no memory)"]
        with self.assertRaisesRegex(ValueError, "Resolved KV"):
            validate(report, spec, manifest)

    def test_headline_uses_common_window_not_legacy(self):
        spec, _, report = fixture()
        row = summarize_cell(report, spec)
        self.assertEqual(row["aggregateDecodeTPS"], 2000)
        self.assertEqual(row["perRequestDecodeTPS"], 1000)
        self.assertEqual(row["legacyWholeRowAggregateTPS"], 900)

    def test_raw_timing_and_provenance_must_match_summary(self):
        spec, manifest, report = fixture()
        report["decode"][0]["decodeTiming"]["overlapAggregateTokensPerSecond"] = 9999
        with self.assertRaisesRegex(ValueError, "throughput disagrees"):
            validate(report, spec, manifest)
        spec["provenanceID"] = "different-binary"
        with self.assertRaisesRegex(ValueError, "provenance differs"):
            validate(report, spec, manifest)

    def test_environment_discards_unrecorded_experiments(self):
        child, controls = environment({"PATH": "/bin", "SECRET": "do-not-record", "MLX_FOO": "1", "DARKBLOOM_PREFIX_CACHE": "1"})
        self.assertNotIn("MLX_FOO", child)
        self.assertNotIn("SECRET", controls)
        self.assertEqual(child["DARKBLOOM_PREFIX_CACHE"], "0")
        with self.assertRaisesRegex(ValueError, "must remain disabled"):
            environment({}, ["DARKBLOOM_CBV2_MTP=1"])

    def test_matrix_includes_b2_b4_and_mixed_arrival(self):
        self.assertEqual(len(cells("decode")), 12)
        mixed = cells("arrival", "arrival-8192")[0]
        invocation = command(Path("/bin/test"), "model", None, mixed, 5, 256, "contiguous")
        self.assertIn("8192,512,512,512", invocation)
        with self.assertRaises(ValueError):
            cells("decode", "decode-99-b2")

    def test_summary_revalidates_raw_and_scaling(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for batch in (1, 2, 4):
                spec, manifest, report = fixture(batch)
                directory = root / "cells" / spec["cell"]["name"]
                directory.mkdir(parents=True)
                write_json(root / "manifest.json", manifest)
                write_json(directory / "spec.json", spec)
                write_json(directory / "process.json", {"returncode": 0})
                write_json(directory / "stdout.raw", report)
            result = summarize(root)
            self.assertEqual([r["scalingVsB1"] for r in result["cells"]], [1, 2, 4])
            self.assertTrue((root / "summary.csv").exists())
            directory.joinpath("stdout.raw").write_text("not json")
            result = summarize(root)
            self.assertEqual(len(result["failures"]), 1)
            self.assertEqual(len(result["cells"]), 2)

    def test_timeout_retains_output_and_child_failure(self):
        with tempfile.TemporaryDirectory() as tmp, patch("gptoss_profile.process.host_snapshot", return_value={}):
            root = Path(tmp)
            state = run([sys.executable, "-u", "-c", "import time; print('raw-before-timeout'); time.sleep(30)"],
                        root, {}, root, .2)
            self.assertTrue(state["timedOut"])
            self.assertNotEqual(state["returncode"], 0)
            self.assertIn("raw-before-timeout", (root / "stdout.raw").read_text())
            self.assertTrue(json.loads((root / "process.json").read_text())["timedOut"])

    def test_runner_only_reuses_unchanged_pinned_success(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            binary, library = root / "binary", root / "mlx.metallib"
            binary.write_text("fixture binary")
            binary.chmod(0o700)
            library.write_text("fixture metallib")
            model = root / "model"
            model.mkdir()
            (model / "weights.safetensors").write_bytes(b"fixture weights")
            output = root / "result"
            args = parser().parse_args(["run", "--binary", str(binary), "--model", "test-model", "--model-dir", str(model),
                                        "--metallib", str(library), "--output", str(output), "--cells", "decode-512-b2",
                                        "--iterations", "1", "--decode-tokens", "64"])

            def fake_run(command, cwd, environment, directory, timeout, required_ac_power_mode=None):
                _, _, report = fixture()
                report["modelPath"] = str(model)
                write_json(directory / "stdout.raw", report)
                write_json(directory / "process.json", {"returncode": 0})
                write_json(directory / "host-before.json", {})
                write_json(directory / "host-after.json", {})
                return {"returncode": 0}

            with patch("gptoss_profile.runner.source_pin", return_value={}), \
                    patch("gptoss_profile.runner.host_snapshot", return_value={}), \
                    patch("gptoss_profile.runner.run", side_effect=fake_run) as launch:
                self.assertEqual(execute(args), 0)
                self.assertEqual(execute(args), 0)
                self.assertEqual(launch.call_count, 1)
                binary.write_text("different fixture binary")
                with self.assertRaisesRegex(ValueError, "different binary/model/source/environment"):
                    execute(args)
                self.assertEqual(launch.call_count, 1)

    def test_power_parser_and_requirement_fail_closed(self):
        power = parse_power("Battery Power:\n powermode 1\nAC Power:\n powermode 2\n", "Now drawing from 'AC Power'")
        self.assertEqual(power["acPowerMode"], 2)
        self.assertEqual(power["batteryPowerMode"], 1)
        self.assertIsNone(power_failure({"power": power}, 2))
        self.assertIn("Expected AC Power", power_failure({}, 2))
        power["source"] = "Battery Power"
        self.assertIn("Expected AC Power", power_failure({"power": power}, 2))

    def test_power_requirement_prevents_launch_and_rejects_after_change(self):
        high = {"power": {"source": "AC Power", "acPowerMode": 2}}
        low = {"power": {"source": "AC Power", "acPowerMode": 1}}
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with patch("gptoss_profile.process.host_snapshot", return_value=low), \
                    patch("gptoss_profile.process.subprocess.Popen") as launch:
                state = run([sys.executable, "-c", "print('not launched')"], root, {}, root, 10, 2)
                launch.assert_not_called()
                self.assertTrue(state["notLaunched"])
                self.assertIn("Expected AC powermode 2", state["powerRequirementFailed"])
            with patch("gptoss_profile.process.host_snapshot", side_effect=[high, low]):
                state = run([sys.executable, "-c", "print('ran on high power initially')"], root, {}, root, 10, 2)
                self.assertEqual(state["returncode"], 0)
                self.assertIn("powerRequirementFailed", state)
                self.assertEqual(json.loads((root / "host-before.json").read_text()), high)
                self.assertEqual(json.loads((root / "host-after.json").read_text()), low)


if __name__ == "__main__":
    unittest.main()
