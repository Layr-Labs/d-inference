#!/usr/bin/env python3
"""Offline fixture inventory, reproducibility and CI-split regressions."""
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts/prepare-mimo-provider-fixtures.py"
SPEC = importlib.util.spec_from_file_location("provider_fixtures", SCRIPT)
SETUP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SETUP)


class ProviderFixtureTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def test_inventory_offsets_payloads_and_provenance_are_closed(self):
        output = SETUP.prepare(self.root / "fixtures")
        model = output / "tiny-bf16"
        config = json.loads((model / "config.json").read_bytes())
        inventory = SETUP.tensors(config)
        index = json.loads((model / "model.safetensors.index.json").read_bytes())
        self.assertEqual(len(inventory), 193)
        self.assertEqual(set(index["weight_map"]), set(inventory))
        total = 0
        for name in set(index["weight_map"].values()):
            data = (model / name).read_bytes()
            length = struct.unpack("<Q", data[:8])[0]
            self.assertEqual(length % 8, 0)
            header = json.loads(data[8:8 + length])
            self.assertEqual(header.pop("__metadata__")["fixture"], "synthetic-ci-not-model-evidence")
            payload = data[8 + length:]
            offset = 0
            for key, entry in header.items():
                count = math.prod(entry["shape"])
                size = count * {"BF16": 2, "F32": 4, "U32": 4, "U8": 1}[entry["dtype"]]
                self.assertEqual(entry["data_offsets"], [offset, offset + size])
                self.assertEqual(index["weight_map"][key], name)
                self.assertEqual(entry["shape"], inventory[key]["shape"])
                self.assertEqual(entry["dtype"], inventory[key]["dtype"])
                offset += size
            self.assertEqual(offset, len(payload))
            total += offset
            self.assertLess(len(data), 1 << 20)
        self.assertEqual(total, index["metadata"]["total_size"])
        self.assertLess(total, 1 << 20)
        provenance = json.loads((output / "provenance.json").read_bytes())
        manifest = (model / "conversion_manifest.json").read_bytes()
        self.assertEqual(provenance["conversionManifestSHA256"], hashlib.sha256(manifest).hexdigest())
        self.assertEqual(json.loads(manifest)["source_config_sha256"],
                         hashlib.sha256((model / "config.json").read_bytes()).hexdigest())
        self.assertFalse((model / "audio_tokenizer").exists())
        self.assertNotIn("payloadVerificationReceiptSHA256", provenance)
        processor = config["processor_config"]
        self.assertEqual(processor["rope_type"], "rope")
        self.assertEqual(processor["temporal_compression_ratio"], 1)
        self.assertTrue(processor["use_video_timestamps"])
        self.assertFalse(processor["use_per_grid_t_timestamps"])
        self.assertEqual(processor["video_total_max_pixels"], 512)

    def test_symmetric_and_prefix_fixtures_have_distinct_geometry(self):
        for asymmetric, context, head, width in [(False, 128, 32, 32), (True, 1024, 64, 128)]:
            with self.subTest(asymmetric=asymmetric):
                output = SETUP.prepare(self.root / str(asymmetric), asymmetric)
                config = json.loads((output / "tiny-bf16/config.json").read_bytes())
                self.assertEqual(config["max_position_embeddings"], context)
                self.assertEqual((config["head_dim"], config["v_head_dim"]), (head, width))
                self.assertEqual((config["swa_head_dim"], config["swa_v_head_dim"]), (head, width))
                self.assertEqual(config["num_nextn_predict_layers"], 3)
                tensors = SETUP.tensors(config)
                self.assertEqual(tensors["mtp.layers.0.self_attn.v_proj.weight"]["shape"], [width, 8])
                self.assertEqual(tensors["model.layers.0.self_attn.o_proj.weight"]["shape"], [64, 2 * width])

    def test_repeated_setup_produces_identical_bytes(self):
        left = SETUP.prepare(self.root / "left")
        right = SETUP.prepare(self.root / "right")
        for path in left.rglob("*"):
            if path.is_file():
                self.assertEqual(path.read_bytes(), (right / path.relative_to(left)).read_bytes())

    def test_existing_and_linked_outputs_are_not_overwritten(self):
        for name, linked in [("existing", False), ("link", True)]:
            path = self.root / name
            if linked:
                path.symlink_to(self.root / "absent", target_is_directory=True)
            else:
                path.mkdir()
            with self.assertRaises(FileExistsError):
                SETUP.prepare(path)

    def test_cli_exports_only_fixture_path_not_native_opt_ins(self):
        env_file = self.root / "github-env"
        output = self.root / "path with spaces"
        result = subprocess.run([sys.executable, "-B", str(SCRIPT), "--output", str(output),
                                 "--github-env", str(env_file)], capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        expected = (f"MIMO_V26_SERIAL_LOAD_FIXTURES={output.resolve()}\n"
                    f"MIMO_V26_WIRED_METADATA_FIXTURE={output.resolve() / 'tiny-bf16'}\n")
        self.assertEqual(result.stdout, expected)
        self.assertEqual(env_file.read_text(), expected)

    def test_provider_job_provisions_prompt_and_tiny_inputs_before_tests(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text().split("  test-provider:", 1)[1]
        workflow = workflow.split("  test-provider-sdk:", 1)[0]
        run = workflow.index("run: ../scripts/run-provider-tests.sh")
        for command in ("scripts/prepare-mimo-prompt-fixtures.py", "scripts/prepare-mimo-provider-fixtures.py"):
            self.assertLess(workflow.index(command), run)
        self.assertIn("--asymmetric", workflow)
        for name in ("startup", "complete-prefix", "retained-fault"):
            step = workflow.split(f"      - name: Run isolated native MiMo {name} gate", 1)[1]
            step = step.split("      - name:", 1)[0]
            self.assertIn("!cancelled()", step)
            self.assertIn("steps.mimo-fixtures.outcome == 'success'", step)
            self.assertIn("steps.provider-ci-build.outcome == 'success'", step)
            self.assertIn("../scripts/run-nested-suite.sh", step)
            self.assertIn("--no-parallel", step)
            self.assertNotIn("continue-on-error", step)
        self.assertNotIn("MIMO_V26_MANAGED_AUDIO_PROVIDER_TESTS:", workflow)
        self.assertNotIn("MIMO_CONSUMER_DIVERGENCE_TESTS:", workflow)
        self.assertNotIn("MIMO_V26_INGRESS_AUDIO_VIDEO_TESTS:", workflow)

    def test_sdk_qualification_provisions_the_same_routine_inputs(self):
        action = (ROOT / ".github/actions/provider-release-build/action.yml").read_text()
        step = action.split("    - name: Test provider with release SDK", 1)[1].split("    - name:", 1)[0]
        self.assertIn("if: inputs.lane == 'qualification'", step)
        self.assertIn("MIMO_V26_PROVIDER_LIFETIME_METADATA_TESTS: '1'", step)
        run = step.index("-- ../scripts/run-provider-tests.sh")
        for command in ("prepare-mimo-prompt-fixtures.py", "prepare-mimo-provider-fixtures.py"):
            self.assertLess(step.index(command), run)
        for key in ("MIMO_PROMPT_ARTIFACT_DIRECTORY", "MIMO_PROMPT_REFERENCE_VECTORS",
                    "MIMO_V26_SERIAL_LOAD_FIXTURES", "MIMO_V26_WIRED_METADATA_FIXTURE"):
            self.assertIn(f"export {key}=", step)
        self.assertNotIn("MIMO_V26_SERIAL_NATIVE_TESTS", step)


if __name__ == "__main__":
    unittest.main()
