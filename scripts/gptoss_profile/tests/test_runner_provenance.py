import contextlib
import copy
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from gptoss_profile.provenance import assert_artifacts_unchanged, write_json
from gptoss_profile.runner import execute, parser
from gptoss_profile.summary import summarize
from gptoss_profile.tests.test_integrity import fixture


class RunnerProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.model = self.root / "model"
        self.model.mkdir()
        self.paths = {name: self.root / name for name in ("binary", "metallib", "config", "receipt")}
        self.paths["weights"] = self.model / "weights.safetensors"
        for name, path in self.paths.items():
            path.write_text(name)
        self.paths["binary"].chmod(0o700)
        self.output = self.root / "result"
        self.args = parser().parse_args([
            "run", "--binary", str(self.paths["binary"]), "--model", "test-model",
            "--model-dir", str(self.model), "--metallib", str(self.paths["metallib"]),
            "--config", str(self.paths["config"]), "--build-receipt", str(self.paths["receipt"]),
            "--output", str(self.output), "--cells", "decode-512-b1", "--iterations", "1",
            "--decode-tokens", "64"])
        self.addCleanup(patch.stopall)
        patch("gptoss_profile.runner.source_pin", return_value={}).start()
        patch("gptoss_profile.runner.host_snapshot", return_value={}).start()
        self.launch = patch("gptoss_profile.runner.run", side_effect=self.fake_run).start()
        self.stdout = contextlib.redirect_stdout(io.StringIO())
        self.stdout.__enter__()
        self.addCleanup(self.stdout.__exit__, None, None, None)

    def fake_run(self, command, cwd, environment, directory, timeout, required_ac_power_mode=None):
        spec = json.loads((directory / "spec.json").read_text())
        _, _, report = fixture(spec["cell"]["batch"])
        report["modelPath"] = str(self.model)
        write_json(directory / "stdout.raw", report)
        write_json(directory / "process.json", {"returncode": 0})
        for moment in ("before", "after"):
            write_json(directory / f"host-{moment}.json", {})
        return {"returncode": 0}

    def test_resume_rejects_changed_matrix_settings_for_new_cell(self):
        self.assertEqual(execute(self.args), 0)
        for key, value in (("iterations", 2), ("decode_tokens", 128), ("kv_backend", "paged")):
            with self.subTest(setting=key):
                args = copy.copy(self.args)
                args.cells = "decode-512-b2"
                setattr(args, key, value)
                with self.assertRaisesRegex(ValueError, "workload provenance"):
                    execute(args)
        self.assertEqual(self.launch.call_count, 1)

    def test_all_artifacts_rechecked_before_and_after_run(self):
        for moment in ("before", "after"):
            for name in (*self.paths, "added-model-file", "removed-model-file"):
                with self.subTest(moment=moment, artifact=name):
                    self.args.output = self.root / f"{moment}-{name}"
                    original = {p: p.read_bytes() for p in self.paths.values()}
                    added = self.model / "extra.json"

                    def mutate():
                        if name == "added-model-file":
                            added.write_text("new")
                        elif name == "removed-model-file":
                            self.paths["weights"].unlink()
                        else:
                            path = self.paths[name]
                            # Same-size replacement must also be detected.
                            path.write_bytes(b"X" * len(original[path]))

                    def check(pins):
                        if moment == "before":
                            mutate()
                        assert_artifacts_unchanged(pins)

                    def launch(*args, **kwargs):
                        state = self.fake_run(*args, **kwargs)
                        if moment == "after":
                            mutate()
                        return state

                    self.launch.reset_mock()
                    self.launch.side_effect = launch
                    with patch("gptoss_profile.runner.assert_artifacts_unchanged", side_effect=check):
                        if moment == "before":
                            with self.assertRaises((ValueError, OSError)):
                                execute(self.args)
                            self.launch.assert_not_called()
                        else:
                            self.assertEqual(execute(self.args), 1)
                            result = summarize(self.args.output)
                            self.assertEqual(result["cells"], [])
                            self.assertTrue(result["failures"])
                    for path, contents in original.items():
                        path.write_bytes(contents)
                    added.unlink(missing_ok=True)

    def test_legacy_manifest_does_not_mix_backends_in_scaling(self):
        for batch, backend in ((1, "contiguous"), (2, "paged")):
            spec, manifest, report = fixture(batch)
            spec["backend"] = backend
            report["kvBackend"] = {"selection": backend, "resolved": [backend]}
            report["decode"][0]["resolvedKVBackend"] = backend
            directory = self.output / "cells" / spec["cell"]["name"]
            directory.mkdir(parents=True)
            write_json(self.output / "manifest.json", manifest)
            write_json(directory / "spec.json", spec)
            write_json(directory / "process.json", {"returncode": 0})
            write_json(directory / "stdout.raw", report)
        result = summarize(self.output)
        self.assertFalse(result["failures"])
        self.assertEqual(result["cells"][0]["scalingVsB1"], 1)
        self.assertIsNone(result["cells"][1]["scalingVsB1"])
        self.assertEqual(result["cells"][1]["backend"], "paged")

    def test_runtime_metallib_symlink_retarget_is_rejected(self):
        library = self.paths["metallib"]
        old, new = self.root / "old.metallib", self.root / "new.metallib"
        library.rename(old)
        new.write_text("replacement library")
        library.symlink_to(old)

        def launch(*args, **kwargs):
            state = self.fake_run(*args, **kwargs)
            library.unlink()
            library.symlink_to(new)
            return state

        self.launch.side_effect = launch
        self.assertEqual(execute(self.args), 1)
        result = summarize(self.output)
        self.assertEqual(result["cells"], [])
        self.assertIn("Pinned artifact changed", result["failures"][0]["error"])
