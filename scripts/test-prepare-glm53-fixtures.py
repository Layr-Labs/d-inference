#!/usr/bin/env python3
"""Stdlib-only tests for oracle identity, preparation and refusal; no model execution."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import struct
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).with_name("prepare-glm53-fixtures.py")
SPEC = importlib.util.spec_from_file_location("glm53_fixtures", SCRIPT)
FIXTURES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FIXTURES)


class GLM53FixtureContractTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()

    def test_pins_cover_official_target_vision_and_processors(self):
        self.assertEqual(FIXTURES.SOURCE_REVISION, "f0705f991a71f05dad9569336b181119f5546f93")
        self.assertEqual(FIXTURES.MODEL_REVISION, "91b69215804f2d2036a8867f6ce44848e278dcda")
        self.assertEqual(len(FIXTURES.SOURCE_HASHES), 8)
        self.assertIn("modeling_glm5_next.py", FIXTURES.SOURCE_HASHES)
        self.assertIn("image_processing_glm5_next.py", FIXTURES.SOURCE_HASHES)
        self.assertIn("video_processing_glm5_next.py", FIXTURES.SOURCE_HASHES)
        self.assertTrue(all(len(value) == 64 for value in FIXTURES.SOURCE_HASHES.values()))
        self.assertTrue(all(not name.endswith((".safetensors", ".py")) for name in FIXTURES.ASSET_HASHES))
        self.assertIn("tokenizer.json", FIXTURES.ASSET_HASHES)

    def test_existing_file_directory_dangling_link_and_link_parent_refuse(self):
        for name, kind in (("file", "file"), ("directory", "directory"), ("link", "link")):
            path = self.root / name
            if kind == "file":
                path.write_text("sentinel")
            elif kind == "directory":
                path.mkdir()
            else:
                path.symlink_to(self.root / "missing")
            with self.assertRaises(FileExistsError):
                FIXTURES.OutputDirectory(path)
        real = self.root / "real"
        real.mkdir()
        alias = self.root / "alias"
        alias.symlink_to(real, target_is_directory=True)
        with self.assertRaises(OSError):
            FIXTURES.OutputDirectory(alias / "output")
        self.assertFalse((real / "output").exists())
        self.assertEqual((self.root / "file").read_text(), "sentinel")

    def test_outputs_are_exclusive_private_and_descriptor_relative(self):
        path = self.root / "output"
        with FIXTURES.OutputDirectory(path) as output:
            output.write("one.json", b"{}")
            with self.assertRaises(FileExistsError):
                output.write("one.json", b"bad")
            with self.assertRaises(ValueError):
                output.write("../escape", b"bad")
            moved = self.root / "moved"
            path.rename(moved)
            path.symlink_to(self.root, target_is_directory=True)
            output.write("two.json", b"anchored")
        self.assertEqual((moved / "two.json").read_bytes(), b"anchored")
        self.assertFalse((self.root / "two.json").exists())
        self.assertEqual((moved.stat().st_mode & 0o777), 0o700)
        self.assertEqual(((moved / "one.json").stat().st_mode & 0o777), 0o600)

    def test_nonregular_input_is_rejected_without_blocking(self):
        directory = self.root / "directory"
        directory.mkdir()
        with self.assertRaises(ValueError):
            FIXTURES.read_regular(directory)
        fifo = self.root / "fifo"
        os.mkfifo(fifo)
        with self.assertRaises(ValueError):
            FIXTURES.read_regular(fifo)
        link = self.root / "link"
        link.symlink_to(directory)
        with self.assertRaises(OSError):
            FIXTURES.read_regular(link)

    def test_preparation_checks_bytes_and_preserves_failure(self):
        expected = hashlib.sha256(b"pinned").hexdigest()
        with patch.object(FIXTURES, "ASSET_HASHES", {"config.json": expected}), \
                patch.object(FIXTURES, "fetch_asset", return_value=b"wrong"):
            with self.assertRaisesRegex(ValueError, "asset changed"):
                FIXTURES.prepare(self.root / "failed")
        self.assertFalse((self.root / "failed/config.json").exists())
        self.assertFalse(json.loads((self.root / "failed/failure.json").read_text())["complete"])

    def test_metadata_preparation_is_reproducible_and_offline_source_is_checked(self):
        source = self.root / "source"
        source.mkdir()
        (source / "config.json").write_bytes(b"pinned")
        expected = hashlib.sha256(b"pinned").hexdigest()
        with patch.object(FIXTURES, "ASSET_HASHES", {"config.json": expected}):
            for name in ("left", "right"):
                FIXTURES.prepare(self.root / name, source)
            self.assertEqual((self.root / "left/config.json").read_bytes(), b"pinned")
            self.assertEqual((self.root / "left/provenance.json").read_bytes(),
                             (self.root / "right/provenance.json").read_bytes())
        self.assertNotIn("torch", sys.modules)

    def test_tiny_geometry_keeps_mixed_layers_pool_boundary_and_official_semantics(self):
        original = {"model_type": "glm5_next", "quantization_config": {"quant_method": "fp8"},
                    "text_config": {"hc_mult": 4, "rms_norm_eps": 1e-5, "hc_eps": 1e-6,
                                    "swiglu_limit": 10, "routed_scaling_factor": 2.5},
                    "vision_config": {"patch_size": 14, "temporal_patch_size": 2,
                                      "spatial_merge_size": 2}}
        tiny = FIXTURES.tiny_configuration(original)
        text, vision = tiny["text_config"], tiny["vision_config"]
        self.assertEqual(text["layer_types"], ["linear_attention"] * 3 + ["deepseek_sparse_attention"])
        self.assertEqual(text["qk_head_dim"], text["qk_nope_head_dim"])
        self.assertEqual(text["qk_head_dim"], 8)
        self.assertEqual(text["linear_attn_config"]["kda_layers"], [0, 1, 2])
        self.assertEqual(text["linear_attn_config"]["full_attn_layers"], [3])
        self.assertEqual(text["num_nextn_predict_layers"], 0)
        self.assertNotIn("rope_parameters", vision)
        self.assertNotIn("dtype", vision)
        self.assertEqual(text["index_kpool"], 4)
        self.assertEqual(text["index_topk"], 8)
        self.assertEqual((text["hc_mult"], text["hc_eps"], text["rms_norm_eps"]), (4, 1e-6, 1e-5))
        self.assertEqual(vision["patch_size"], 14)
        self.assertEqual(vision["temporal_patch_size"], 2)
        self.assertNotIn("quantization_config", tiny)
        self.assertIn("quantization_config", original)
        self.assertEqual(text["dtype"], "float32")

    def test_transformers_constructor_dialect_never_mutates_native_configuration(self):
        native = {"text_config": {"layer_types": ["linear_attention", "deepseek_sparse_attention"],
                                  "num_nextn_predict_layers": 0}, "vision_config": {"depth": 2}}
        hf, changes = FIXTURES.transformers_configuration(native)
        self.assertEqual(hf["text_config"]["layer_types"], ["linear_attention", "indexed_attention"])
        self.assertEqual(native["text_config"]["layer_types"][-1], "deepseek_sparse_attention")
        self.assertNotIn("rope_parameters", native["vision_config"])
        self.assertEqual(hf["vision_config"]["rope_parameters"]["rope_type"], "axial")
        self.assertEqual(hf["text_config"]["num_nextn_predict_layers"], 0)
        self.assertEqual([item["path"] for item in changes],
                         ["text_config.layer_types", "vision_config.rope_parameters"])

    def test_target_only_intent_replaces_inherited_mtp_declaration(self):
        native = FIXTURES.tiny_configuration({"model_type": "glm5_next",
            "text_config": {"num_nextn_predict_layers": 1}, "vision_config": {}})
        self.assertEqual(native["text_config"]["num_nextn_predict_layers"], 0)

    def test_cpu_generation_requires_explicit_approval_before_import_or_io(self):
        with self.assertRaisesRegex(ValueError, "resource window"):
            FIXTURES.generate(self.root / "missing", self.root / "output", "")
        with self.assertRaisesRegex(ValueError, "seed"):
            FIXTURES.generate(self.root / "missing", self.root / "output", "approved", -1)
        self.assertFalse((self.root / "output").exists())
        self.assertNotIn("torch", sys.modules)

    def test_cli_cannot_accidentally_generate_without_resource_window(self):
        result = subprocess.run([sys.executable, "-B", str(SCRIPT), "generate", "--assets", ".",
                                 "--output", str(self.root / "output")],
                                capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--resource-window", result.stderr)
        self.assertFalse((self.root / "output").exists())

    def test_tolerances_and_empty_oracle_guard_are_explicit(self):
        self.assertEqual(FIXTURES.TOLERANCES["integer_and_boolean"], {"atol": 0, "rtol": 0})
        self.assertLessEqual(FIXTURES.TOLERANCES["float32"]["atol"], 3e-5)
        source = SCRIPT.read_text()
        self.assertIn("zero-tensor oracle is not a fixture", source)
        self.assertIn("synthetic", source)
        self.assertNotIn("from_pretrained(\"zai-org", source)
        self.assertNotIn("trust_remote_code=True", source)
        self.assertIn('model.set_attn_implementation("eager")', source)
        self.assertIn('model.set_experts_implementation("eager")', source)
        self.assertIn('"observed_execution_backends": execution_backends', source)

    def test_environment_rejects_missing_and_wrong_dependency_versions(self):
        metadata = FIXTURES.importlib.metadata
        with patch.object(metadata, "distributions", return_value=[]), \
                patch.object(metadata, "version", side_effect=metadata.PackageNotFoundError):
            with self.assertRaisesRegex(RuntimeError, "missing oracle dependency"):
                FIXTURES.environment_manifest()
        with patch.object(metadata, "distributions", return_value=[]), \
                patch.object(metadata, "version", return_value="unreviewed"):
            with self.assertRaisesRegex(RuntimeError, "dependency mismatch"):
                FIXTURES.environment_manifest()

    def test_environment_rejects_same_version_from_wrong_source_commit(self):
        distribution = SimpleNamespace(read_text=lambda name: json.dumps({
            "url": "https://github.com/huggingface/transformers.git",
            "vcs_info": {"commit_id": "0" * 40}}))
        metadata = FIXTURES.importlib.metadata
        with patch.object(metadata, "distributions", return_value=[]), \
                patch.object(metadata, "version", side_effect=lambda name: FIXTURES.PACKAGE_PINS[name]), \
                patch.object(metadata, "distribution", return_value=distribution):
            with self.assertRaisesRegex(RuntimeError, "exact official git commit"):
                FIXTURES.environment_manifest()

    def test_environment_rejects_modified_official_module_bytes(self):
        source = self.root / "package/transformers/models/glm5_next"
        source.mkdir(parents=True)
        (source / "model.py").write_bytes(b"modified")
        distribution = SimpleNamespace(
            read_text=lambda name: json.dumps({"url": "https://github.com/huggingface/transformers.git",
                       "vcs_info": {"commit_id": FIXTURES.SOURCE_REVISION}}),
            locate_file=lambda name: self.root / "package" / name)
        metadata = FIXTURES.importlib.metadata
        with patch.object(metadata, "distributions", return_value=[]), \
                patch.object(metadata, "version", side_effect=lambda name: FIXTURES.PACKAGE_PINS[name]), \
                patch.object(metadata, "distribution", return_value=distribution), \
                patch.object(FIXTURES, "SOURCE_HASHES", {"model.py": "0" * 64}):
            with self.assertRaisesRegex(RuntimeError, "source changed"):
                FIXTURES.environment_manifest()


def fixture_config():
    return {"text_config": {**FIXTURES.TEXT_OVERRIDES, "hc_mult": 4},
            "vision_config": {**FIXTURES.VISION_OVERRIDES, "in_channels": 3,
                              "patch_size": 14, "temporal_patch_size": 2, "spatial_merge_size": 2}}


def raw_tensor(shape):
    # Include negative zero and distinct NaN payloads: equality must concern bits,
    # not floating-point equality, casting or arithmetic.
    count = FIXTURES.math.prod(shape)
    words = [0x80000000, 0x7FC00001, 0xFFC00002, 0x3F800000]
    return {"dtype": "F32", "shape": shape,
            "data": b"".join(struct.pack("<I", words[i % len(words)] ^ i) for i in range(count))}


class CanonicalFixtureMappingTests(unittest.TestCase):
    def test_serialization_preserves_exact_float_bits(self):
        tensors = {"values": raw_tensor([2, 4])}
        data = FIXTURES.encode_safetensors(tensors)
        self.assertEqual(FIXTURES.decode_safetensors(data), tensors)
        with self.assertRaisesRegex(ValueError, "archive"):
            FIXTURES.decode_safetensors(data[:7])

    def test_parser_rejects_duplicates_wrong_spans_and_nonpositive_shapes(self):
        duplicate = b'{"a":{"dtype":"F32","shape":[1],"data_offsets":[0,4]},"a":{}}'
        with self.assertRaisesRegex(ValueError, "duplicate"):
            FIXTURES.decode_safetensors(struct.pack("<Q", len(duplicate)) + duplicate + b"1234")
        bad = json.dumps({"a": {"dtype": "F32", "shape": [1], "data_offsets": [1, 5]}}).encode()
        with self.assertRaisesRegex(ValueError, "gap"):
            FIXTURES.decode_safetensors(struct.pack("<Q", len(bad)) + bad + b"12345")
        for shape in ([0], [-1], [True], []):
            with self.assertRaises(ValueError):
                FIXTURES.tensor_bytes("F32", shape)

    def test_native_schema_is_complete_float32_target_and_vision_without_mtp(self):
        schema = FIXTURES.native_fixture_schema(fixture_config())
        self.assertEqual(len(schema), 159)
        self.assertEqual(schema["model.language_model.layers.0.hc_attn_fn"], [24, 64])
        self.assertEqual(schema["model.language_model.layers.0.self_attn.q_conv1d.weight"], [16, 1, 4])
        self.assertEqual(schema["model.language_model.layers.3.mlp.experts.3.up_proj.weight"], [24, 16])
        self.assertEqual(schema["model.visual.patch_embed.proj.weight"], [16, 3, 2, 14, 14])
        self.assertFalse(any("layers.4." in name for name in schema))
        config = fixture_config()
        config["text_config"]["num_nextn_predict_layers"] = 1
        with self.assertRaisesRegex(ValueError, "target-only"):
            FIXTURES.native_fixture_schema(config)

    def test_hc_rename_and_forget_gate_flattening_preserve_payload(self):
        sources = {
            "model.language_model.layers.0.attn_hc.fn": raw_tensor([24, 64]),
            "model.language_model.layers.0.ffn_hc.scale": raw_tensor([3]),
            "model.language_model.layers.0.self_attn.forget_gate.f_a_proj.weight": raw_tensor([8, 16]),
        }
        expected = {
            "model.language_model.layers.0.hc_attn_fn": [24, 64],
            "model.language_model.layers.0.hc_ffn_scale": [3],
            "model.language_model.layers.0.self_attn.f_a_proj.weight": [8, 16],
        }
        with patch.object(FIXTURES, "native_fixture_schema", return_value=expected):
            mapped, operations = FIXTURES.canonical_weight_mapping(sources, fixture_config())
        for source, record in zip(sorted(sources), operations):
            self.assertEqual(record["operation"], "rename")
            self.assertEqual(mapped[record["destinations"][0]["name"]]["data"], sources[source]["data"])

    def test_convolution_split_has_q_k_v_order_and_exact_inverse(self):
        prefix = "model.language_model.layers.0.self_attn"
        source = raw_tensor([48, 1, 4])
        expected = {prefix + f".{name}_conv1d.weight": [16, 1, 4] for name in ("q", "k", "v")}
        with patch.object(FIXTURES, "native_fixture_schema", return_value=expected):
            mapped, operations = FIXTURES.canonical_weight_mapping({prefix + ".conv1d.weight": source}, fixture_config())
        pieces = [mapped[prefix + f".{name}_conv1d.weight"]["data"] for name in ("q", "k", "v")]
        self.assertEqual(pieces[1], source["data"][256:512])
        self.assertEqual(b"".join(pieces), source["data"])
        self.assertTrue(operations[0]["bitwise_equal"])

    def test_experts_split_each_gate_up_pair_before_next_expert(self):
        prefix = "model.language_model.layers.3.mlp.experts"
        sources = {prefix + ".gate_up_proj": raw_tensor([4, 48, 16]),
                   prefix + ".down_proj": raw_tensor([4, 16, 24])}
        expected = {prefix + f".{expert}.{name}_proj.weight": shape
                    for expert in range(4) for name, shape in
                    (("gate", [24, 16]), ("up", [24, 16]), ("down", [16, 24]))}
        with patch.object(FIXTURES, "native_fixture_schema", return_value=expected):
            mapped, operations = FIXTURES.canonical_weight_mapping(sources, fixture_config())
        for record in operations:
            data = b"".join(mapped[d["name"]]["data"] for d in record["destinations"])
            self.assertEqual(data, sources[record["source"]]["data"])
        gate = mapped[prefix + ".1.gate_proj.weight"]["data"]
        self.assertEqual(gate, sources[prefix + ".gate_up_proj"]["data"][3072:4608])

    def test_missing_extra_and_malformed_tensors_fail_closed(self):
        expected = {"allowed": [1]}
        with patch.object(FIXTURES, "native_fixture_schema", return_value=expected):
            for tensors, reason in (({}, "missing"), ({"unknown": raw_tensor([1])}, "unexpected"),
                                    ({"allowed": raw_tensor([2])}, "malformed")):
                with self.assertRaisesRegex(ValueError, reason):
                    FIXTURES.canonical_weight_mapping(tensors, fixture_config())

    def test_case_index_refuses_missing_expected_traces(self):
        with self.assertRaisesRegex(ValueError, "missing expected oracle key"):
            FIXTURES.compact_case_index(set())

    def test_colliding_source_names_are_not_silently_overwritten(self):
        canonical = "model.language_model.layers.0.hc_attn_scale"
        legacy = "model.language_model.layers.0.attn_hc.scale"
        with patch.object(FIXTURES, "native_fixture_schema", return_value={canonical: [3]}):
            with self.assertRaisesRegex(ValueError, "duplicate canonical destination"):
                FIXTURES.canonical_weight_mapping(
                    {canonical: raw_tensor([3]), legacy: raw_tensor([3])}, fixture_config())

    def test_packed_or_non_float32_weights_are_not_converted(self):
        tensor = {"shape": [1], "dtype": "U32", "data": b"\x12\x34\x56\x78"}
        with patch.object(FIXTURES, "native_fixture_schema", return_value={"weight": [1]}):
            with self.assertRaisesRegex(ValueError, "only complete F32 synthetic weights"):
                FIXTURES.canonical_weight_mapping({"weight": tensor}, fixture_config())


if __name__ == "__main__":
    unittest.main()
