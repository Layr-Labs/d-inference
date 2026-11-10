"""Model Requant Upload: input validation, canonical prefixes, manifest verification, the workflow's guards, and the
quantizer's packing (stdlib + numpy when present; no network, no credentials)."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
WORKFLOW = ROOT / ".github/workflows/model-requant-upload.yml"
UPLOAD = HERE / "upload-model-revision.py"


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


up = load("upload_model_revision", UPLOAD)
SRC = "https://huggingface.co/Qwen/Qwen3.5-9B/resolve/" + "c" * 40


def manifest_for(model_id, version, files):
    return {"schema_version": 1, "model_id": model_id, "version": version,
            "r2_prefix": up.slug_prefix(model_id, version), "aggregate_sha256": "0" * 64,
            "total_size_bytes": sum(len(b) for b in files.values()), "file_count": len(files),
            "files": [{"path": p, "role": "weight", "sha256": hashlib.sha256(b).hexdigest(), "size_bytes": len(b)}
                      for p, b in sorted(files.items())]}


def run_inputs(manifest, **over):
    with tempfile.TemporaryDirectory() as d:
        mp = Path(d) / "m.json"
        mp.write_text(json.dumps(manifest))
        args = {"--model-id": manifest["model_id"], "--version": manifest["version"],
                "--template-url": "https://models.darkbloom.ai/" + up.slug_prefix(manifest["model_id"], "2026-09-03-r1"),
                "--source-url": SRC, "--recipe": "g32", "--manifest": str(mp), "--mode": "build", "--confirm-version": ""}
        args.update(over)
        cmd = [sys.executable, str(UPLOAD), "inputs"] + [x for kv in args.items() for x in kv]
        return subprocess.run(cmd, capture_output=True, text=True, env={**os.environ, "GITHUB_OUTPUT": str(Path(d) / "o")})


class CanonicalPrefix(unittest.TestCase):
    def test_matches_published_prefixes(self):
        # Published revisions (models.darkbloom.ai catalog, 2026-11-10).
        for model_id, prefix in {
            "Qwen3.5-9B": "v2/Qwen3.5-9B--3e3c04992a0d/2026-09-03-r1",
            "qwen3.6-35b-a3b-vl-mtp-mxfp8": "v2/qwen3.6-35b-a3b-vl-mtp-mxfp8--943d60189096/2026-08-11-r1",
            "EigenLabs/Qwen3.8-27B-4bit-mtp": "v2/EigenLabs-Qwen3.8-27B-4bit-mtp--96c072dbd610/2026-09-03-r1",
        }.items():
            self.assertEqual(up.slug_prefix(model_id, prefix.rsplit("/", 1)[1]), prefix)


class Inputs(unittest.TestCase):
    def setUp(self):
        self.m = manifest_for("Qwen3.5-9B", "2026-11-12-g32-r1", {"config.json": b"{}"})

    def test_valid_build(self):
        r = run_inputs(self.m)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_upload_needs_the_version_repeated(self):
        self.assertNotEqual(run_inputs(self.m, **{"--mode": "upload"}).returncode, 0)
        self.assertEqual(run_inputs(self.m, **{"--mode": "upload", "--confirm-version": "2026-11-12-g32-r1"}).returncode, 0)

    def test_refusals(self):
        bad = [
            {"--source-url": "https://huggingface.co/Qwen/Qwen3.5-9B/resolve/main"},
            {"--source-url": "https://evil.example/x"},
            {"--template-url": "https://models.darkbloom.ai/v2/other--000000000000/2026-01-01-r1"},
            {"--template-url": "https://models.darkbloom.ai/" + up.slug_prefix("Qwen3.5-9B", "2026-11-12-g32-r1")},
            {"--recipe": "8bit"},
            {"--version": "2026-11-12-g32-r2"},
            {"--model-id": "qwen3.5-35b-a3b"},
        ]
        for over in bad:
            self.assertNotEqual(run_inputs(self.m, **over).returncode, 0, over)
        wrong_prefix = dict(self.m, r2_prefix="v2/elsewhere/2026-11-12-g32-r1")
        self.assertNotEqual(run_inputs(wrong_prefix).returncode, 0)
        unsafe = dict(self.m, files=[{"path": "../x", "sha256": "0" * 64, "size_bytes": 1, "role": "weight"}])
        self.assertNotEqual(run_inputs(unsafe).returncode, 0)


class Verify(unittest.TestCase):
    def test_exact_files_only(self):
        files = {"config.json": b"{}", "model-00001-of-00001.safetensors": b"x" * 100}
        m = manifest_for("Qwen3.5-9B", "v1", files)
        with tempfile.TemporaryDirectory() as d:
            mp = Path(d) / "m.json"
            mp.write_text(json.dumps(m))
            md = Path(d) / "model"
            md.mkdir()
            for p, b in files.items():
                (md / p).write_bytes(b)
            ok = subprocess.run([sys.executable, str(UPLOAD), "verify", "--manifest", str(mp), "--directory", str(md)],
                                capture_output=True, text=True)
            self.assertEqual(ok.returncode, 0, ok.stderr)
            (md / "model-00001-of-00001.safetensors").write_bytes(b"y" * 100)
            changed = subprocess.run([sys.executable, str(UPLOAD), "verify", "--manifest", str(mp), "--directory", str(md)],
                                     capture_output=True, text=True)
            self.assertNotEqual(changed.returncode, 0)
            (md / "model-00001-of-00001.safetensors").write_bytes(b"x" * 100)
            (md / "extra.txt").write_bytes(b"")
            extra = subprocess.run([sys.executable, str(UPLOAD), "verify", "--manifest", str(mp), "--directory", str(md)],
                                   capture_output=True, text=True)
            self.assertNotEqual(extra.returncode, 0)


class WorkflowGuards(unittest.TestCase):
    def test_guards(self):
        text = WORKFLOW.read_text()
        self.assertIn("default: check", text)
        self.assertIn("permissions:\n  contents: read", text)
        self.assertIn("persist-credentials: false", text)
        # No input is expanded inside a script body; they reach scripts through env only.
        for line in text.splitlines():
            if line.strip().startswith(("run:", "python3", "aws", "printf", "echo", "need=", "[")):
                self.assertNotIn("${{ inputs.", line, line)
        # Secrets appear only in the two steps that need them (read check, upload), never in the rebuild.
        self.assertEqual(text.count("secrets.R2_SECRET_ACCESS_KEY"), 2)
        self.assertNotIn("publish-revision", text.split("Reserve and upload")[0])
        self.assertNotIn("promote", text.split("jobs:")[1].split("Next, on the owner's go")[0].lower().replace("promotion", ""))


@unittest.skipUnless(importlib.util.find_spec("numpy"), "numpy not installed")
class Packing(unittest.TestCase):
    def test_round_trip(self):
        import numpy as np
        rq = load("requant", HERE / "requant.py")
        rng = np.random.default_rng(0)
        for bits, group in ((4, 64), (4, 32), (6, 64), (8, 64)):
            w = rng.standard_normal((16, 256)).astype(np.float32)
            pw, ps, pb = rq.affine_quantize(w, bits, group)
            self.assertEqual(pw.shape, (16, 256 * bits // 32))
            q = rq.unpack(pw, bits, 256).reshape(16, 256 // group, group).astype(np.float32)
            s = (ps.astype(np.uint32) << 16).view(np.float32)[..., None]
            b = (pb.astype(np.uint32) << 16).view(np.float32)[..., None]
            # Per group: MLX's rule keeps one edge exact and zero representable (scale = edge / round(edge / scale)),
            # which can stretch the step and clip the far end, and the bf16 bias adds up to half an 8-bit step: within 2 steps.
            err = np.abs(q * s + b - w.reshape(16, 256 // group, group)).max(axis=-1)
            self.assertTrue(bool((err <= 2.0 * np.abs(s[..., 0]) + 1e-6).all()), (bits, group, float(err.max())))


if __name__ == "__main__":
    unittest.main()
