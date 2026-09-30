#!/usr/bin/env python3
"""Offline fixture inventory, reproducibility and CI-split regressions."""
from concurrent.futures import ThreadPoolExecutor
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest import mock

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
        for asymmetric, context, head, width in [(False, 128, 32, 32), (True, 1024, 64, 128)]:
            with self.subTest(asymmetric=asymmetric):
                output = SETUP.prepare(self.root / str(asymmetric), asymmetric)
                model = output / "tiny-bf16"
                config = json.loads((model / "config.json").read_bytes())
                self.assertEqual(config["max_position_embeddings"], context)
                self.assertEqual((config["head_dim"], config["v_head_dim"]), (head, width))
                self.assertEqual((config["swa_head_dim"], config["swa_v_head_dim"]), (head, width))
                self.assertEqual(config["num_nextn_predict_layers"], 3)
                inventory = SETUP.tensors(config)
                self.assertEqual(inventory["mtp.layers.0.self_attn.v_proj.weight"]["shape"], [width, 8])
                self.assertEqual(inventory["model.layers.0.self_attn.o_proj.weight"]["shape"], [64, 2 * width])
                index = json.loads((model / "model.safetensors.index.json").read_bytes())
                self.assertEqual(len(inventory), 193)
                self.assertEqual(index["weight_map"], {key: entry["file"] for key, entry in inventory.items()})
                total = 0
                for name in set(index["weight_map"].values()):
                    data = (model / name).read_bytes()
                    length = struct.unpack("<Q", data[:8])[0]
                    self.assertEqual(length % 8, 0)
                    header = json.loads(data[8:8 + length])
                    self.assertEqual(header.pop("__metadata__")["fixture"], "synthetic-ci-not-model-evidence")
                    self.assertEqual(set(header), {key for key, shard in index["weight_map"].items()
                                                   if shard == name})
                    payload = data[8 + length:]
                    offset = 0
                    for key, entry in header.items():
                        count = math.prod(entry["shape"])
                        size = count * {"BF16": 2, "F32": 4, "U32": 4, "U8": 1}[entry["dtype"]]
                        self.assertEqual(entry["data_offsets"], [offset, offset + size])
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

    def test_competing_output_creation_is_rejected_without_writing_into_it(self):
        output = self.root / "raced"
        ready, resume = threading.Event(), threading.Event()
        tensors = SETUP.tensors

        def paused_inventory(config):
            inventory = tensors(config)
            ready.set()
            if not resume.wait(5):
                raise TimeoutError("fixture race did not resume")
            return inventory

        with mock.patch.object(SETUP, "tensors", paused_inventory), ThreadPoolExecutor(max_workers=1) as worker:
            attempt = worker.submit(SETUP.prepare, output)
            try:
                self.assertTrue(ready.wait(5), "fixture preparation did not reach the race window")
                output.mkdir()
                marker = output / "competitor-owned"
                marker.write_bytes(b"unchanged")
            finally:
                resume.set()
            with self.assertRaises(FileExistsError):
                attempt.result(timeout=5)
        self.assertEqual(list(output.iterdir()), [marker])
        self.assertEqual(marker.read_bytes(), b"unchanged")

    def test_fixture_file_creation_never_overwrites_or_follows_links(self):
        target = self.root / "target"
        target.write_bytes(b"unchanged")
        for name, linked in [("file", False), ("link", True), ("dangling", True)]:
            with self.subTest(name=name):
                path = self.root / name
                if linked:
                    path.symlink_to(target if name == "link" else self.root / "absent")
                else:
                    path.write_bytes(b"unchanged")
                with self.assertRaises(FileExistsError):
                    SETUP.write_bytes(path, b"replacement")
                self.assertEqual(target.read_bytes(), b"unchanged")
                self.assertFalse((self.root / "absent").exists())
                if linked:
                    self.assertTrue(path.is_symlink())
                else:
                    self.assertEqual(path.read_bytes(), b"unchanged")

    def test_cli_exports_only_fixture_path_not_native_opt_ins(self):
        for asymmetric in (False, True):
            with self.subTest(asymmetric=asymmetric):
                env_file = self.root / f"github-env-{asymmetric}"
                output = self.root / f"path with spaces {asymmetric}"
                existing = (f"MIMO_PROMPT_ARTIFACT_DIRECTORY={self.root / 'prompt metadata'}\n"
                            f"MIMO_PROMPT_REFERENCE_VECTORS={self.root / 'prompt vectors.json'}\n") if asymmetric else ""
                if existing:
                    env_file.write_text(existing)
                command = [sys.executable, "-B", str(SCRIPT), "--output", str(output),
                           "--github-env", str(env_file)]
                if asymmetric:
                    command.append("--asymmetric")
                result = subprocess.run(command, capture_output=True, text=True, timeout=20)
                self.assertEqual(result.returncode, 0, result.stderr)
                expected = (f"MIMO_V26_SERIAL_LOAD_FIXTURES={output.resolve()}\n"
                            f"MIMO_V26_WIRED_METADATA_FIXTURE={output.resolve() / 'tiny-bf16'}\n")
                self.assertEqual(result.stdout, expected)
                self.assertEqual(env_file.read_text(), existing + expected)
                config = json.loads((output / "tiny-bf16/config.json").read_bytes())
                self.assertEqual((config["head_dim"], config["v_head_dim"], config["max_position_embeddings"]),
                                 (64, 128, 1024) if asymmetric else (32, 32, 128))

    def test_provider_job_provisions_prompt_and_tiny_inputs_before_tests(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text().split("  test-provider:", 1)[1]
        workflow = workflow.split("  cache-swift:", 1)[0]
        run = workflow.index("run: ../scripts/run-provider-tests.sh")
        for command in ("scripts/prepare-mimo-prompt-fixtures.py", "scripts/prepare-mimo-provider-fixtures.py"):
            self.assertLess(workflow.index(command), run)
        setup = workflow.split("      - name: Prepare bounded synthetic MiMo provider fixtures offline", 1)[1]
        setup = setup.split("      - name:", 1)[0]
        self.assertIn('python3 scripts/prepare-mimo-provider-fixtures.py --output "$RUNNER_TEMP/mimo-provider-fixtures" --github-env "$GITHUB_ENV"', setup)
        self.assertIn('python3 scripts/prepare-mimo-provider-fixtures.py --output "$RUNNER_TEMP/mimo-prefix-fixtures" --asymmetric', setup)
        for name in ("startup", "complete-prefix", "retained-fault"):
            step = workflow.split(f"      - name: Run isolated native MiMo {name} gate", 1)[1]
            step = step.split("      - name:", 1)[0]
            self.assertIn("!cancelled()", step)
            self.assertIn("steps.mimo-fixtures.outcome == 'success'", step)
            self.assertIn("steps.build-provider-tests.outcome == 'success'", step)
            self.assertIn("steps.place-provider-metallib.outcome == 'success'", step)
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
