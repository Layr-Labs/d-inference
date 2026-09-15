"""CPU-only synthetic tests: no real MLX import, model files, or network access.

The converter integration tests use a stub serializer/quantizer. They prove
receipt and fail-closed wiring, not quantization numerics or model execution.
"""
from __future__ import annotations

import contextlib
import functools
import hashlib
import importlib.metadata
import io
import json
import subprocess
import sys
import tempfile
import types
import unittest
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

import convert_qwen4exp_q4_mtp as converter
import qwen38_provenance as provenance
import verify_qwen38_download as verifier


class SyntheticSourceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="synthetic-qwen-", dir=Path(__file__).parent)
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "source"
        self.source.mkdir()
        self.metadata = self.source / ".cache" / "huggingface" / "download"
        self.metadata.mkdir(parents=True)
        self.shards = ("model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors")
        for i, name in enumerate(self.shards):
            (self.source / name).write_bytes(f"synthetic payload {i}".encode())
            self.write_cache_metadata(name, provenance.sha256_file(self.source / name))
        self.write_json("config.json", {
            "model_type": "qwen4_exp",
            "text_config": {"model_type": "qwen4_exp_text", "mtp_num_hidden_layers": 1},
        })
        keys = [f"model.language_model.layers.1.ple.ple_embedding.ngram_embedding.shard_{i}.weight" for i in range(128)]
        keys.extend(f"mtp.synthetic_{i}.weight" for i in range(31))
        keys.append("model.language_model.synthetic.weight")
        self.write_json("model.safetensors.index.json", {
            "metadata": {"total_size": 128},
            "weight_map": {key: self.shards[i % 2] for i, key in enumerate(keys)},
        })
        (self.source / "LICENSE").write_text("synthetic license fixture\n")
        pins = {name: provenance.sha256_file(self.source / name) for name in ("config.json", "model.safetensors.index.json", "LICENSE")}
        for name in pins:
            self.write_cache_metadata(name, "synthetic-small-file-etag")
        self.policy = provenance.SourcePolicy(provenance.SOURCE_REPO, provenance.SOURCE_REVISION, pins, self.shards, len(keys))
        self.write_json(".download-complete", {"repo": self.policy.repo, "revision": self.policy.revision})

    def write_json(self, name: str, value: object) -> None:
        (self.source / name).write_text(json.dumps(value))

    def write_cache_metadata(self, name: str, digest: str, revision: str = provenance.SOURCE_REVISION) -> None:
        (self.metadata / f"{name}.metadata").write_text(f"{revision}\n{digest}\n0\n")

    def verify(self, **kwargs: object) -> dict:
        return provenance.verify_source(self.source, policy=self.policy, **kwargs)

    def policy_verifier(self):
        return functools.partial(provenance.verify_source, policy=self.policy)

    def test_metadata_success_explicitly_does_not_verify_payloads(self) -> None:
        report = self.verify()
        self.assertTrue(report["ok"])
        self.assertFalse(report["source_payloads_verified"])
        self.assertEqual(report["shard_hash_checked"], 0)
        self.assertEqual(report["shard_hash_metadata_count"], 2)

    def test_full_hash_checks_every_synthetic_shard(self) -> None:
        report = self.verify(hash_shards=True)
        self.assertTrue(report["ok"])
        self.assertTrue(report["source_payloads_verified"])
        self.assertEqual(report["shard_hash_checked"], report["shard_hash_expected"])
        self.assertTrue(all(item["sha256"] == item["expected_sha256"] for item in report["source_shards"]))

    def test_missing_hash_metadata_fails_before_payload_hashing(self) -> None:
        (self.metadata / f"{self.shards[1]}.metadata").unlink()
        report = self.verify(hash_shards=True)
        self.assertFalse(report["ok"])
        self.assertFalse(report["source_payloads_verified"])
        self.assertEqual(report["missing_shard_hash_metadata"], [self.shards[1]])
        self.assertEqual(report["shard_hash_checked"], 0)

    def test_malformed_expected_hash_fails(self) -> None:
        self.write_cache_metadata(self.shards[0], "not-a-sha256")
        report = self.verify(hash_shards=True)
        self.assertFalse(report["ok"])
        self.assertEqual(report["invalid_shard_hash_metadata"], [self.shards[0]])

    def test_wrong_marker_revision_fails(self) -> None:
        self.write_json(".download-complete", {"repo": self.policy.repo, "revision": "0" * 40})
        self.assertFalse(self.verify()["ok"])

    def test_wrong_marker_repository_fails(self) -> None:
        self.write_json(".download-complete", {"repo": "Other/Model", "revision": self.policy.revision})
        self.assertFalse(self.verify()["ok"])

    def test_missing_download_marker_fails(self) -> None:
        (self.source / ".download-complete").unlink()
        self.assertFalse(self.verify()["ok"])

    def test_cached_source_revision_mismatch_fails(self) -> None:
        self.write_cache_metadata("config.json", "etag", revision="0" * 40)
        report = self.verify()
        self.assertFalse(report["ok"])
        self.assertIn("config.json", report["revision_mismatch"])

    def test_changed_pinned_metadata_fails(self) -> None:
        (self.source / "LICENSE").write_text("changed license fixture\n")
        report = self.verify()
        self.assertFalse(report["ok"])
        self.assertEqual(report["pin_mismatch"][0]["file"], "LICENSE")

    def test_missing_shard_cannot_pass_full_hash(self) -> None:
        (self.source / self.shards[0]).unlink()
        report = self.verify(hash_shards=True)
        self.assertFalse(report["ok"])
        self.assertEqual(report["missing_shards"], [self.shards[0]])
        self.assertFalse(report["source_payloads_verified"])

    def test_changed_shard_payload_fails_full_hash(self) -> None:
        (self.source / self.shards[0]).write_bytes(b"corrupt synthetic payload")
        report = self.verify(hash_shards=True)
        self.assertFalse(report["ok"])
        self.assertEqual(report["shard_hash_checked"], 2)
        self.assertEqual(report["shard_mismatch"][0]["file"], self.shards[0])

    def test_unexpected_indexed_shard_name_fails(self) -> None:
        name = "model.safetensors.index.json"
        index = json.loads((self.source / name).read_text())
        first = next(iter(index["weight_map"]))
        index["weight_map"][first] = "../unexpected.safetensors"
        self.write_json(name, index)
        self.policy = replace(self.policy, metadata_pins={**self.policy.metadata_pins, name: provenance.sha256_file(self.source / name)})
        report = self.verify()
        self.assertFalse(report["ok"])
        self.assertIn("source shard names/count differ from pin", report["errors"])

    def test_converter_rejects_revision_label_before_reading_source(self) -> None:
        with patch.object(converter, "verify_source") as mock_verify:
            with self.assertRaisesRegex(ValueError, "pinned official revision"):
                converter._validate_source(self.source, "0" * 40)
            mock_verify.assert_not_called()

    def test_converter_source_validation_enforces_pinned_metadata(self) -> None:
        with patch.object(converter, "verify_source", self.policy_verifier()):
            result = converter._validate_source(self.source, self.policy.revision)
            self.assertEqual(result["inventory"]["mtp_count"], 31)
            self.assertTrue(result["inventory"]["ngram_complete"])
            (self.source / "LICENSE").write_text("changed")
            with self.assertRaisesRegex(ValueError, "source identity verification failed"):
                converter._validate_source(self.source, self.policy.revision)

    def test_converter_cli_rejects_wrong_repository(self) -> None:
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as raised:
            converter.main(["--source", str(self.source), "--output", str(self.root / "out"), "--source-repo", "Other/Model", "--inventory-only"])
        self.assertEqual(raised.exception.code, 2)
        self.assertFalse((self.root / "out").exists())

    def complete_manifest_inputs(self) -> tuple[dict, list[dict]]:
        source = self.verify(hash_shards=True)
        outputs = [{"file": name, "bytes": 7, "sha256": hashlib.sha256(b"fixture").hexdigest()} for name in self.shards]
        return source, outputs

    def test_manifest_contains_exact_complete_source_and_output_coverage(self) -> None:
        source, outputs = self.complete_manifest_inputs()
        manifest = provenance.make_shard_manifest(source, outputs)
        self.assertTrue(manifest["source_payloads_verified"])
        self.assertEqual({item["file"] for item in manifest["output_shards"]}, set(self.shards))
        self.assertEqual(manifest["source_revision"], self.policy.revision)

    def test_manifest_rejects_missing_or_duplicate_output_digests(self) -> None:
        source, outputs = self.complete_manifest_inputs()
        for invalid in (outputs[:1], [outputs[0], outputs[0]]):
            with self.subTest(invalid=invalid), self.assertRaisesRegex(ValueError, "output digest coverage"):
                provenance.make_shard_manifest(source, invalid)

    def test_manifest_rejects_unverified_or_mismatched_source_digest(self) -> None:
        source, outputs = self.complete_manifest_inputs()
        for invalid in (None, "0" * 64):
            with self.subTest(digest=invalid):
                source["source_shards"][0]["sha256"] = invalid
                with self.assertRaisesRegex(ValueError, "unverified source digest"):
                    provenance.make_shard_manifest(source, outputs)

    def test_runtime_provenance_fingerprints_core_without_exposing_urls(self) -> None:
        core_file = self.root / "synthetic-core.so"
        core_file.write_bytes(b"synthetic runtime fixture")
        metadata = {"METADATA": "Version: 1.2.3", "WHEEL": "synthetic", "RECORD": "synthetic", "direct_url.json": '{"url":"https://user:secret@example.invalid/private"}'}
        distribution = types.SimpleNamespace(version="1.2.3", read_text=metadata.get)
        with patch.object(importlib.metadata, "distribution", return_value=distribution):
            report = provenance.runtime_provenance(types.SimpleNamespace(__file__=str(core_file)))
        self.assertEqual(report["mlx_distribution_version"], "1.2.3")
        self.assertEqual(report["mlx_core_sha256"], provenance.sha256_file(core_file))
        self.assertNotIn("secret", json.dumps(report))
        self.assertNotIn("example.invalid", json.dumps(report))
        self.assertIn("direct_url.json", report["mlx_distribution_metadata_sha256"])

    def test_missing_mlx_distribution_does_not_invent_provenance(self) -> None:
        with patch.object(importlib.metadata, "distribution", side_effect=importlib.metadata.PackageNotFoundError("mlx")):
            with self.assertRaises(importlib.metadata.PackageNotFoundError):
                provenance.runtime_provenance(types.SimpleNamespace(__file__="unused"))

    @contextlib.contextmanager
    def stub_conversion(self):
        core = types.ModuleType("mlx.core")
        core.reset_peak_memory = lambda: None
        core.get_peak_memory = lambda: 1
        core.clear_cache = lambda: None
        core.synchronize = lambda: None
        core.save_safetensors = lambda filename, tensors: Path(filename).write_bytes(json.dumps(sorted(tensors)).encode())
        package = types.ModuleType("mlx")
        package.core = core
        package.__path__ = []

        def quantize(_filename: Path, keys: list[str]) -> dict:
            return {"tensors": dict.fromkeys(keys, None), "stats": {"copied": len(keys), "quantized": 0, "ngram": sum("ngram_embedding" in key for key in keys), "mtp": sum(key.startswith("mtp.") for key in keys), "exceptions": []}}

        with patch.dict(sys.modules, {"mlx": package, "mlx.core": core}), patch.object(converter, "verify_source", self.policy_verifier()), patch.object(converter, "runtime_provenance", return_value={"synthetic_stub": True}), patch.object(converter.shutil, "disk_usage", return_value=types.SimpleNamespace(free=16 * 1024**3)), patch.object(converter, "convert_shard", side_effect=quantize) as quantizer, contextlib.redirect_stdout(io.StringIO()):
            yield quantizer

    def test_converter_writes_complete_manifest_with_stub_quantizer(self) -> None:
        output = self.root / "output"
        with self.stub_conversion():
            receipt = converter.convert(self.source, output, self.policy.revision, self.policy.repo)
        manifest = json.loads((output / "shard-digests.json").read_text())
        self.assertTrue(receipt["source_payloads_verified"])
        self.assertEqual(receipt["source_shard_hash_checked"], 2)
        self.assertEqual(receipt["output_shard_hash_checked"], 2)
        self.assertEqual(receipt["shard_digest_manifest"]["sha256"], provenance.sha256_file(output / "shard-digests.json"))
        self.assertEqual(receipt["runtime_provenance"], {"synthetic_stub": True})
        self.assertTrue(receipt["all_source_tensor_identities_preserved"])
        self.assertEqual(receipt["output_mtp_weight_count"], 31)
        self.assertEqual(receipt["output_config_sha256"], provenance.sha256_file(output / "config.json"))
        self.assertEqual(receipt["output_index_sha256"], provenance.sha256_file(output / "model.safetensors.index.json"))
        self.assertEqual(receipt["output_metadata_sha256"]["README.md"], provenance.sha256_file(output / "README.md"))
        for item in manifest["output_shards"]:
            self.assertEqual(item["sha256"], provenance.sha256_file(output / item["file"]))

    def test_converter_rejects_bad_source_payload_before_quantizer(self) -> None:
        (self.source / self.shards[0]).write_bytes(b"changed synthetic payload")
        output = self.root / "output"
        with self.stub_conversion() as quantizer:
            with self.assertRaisesRegex(ValueError, "source shard payload hash mismatch"):
                converter.convert(self.source, output, self.policy.revision, self.policy.repo)
            quantizer.assert_not_called()
        self.assertFalse((output / "conversion-receipt.json").exists())
        self.assertFalse((output / "shard-digests.json").exists())

    def test_key_coverage_allows_copied_and_complete_quantized_tensors(self) -> None:
        converter.validate_output_key_coverage(
            ["mtp.norm.weight", "mtp.proj.weight"],
            ["mtp.norm.weight", "mtp.proj.weight", "mtp.proj.scales", "mtp.proj.biases"])

    def test_key_coverage_rejects_missing_mtp_tensor(self) -> None:
        with self.assertRaisesRegex(ValueError, "missing converted tensor identity"):
            converter.validate_output_key_coverage(
                ["mtp.first.weight", "mtp.second.weight"], ["mtp.first.weight"])

    def test_key_coverage_rejects_incomplete_affine_triples(self) -> None:
        for keys in (["mtp.proj.weight", "mtp.proj.scales"], ["mtp.proj.scales", "mtp.proj.biases"]):
            with self.subTest(keys=keys), self.assertRaisesRegex(ValueError, "incomplete quantized tensor"):
                converter.validate_output_key_coverage(["mtp.proj.weight"], keys)

    def test_key_coverage_rejects_unknown_and_colliding_identities(self) -> None:
        with self.assertRaisesRegex(ValueError, "unexpected converted tensor"):
            converter.validate_output_key_coverage(["mtp.norm.weight"], ["mtp.norm.weight", "unexpected"])
        with self.assertRaisesRegex(ValueError, "colliding converted tensor"):
            converter.validate_output_key_coverage(["mtp.norm.weight", "mtp.norm.weight"], ["mtp.norm.weight"])

    def test_converter_cannot_write_success_receipt_after_dropping_one_mtp_key(self) -> None:
        output = self.root / "missing-mtp-output"
        with self.stub_conversion() as quantizer:
            original = quantizer.side_effect
            def omit_one(filename, keys):
                result = original(filename, keys)
                mtp = next(key for key in result["tensors"] if key.startswith("mtp."))
                result["tensors"].pop(mtp)
                return result
            quantizer.side_effect = omit_one
            with self.assertRaisesRegex(ValueError, "missing converted tensor identity"):
                converter.convert(self.source, output, self.policy.revision, self.policy.repo)
        self.assertFalse((output / "conversion-receipt.json").exists())
        self.assertFalse((output / "shard-digests.json").exists())

    def test_verifier_cli_manifest_requires_full_hashing(self) -> None:
        output = self.root / "manifest.json"
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as raised:
            verifier.main(["--source", str(self.source), "--output-manifest", str(output)])
        self.assertEqual(raised.exception.code, 2)
        self.assertFalse(output.exists())

    def test_verifier_cli_preserves_existing_manifest(self) -> None:
        output = self.root / "manifest.json"
        args = ["--source", str(self.source), "--hash-shards", "--output-manifest", str(output)]
        with patch.object(verifier, "verify_source", self.policy_verifier()), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(verifier.main(args), 0)
            before = output.read_bytes()
            with self.assertRaises(FileExistsError):
                verifier.main(args)
        self.assertEqual(output.read_bytes(), before)
        self.assertTrue(json.loads(before)["source_payloads_verified"])

    def test_verifier_cli_missing_source_is_read_only_and_fails(self) -> None:
        missing = self.root / "unavailable-volume" / "source"
        result = subprocess.run([sys.executable, "-B", str(Path(verifier.__file__)), "--source", str(missing), "--hash-shards"], capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 4, result.stderr)
        report = json.loads(result.stdout)
        self.assertFalse(report["ok"])
        self.assertFalse(report["source_payloads_verified"])
        self.assertFalse(missing.parent.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
