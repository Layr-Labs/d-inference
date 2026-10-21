"""CPU-only synthetic tests: no real MLX import, model files or network access.

A stub `mlx.core` records transforms and writes real safetensors headers with
synthetic payloads. The tests prove naming, policy, provenance and receipt
wiring; they do not prove quantization numerics or model execution.
"""
from __future__ import annotations

import contextlib
import copy
import functools
import hashlib
import importlib.metadata
import io
import json
import math
import shutil
import struct
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

import compare_pack_layout as compare
import convert_pplx_decider_q4 as converter
import pplx_decider_provenance as provenance
import verify_pplx_decider_download as verifier

ST_TO_STUB = {"BF16": "bfloat16", "U32": "uint32", "F32": "float32"}
STUB_TO_ST = {value: key for key, value in ST_TO_STUB.items()}
ITEM_SIZE = {"BF16": 2, "U32": 4, "F32": 4}
SHARDS = ("model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors")
DECIDER_TENSORS = {
    SHARDS[0]: {
        "language_model.embed_tokens.weight": [300, 128],
        "language_model.layers.0.input_layernorm.weight": [128],
        "language_model.layers.0.post_attention_layernorm.weight": [128],
        "language_model.layers.0.linear_attn.conv1d.weight": [256, 1, 4],
        "language_model.layers.0.linear_attn.A_log": [4],
        "language_model.layers.0.linear_attn.dt_bias": [4],
        "language_model.layers.0.linear_attn.in_proj_qkv.weight": [256, 128],
        "language_model.layers.0.linear_attn.norm.weight": [32],
    },
    SHARDS[1]: {
        "language_model.layers.1.self_attn.q_norm.weight": [32],
        "language_model.layers.1.self_attn.k_norm.weight": [32],
        "language_model.layers.1.self_attn.q_proj.weight": [64, 128],
        "language_model.norm.weight": [128],
        "visual.patch_embed.proj.weight": [16, 3, 2, 4, 4],
        "visual.patch_embed.proj.bias": [16],
        "visual.blocks.0.attn.qkv.weight": [48, 16],
        "visual.pos_embed.weight": [8, 16],
    },
}
DECIDER_PROCESSOR = {
    "image_processor": {
        "do_convert_rgb": True, "do_normalize": True, "do_rescale": True, "do_resize": True,
        "image_mean": [0.5, 0.5, 0.5], "image_processor_type": "Qwen2VLImageProcessor",
        "image_std": [0.5, 0.5, 0.5], "merge_size": 2, "patch_size": 16, "resample": 3,
        "rescale_factor": 0.00392156862745098, "size": {"longest_edge": 262144, "shortest_edge": 65536},
        "temporal_patch_size": 2,
    },
    "processor_class": "Qwen3VLProcessor",
    "video_processor": {
        "do_convert_rgb": True, "do_normalize": True, "do_rescale": True, "do_resize": True,
        "do_sample_frames": True, "fps": 2, "image_mean": [0.5, 0.5, 0.5], "image_std": [0.5, 0.5, 0.5],
        "max_frames": 768, "max_video_tokens": 768, "merge_size": 2, "min_frames": 4, "patch_size": 16,
        "resample": 3, "rescale_factor": 0.00392156862745098, "return_metadata": False,
        "size": {"longest_edge": 25165824, "shortest_edge": 4096}, "temporal_patch_size": 2,
        "video_processor_type": "Qwen3VLVideoProcessor",
    },
}
# SHA-256 of the three processor files in EigenLabs/Qwen3.8-27B-4bit at the pinned revision.
SERVED_PROCESSOR_SHA256 = {
    "preprocessor_config.json": "27225450ac9c6529872ee1924fcb0962ff5634834f817040f444118116f4e516",
    "processor_config.json": "45fc17c8dd2474af6b493b52483c26c0584b0082d368c480f9fa611e73070040",
    "video_preprocessor_config.json": "7768af27c1fafa9cc9011c1dc20067e03f8915e03b63504550e11d5066986d13",
}


def write_safetensors(path: Path, tensors: dict[str, tuple[str, list[int], bytes]], metadata: dict | None) -> None:
    header: dict = {}
    blobs: list[bytes] = []
    offset = 0
    for name in sorted(tensors):
        dtype, shape, data = tensors[name]
        header[name] = {"dtype": dtype, "shape": list(shape), "data_offsets": [offset, offset + len(data)]}
        offset += len(data)
        blobs.append(data)
    if metadata:
        header["__metadata__"] = metadata
    raw = json.dumps(header).encode()
    raw += b" " * (-len(raw) % 8)
    path.write_bytes(struct.pack("<Q", len(raw)) + raw + b"".join(blobs))


def zeros(dtype: str, shape: list[int]) -> bytes:
    return bytes(math.prod(shape) * ITEM_SIZE[dtype])


class FakeArray:
    def __init__(self, shape, dtype: str = "bfloat16", origin: str = "", ops: tuple = ()) -> None:
        self.shape = tuple(int(dim) for dim in shape)
        self.dtype = dtype
        self.origin = origin
        self.ops = ops

    @property
    def ndim(self) -> int:
        return len(self.shape)

    def derive(self, shape, op: str, dtype: str | None = None) -> "FakeArray":
        return FakeArray(shape, dtype or self.dtype, self.origin, self.ops + (op,))

    def moveaxis(self, source: int, dest: int) -> "FakeArray":
        shape = list(self.shape)
        shape.insert(dest, shape.pop(source))
        return self.derive(shape, f"moveaxis({source},{dest})")

    def transpose(self, *axes: int) -> "FakeArray":
        return self.derive([self.shape[i] for i in axes], f"transpose{axes}")

    def __add__(self, other: float) -> "FakeArray":
        return self.derive(self.shape, f"add({other})")

    def astype(self, dtype: str) -> "FakeArray":
        return self if dtype == self.dtype else self.derive(self.shape, f"astype({dtype})", dtype)

    def payload(self) -> bytes:
        seed = hashlib.sha256(repr((self.origin.split(":", 1)[-1], self.ops)).encode()).digest()[0]
        return bytes([seed]) * (math.prod(self.shape) * ITEM_SIZE[STUB_TO_ST[self.dtype]])


def stub_core(saved: dict) -> types.ModuleType:
    core = types.ModuleType("mlx.core")
    core.cpu = "cpu"
    core.bfloat16 = "bfloat16"

    def load(path: str, stream=None) -> dict:
        tensors, _, _ = provenance.read_safetensors_header(Path(path))
        return {key: FakeArray(entry["shape"], ST_TO_STUB[entry["dtype"]], f"{Path(path).name}:{key}")
                for key, entry in tensors.items()}

    def quantize(value: FakeArray, group_size: int, bits: int, mode: str):
        rows, cols = value.shape
        op = f"quantize({group_size},{bits},{mode})"
        return (value.derive((rows, cols * bits // 32), op, "uint32"),
                value.derive((rows, cols // group_size), op + ".scales"),
                value.derive((rows, cols // group_size), op + ".biases"))

    def save(path: str, tensors: dict, metadata: dict | None = None) -> None:
        saved[Path(path).name] = (dict(tensors), metadata)
        write_safetensors(Path(path), {key: (STUB_TO_ST[v.dtype], list(v.shape), v.payload())
                                       for key, v in tensors.items()}, metadata)

    core.load = load
    core.quantize = quantize
    core.save_safetensors = save
    core.eval = lambda *arrays: None
    core.reset_peak_memory = lambda: None
    core.clear_cache = lambda: None
    core.synchronize = lambda: None
    core.get_peak_memory = lambda: 1
    return core


class Fixture(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="synthetic-pplx-", dir=Path(__file__).parent)
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def write(self, source: Path, name: str, value) -> None:
        payload = value if isinstance(value, bytes) else json.dumps(value).encode()
        (source / name).write_bytes(payload)

    def write_shards(self, source: Path, tensors: dict, shard_format: str = "pt") -> None:
        for shard, entries in tensors.items():
            write_safetensors(source / shard, {k: ("BF16", s, zeros("BF16", s)) for k, s in entries.items()},
                              {"format": shard_format})
        weight_map = {key: shard for shard, entries in tensors.items() for key in entries}
        self.write(source, provenance.INDEX, {"metadata": {"total_size": 1}, "weight_map": weight_map})

    def config(self) -> dict:
        return {
            "architectures": ["Qwen3_5Model"],
            "model_type": "qwen3_5",
            "tie_word_embeddings": False,
            "text_config": {"model_type": "qwen3_5_text", "hidden_size": 128, "vocab_size": 300,
                            "tie_word_embeddings": False},
            "vision_config": {"in_channels": 3, "depth": 1},
        }

    def make_decider(self, name: str = "decider", tensors: dict | None = None, shard_format: str = "pt",
                     readout_shape: tuple[int, int] = (3, 128),
                     vocab: dict | None = None) -> tuple[Path, provenance.ReleasePolicy]:
        source = self.root / name
        source.mkdir()
        self.write_shards(source, tensors or DECIDER_TENSORS, shard_format)
        write_safetensors(source / converter.READOUT,
                          {"weight": ("BF16", list(readout_shape), zeros("BF16", list(readout_shape)))}, {"format": "pt"})
        self.write(source, "config.json", self.config())
        self.write(source, "decision_config.json", {
            "step": 200, "provenance": {"run": "synthetic"}, "format_version": 1,
            "base_model": provenance.BASE_REPO, "revision": provenance.BASE_REVISION,
            "codes": ["A", "B", "C"], "token_ids": [10, 11, 12], "temperature": 2.25})
        self.write(source, "tokenizer.json", {"model": {"vocab": vocab or {"A": 10, "B": 11, "C": 12, "D": 13}}})
        self.write(source, "tokenizer_config.json", {"tokenizer_class": "Qwen2Tokenizer"})
        self.write(source, "chat_template.jinja", b"synthetic template\n")
        self.write(source, "processor_config.json", DECIDER_PROCESSOR)
        self.write(source, "LICENSE", b"synthetic license\n")
        self.write(source, "NOTICE", b"synthetic notice\n")
        listed = sorted(p.name for p in source.iterdir() if p.name not in ("LICENSE", "NOTICE"))
        manifest = {"model": provenance.SOURCE_REPO, "base_model": provenance.BASE_REPO, "files": {
            n: {"bytes": (source / n).stat().st_size, "sha256": provenance.sha256_file(source / n)} for n in listed}}
        self.write(source, provenance.RELEASE_MANIFEST, manifest)
        self.write(source, provenance.MARKER, {"repo": provenance.SOURCE_REPO, "revision": provenance.SOURCE_REVISION})
        policy = provenance.ReleasePolicy(
            provenance.SOURCE_REPO, provenance.SOURCE_REVISION,
            provenance.sha256_file(source / provenance.RELEASE_MANIFEST),
            {n: provenance.sha256_file(source / n) for n in ("LICENSE", "NOTICE")})
        return source, policy

    def hub_metadata(self, source: Path, repo: str, revision: str) -> None:
        cache = source / ".cache" / "huggingface" / "download"
        cache.mkdir(parents=True, exist_ok=True)
        shards = set(json.loads((source / provenance.INDEX).read_text())["weight_map"].values())
        for name in ("config.json", provenance.INDEX, *shards):
            etag = provenance.sha256_file(source / name) if name in shards else "git-blob-etag"
            (cache / f"{name}.metadata").write_text(f"{revision}\n{etag}\n0\n")
        self.write(source, provenance.MARKER, {"repo": repo, "revision": revision})

    def make_base(self, name: str = "base") -> Path:
        source = self.root / name
        source.mkdir()
        tensors = {shard: {("model." + k if not k.startswith("mtp.") else k): s for k, s in entries.items()}
                   for shard, entries in DECIDER_TENSORS.items()}
        tensors[SHARDS[1]]["lm_head.weight"] = [300, 128]
        tensors[SHARDS[1]]["mtp.fc.weight"] = [128, 256]
        self.write_shards(source, tensors)
        self.write(source, "config.json", self.config())
        self.write(source, "tokenizer.json", {"model": {"vocab": {}}})
        self.write(source, "LICENSE", b"base license\n")
        self.hub_metadata(source, provenance.BASE_REPO, provenance.BASE_REVISION)
        return source

    @contextlib.contextmanager
    def stub_mlx(self, policy: provenance.ReleasePolicy | None = None):
        saved: dict = {}
        core = stub_core(saved)
        package = types.ModuleType("mlx")
        package.core = core
        package.__path__ = []
        verify = functools.partial(provenance.verify_release, policy=policy) if policy else provenance.verify_release
        with patch.dict(sys.modules, {"mlx": package, "mlx.core": core}), \
                patch.object(converter, "verify_release", verify), \
                patch.object(converter, "runtime_provenance", return_value={"synthetic_stub": True}), \
                patch.object(converter.shutil, "disk_usage", return_value=types.SimpleNamespace(free=16 * 1024**3)), \
                contextlib.redirect_stdout(io.StringIO()):
            yield saved


class NamingAndPolicyTests(unittest.TestCase):
    def test_decider_layout_renames(self) -> None:
        cases = {
            "language_model.layers.7.mlp.up_proj.weight": "language_model.model.layers.7.mlp.up_proj.weight",
            "language_model.embed_tokens.weight": "language_model.model.embed_tokens.weight",
            "language_model.norm.weight": "language_model.model.norm.weight",
            "visual.blocks.0.attn.qkv.weight": "vision_tower.blocks.0.attn.qkv.weight",
            "visual.patch_embed.proj.weight": "vision_tower.patch_embed.proj.weight",
        }
        for source, target in cases.items():
            with self.subTest(source=source):
                self.assertEqual(converter.pack_key(source), target)

    def test_upstream_layout_renames_and_drops(self) -> None:
        cases = {
            "model.language_model.layers.0.linear_attn.A_log": "language_model.model.layers.0.linear_attn.A_log",
            "model.language_model.norm.weight": "language_model.model.norm.weight",
            "model.visual.merger.linear_fc1.weight": "vision_tower.merger.linear_fc1.weight",
            "lm_head.weight": "language_model.lm_head.weight",
            "mtp.layers.0.mlp.up_proj.weight": None,
            "model.visual.position_ids": None,
        }
        for source, target in cases.items():
            with self.subTest(source=source):
                self.assertEqual(converter.pack_key(source), target)

    def test_unknown_or_converted_names_are_refused(self) -> None:
        for key in ("vision_tower.blocks.0.attn.qkv.weight", "language_model.model.norm.weight",
                    "model.language_model.model.norm.weight", "extra.weight"):
            with self.subTest(key=key), self.assertRaises(ValueError):
                converter.pack_key(key)

    def test_conv1d_norm_and_patch_embed_transforms(self) -> None:
        conv = "language_model.model.layers.0.linear_attn.conv1d.weight"
        self.assertEqual(converter.transform_for(conv, (256, 1, 4), 3), ("conv1d_moveaxis", (256, 4, 1)))
        self.assertEqual(converter.transform_for(conv, (256, 4, 1), 3), (None, (256, 4, 1)))
        for key in ("language_model.model.layers.0.input_layernorm.weight",
                    "language_model.model.layers.0.post_attention_layernorm.weight",
                    "language_model.model.norm.weight",
                    "language_model.model.layers.3.self_attn.q_norm.weight",
                    "language_model.model.layers.3.self_attn.k_norm.weight"):
            with self.subTest(key=key):
                self.assertEqual(converter.transform_for(key, (128,), 3), ("norm_plus_one", (128,)))
        for key in ("language_model.model.layers.0.linear_attn.norm.weight", "vision_tower.merger.norm.weight",
                    "vision_tower.blocks.0.norm1.weight"):
            with self.subTest(key=key):
                self.assertEqual(converter.transform_for(key, (128,), 3), (None, (128,)))
        patch_key = "vision_tower.patch_embed.proj.weight"
        self.assertEqual(converter.transform_for(patch_key, (1152, 3, 2, 16, 16), 3),
                         ("patch_embed_transpose", (1152, 2, 16, 16, 3)))
        self.assertEqual(converter.transform_for(patch_key, (1152, 2, 16, 16, 3), 3), (None, (1152, 2, 16, 16, 3)))
        array = FakeArray((256, 1, 4))
        self.assertEqual(converter.apply_transform("conv1d_moveaxis", array).shape, (256, 4, 1))
        self.assertEqual(converter.apply_transform("patch_embed_transpose", FakeArray((8, 3, 2, 4, 4))).shape, (8, 2, 4, 4, 3))
        self.assertEqual(converter.apply_transform("norm_plus_one", FakeArray((4,))).ops, ("add(1.0)",))

    def test_quantization_policy(self) -> None:
        self.assertTrue(converter.should_quantize("language_model.model.layers.0.mlp.up_proj.weight", (17408, 5120)))
        self.assertTrue(converter.should_quantize("language_model.model.layers.0.linear_attn.in_proj_a.weight", (48, 5120)))
        self.assertTrue(converter.should_quantize("language_model.model.embed_tokens.weight", (248320, 5120)))
        self.assertTrue(converter.should_quantize(converter.LM_HEAD, (248320, 5120)))
        self.assertFalse(converter.should_quantize("vision_tower.blocks.0.attn.qkv.weight", (3456, 1152)))
        self.assertFalse(converter.should_quantize("language_model.model.norm.weight", (5120,)))
        self.assertFalse(converter.should_quantize("language_model.model.layers.0.linear_attn.conv1d.weight", (10240, 4, 1)))
        with self.assertRaisesRegex(ValueError, "not divisible by 64"):
            converter.should_quantize("language_model.model.layers.0.mlp.up_proj.weight", (64, 160))

    def test_quantized_layout_matches_served_shapes(self) -> None:
        layout = converter.quantized_layout("language_model.model.layers.0.mlp.down_proj", (5120, 17408))
        self.assertEqual(layout["language_model.model.layers.0.mlp.down_proj.weight"], ("U32", (5120, 2176)))
        self.assertEqual(layout["language_model.model.layers.0.mlp.down_proj.scales"], ("BF16", (5120, 272)))

    def test_head_selection(self) -> None:
        lm_head = [converter.TensorPlan("lm_head.weight", converter.LM_HEAD, "x", (4, 64), (4, 64), None, True)]
        self.assertEqual(converter.select_head([], True), "readout")
        self.assertEqual(converter.select_head(lm_head, False), "source")
        with self.assertRaisesRegex(ValueError, "both"):
            converter.select_head(lm_head, True)
        with self.assertRaisesRegex(ValueError, "neither"):
            converter.select_head([], False)

    def test_key_coverage(self) -> None:
        converter.validate_output_key_coverage(["a.norm.weight", "a.proj.weight"],
                                               ["a.norm.weight", "a.proj.weight", "a.proj.scales", "a.proj.biases"])
        failures = {
            "missing converted": (["a.weight", "b.weight"], ["a.weight"]),
            "incomplete quantized": (["a.proj.weight"], ["a.proj.weight", "a.proj.scales"]),
            "unexpected converted": (["a.weight"], ["a.weight", "b.weight"]),
            "colliding converted": (["a.weight", "a.weight"], ["a.weight"]),
            "mtp": (["mtp.fc.weight"], ["mtp.fc.weight"]),
        }
        for message, (source, output) in failures.items():
            with self.subTest(message=message), self.assertRaisesRegex(ValueError, message):
                converter.validate_output_key_coverage(source, output)


class DecisionAndMetadataTests(unittest.TestCase):
    decision = {"step": 1, "provenance": {}, "base_model": "b", "revision": "r", "format_version": 1,
                "codes": ["A", "B", "AA"], "token_ids": [5, 6, 7], "temperature": 2.207568021892729}
    tokenizer = {"model": {"vocab": {"A": 5, "B": 6, "AA": 7}}}

    def test_decision_block_derivation(self) -> None:
        block = converter.decision_block(self.decision, self.tokenizer, 300)
        self.assertEqual(list(block), ["format_version", "options", "temperature", "codes", "token_ids", "max_input_tokens"])
        self.assertEqual(block["options"], 3)
        self.assertEqual(block["max_input_tokens"], 8192)
        self.assertEqual(block["temperature"], 2.207568021892729)

    def test_decision_block_refusals(self) -> None:
        variants = {
            "unknown key": {**self.decision, "extra": 1},
            "format": {**self.decision, "format_version": 2},
            "duplicate code": {**self.decision, "codes": ["A", "A", "AA"]},
            "code pattern": {**self.decision, "codes": ["A", "b", "AA"]},
            "length": {**self.decision, "token_ids": [5, 6]},
            "out of vocab": {**self.decision, "token_ids": [5, 6, 300]},
            "temperature": {**self.decision, "temperature": 0.0},
            "vocab mismatch": {**self.decision, "token_ids": [5, 7, 6]},
        }
        for name, decision in variants.items():
            with self.subTest(name=name), self.assertRaises(ValueError):
                converter.decision_block(decision, self.tokenizer, 300)

    def test_output_config(self) -> None:
        source = {"model_type": "qwen3_5", "text_config": {"vocab_size": 248320}, "architectures": ["Qwen3_5Model"]}
        decision = converter.decision_block(self.decision, self.tokenizer, 300)
        config = converter.output_config(source, decision)
        self.assertEqual(config["model_type"], "pplx_decider_qwen35")
        self.assertEqual(config["quantization"], {"group_size": 64, "bits": 4, "mode": "affine"})
        self.assertEqual(config["quantization_config"], config["quantization"])
        self.assertEqual(config["decision"], decision)
        self.assertEqual(config["text_config"], source["text_config"])
        self.assertEqual(converter.output_config(source, None)["model_type"], "qwen3_5")
        self.assertNotIn("decision", converter.output_config(source, None))

    def test_processor_files_reproduce_served_bytes(self) -> None:
        served = copy.deepcopy(DECIDER_PROCESSOR)
        served["image_processor"]["size"]["longest_edge"] = 16777216
        files = converter.derive_processor_files(served)
        self.assertEqual({n: hashlib.sha256(p).hexdigest() for n, p in files.items()}, SERVED_PROCESSOR_SHA256)

    def test_processor_files_carry_decider_values(self) -> None:
        files = {n: json.loads(p) for n, p in converter.derive_processor_files(DECIDER_PROCESSOR).items()}
        self.assertEqual(files["preprocessor_config.json"]["size"], {"longest_edge": 262144, "shortest_edge": 65536})
        self.assertEqual(files["preprocessor_config.json"]["image_processor_type"], "Qwen2VLImageProcessorFast")
        image, video = files["processor_config.json"]["image_processor"], files["processor_config.json"]["video_processor"]
        self.assertEqual((image["min_pixels"], image["max_pixels"]), (65536, 262144))
        self.assertEqual((video["min_pixels"], video["max_pixels"], video["fps"]), (4096, 25165824, 2.0))
        self.assertEqual((video["min_frames"], video["max_frames"]), (4, 768))
        self.assertEqual(files["video_preprocessor_config.json"]["size"], {"longest_edge": 25165824, "shortest_edge": 4096})

    def test_processor_files_refuse_missing_fields(self) -> None:
        broken = copy.deepcopy(DECIDER_PROCESSOR)
        del broken["video_processor"]["fps"]
        with self.assertRaisesRegex(ValueError, "served-layout field"):
            converter.derive_processor_files(broken)


class ProvenanceTests(Fixture):
    def setUp(self) -> None:
        super().setUp()
        self.source, self.policy = self.make_decider()

    def verify(self, **kwargs) -> dict:
        return provenance.verify_release(self.source, policy=self.policy, **kwargs)

    def test_pinned_constants(self) -> None:
        self.assertEqual(provenance.PINNED_RELEASE.manifest_sha256, provenance.RELEASE_MANIFEST_SHA256)
        for digest in (provenance.RELEASE_MANIFEST_SHA256, *provenance.EXTRA_PINS.values()):
            self.assertRegex(digest, provenance.SHA256_RE)
        self.assertEqual(set(provenance.EXTRA_PINS), {"LICENSE", "NOTICE"})

    def test_metadata_success_does_not_claim_payloads(self) -> None:
        report = self.verify()
        self.assertTrue(report["ok"], report["errors"])
        self.assertFalse(report["source_payloads_verified"])
        self.assertEqual(report["shards"], list(SHARDS))
        self.assertEqual(report["files"]["readout.safetensors"]["sha256"],
                         report["files"]["readout.safetensors"]["expected_sha256"])
        self.assertIsNone(report["files"][SHARDS[0]]["sha256"])

    def test_full_hash_verifies_every_shard(self) -> None:
        report = self.verify(hash_shards=True)
        self.assertTrue(report["ok"])
        self.assertTrue(report["source_payloads_verified"])
        self.assertEqual(report["shard_hash_checked"], 2)

    def test_tampered_manifest_is_refused(self) -> None:
        manifest = json.loads((self.source / provenance.RELEASE_MANIFEST).read_text())
        manifest["files"]["config.json"]["sha256"] = "0" * 64
        self.write(self.source, provenance.RELEASE_MANIFEST, manifest)
        report = self.verify()
        self.assertFalse(report["ok"])
        self.assertIn("release manifest missing or not the pinned manifest", report["errors"])

    def test_tampered_listed_and_extra_files_are_refused(self) -> None:
        for name in ("config.json", "readout.safetensors", "NOTICE"):
            with self.subTest(name=name):
                original = (self.source / name).read_bytes()
                (self.source / name).write_bytes(original[:-1] + bytes([original[-1] ^ 1]))
                self.assertIn(f"source file hash mismatch: {name}", self.verify()["errors"])
                (self.source / name).write_bytes(original)

    def test_missing_files_are_refused(self) -> None:
        for name in ("LICENSE", "tokenizer.json"):
            with self.subTest(name=name):
                original = (self.source / name).read_bytes()
                (self.source / name).unlink()
                self.assertIn(f"missing source file: {name}", self.verify()["errors"])
                (self.source / name).write_bytes(original)

    def test_shard_size_and_payload_checks(self) -> None:
        path = self.source / SHARDS[0]
        original = path.read_bytes()
        path.write_bytes(original[:-1] + b"\x01")
        self.assertTrue(self.verify()["ok"])
        self.assertIn(f"source shard payload hash mismatch: {SHARDS[0]}", self.verify(hash_shards=True)["errors"])
        path.write_bytes(original + b"\x00")
        self.assertIn(f"source file size mismatch: {SHARDS[0]}", self.verify()["errors"])

    def test_marker_must_name_the_pinned_revision(self) -> None:
        self.write(self.source, provenance.MARKER, {"repo": provenance.SOURCE_REPO, "revision": "0" * 40})
        self.assertIn("download marker repository/revision mismatch", self.verify()["errors"])
        (self.source / provenance.MARKER).unlink()
        self.assertIn("missing or invalid download marker", self.verify()["errors"])

    def test_unsafe_manifest_names_are_refused(self) -> None:
        manifest = json.loads((self.source / provenance.RELEASE_MANIFEST).read_text())
        manifest["files"]["../escape"] = {"bytes": 1, "sha256": "0" * 64}
        self.write(self.source, provenance.RELEASE_MANIFEST, manifest)
        policy = provenance.ReleasePolicy(self.policy.repo, self.policy.revision,
                                          provenance.sha256_file(self.source / provenance.RELEASE_MANIFEST),
                                          self.policy.extra_pins)
        report = provenance.verify_release(self.source, policy=policy)
        self.assertIn("invalid release manifest entry: '../escape'", report["errors"])

    def test_hub_snapshot_identity(self) -> None:
        base = self.make_base()
        report = provenance.verify_hub_snapshot(base, provenance.BASE_REPO, provenance.BASE_REVISION, hash_shards=True)
        self.assertTrue(report["ok"], report["errors"])
        self.assertTrue(report["source_payloads_verified"])
        cache = base / ".cache" / "huggingface" / "download"
        (cache / "config.json.metadata").write_text("0" * 40 + "\netag\n")
        report = provenance.verify_hub_snapshot(base, provenance.BASE_REPO, provenance.BASE_REVISION)
        self.assertIn("cached revision missing or mismatched: config.json", report["errors"])
        self.hub_metadata(base, provenance.BASE_REPO, provenance.BASE_REVISION)
        (cache / f"{SHARDS[1]}.metadata").write_text(f"{provenance.BASE_REVISION}\nnot-a-sha\n")
        report = provenance.verify_hub_snapshot(base, provenance.BASE_REPO, provenance.BASE_REVISION)
        self.assertIn(f"missing or invalid shard SHA-256 etag: {SHARDS[1]}", report["errors"])

    def test_shard_manifest_requires_complete_verified_coverage(self) -> None:
        evidence = self.verify()
        consumed = {name: evidence["files"][name]["expected_sha256"] for name in (*SHARDS, "readout.safetensors")}
        outputs = [{"file": name, "bytes": 1, "sha256": "a" * 64} for name in SHARDS]
        manifest = provenance.make_shard_manifest(evidence, consumed, outputs)
        self.assertEqual(manifest["release_manifest_sha256"], self.policy.manifest_sha256)
        with self.assertRaisesRegex(ValueError, "output digest coverage"):
            provenance.make_shard_manifest(evidence, consumed, outputs[:1])
        with self.assertRaisesRegex(ValueError, "unverified source digest"):
            provenance.make_shard_manifest(evidence, {**consumed, SHARDS[0]: "0" * 64}, outputs)
        with self.assertRaisesRegex(ValueError, "payload coverage"):
            provenance.make_shard_manifest(evidence, {SHARDS[0]: consumed[SHARDS[0]]}, outputs)

    def test_runtime_provenance_hides_urls(self) -> None:
        core_file = self.root / "synthetic-core.so"
        core_file.write_bytes(b"synthetic runtime")
        metadata = {"METADATA": "Version: 0.32.0", "direct_url.json": '{"url":"https://user:secret@example.invalid/x"}'}
        distribution = types.SimpleNamespace(version="0.32.0", read_text=metadata.get)
        with patch.object(importlib.metadata, "distribution", return_value=distribution):
            report = provenance.runtime_provenance(types.SimpleNamespace(__file__=str(core_file)))
        self.assertEqual(report["mlx_distribution_version"], "0.32.0")
        self.assertNotIn("secret", json.dumps(report))

    def test_verifier_cli(self) -> None:
        manifest = self.root / "receipt.json"
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as raised:
            verifier.main(["--source", str(self.source), "--output-manifest", str(manifest)])
        self.assertEqual(raised.exception.code, 2)
        args = ["--source", str(self.source), "--hash-shards", "--output-manifest", str(manifest)]
        verify = functools.partial(provenance.verify_release, policy=self.policy)
        with patch.object(verifier, "verify_release", verify), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(verifier.main(args), 0)
            with self.assertRaises(FileExistsError):
                verifier.main(args)
        self.assertTrue(json.loads(manifest.read_text())["source_payloads_verified"])
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(verifier.main(["--source", str(self.source)]), 4)


class ConverterTests(Fixture):
    def convert(self, source: Path, policy, name: str = "out") -> tuple[dict, Path, dict]:
        output = self.root / name
        with self.stub_mlx(policy) as saved:
            receipt = converter.convert(source, output, mode="decider")
        return receipt, output, saved

    def test_decider_conversion_writes_the_contract(self) -> None:
        source, policy = self.make_decider()
        receipt, output, saved = self.convert(source, policy)
        index = json.loads((output / provenance.INDEX).read_text())
        self.assertEqual(index["metadata"]["format"], "mlx")
        self.assertEqual(len(index["weight_map"]), 23)
        self.assertEqual(index["weight_map"][converter.LM_HEAD], SHARDS[1])
        self.assertNotIn("language_model.lm_head.scales", index["weight_map"])
        written = {}
        for shard in SHARDS:
            tensors, metadata, _ = provenance.read_safetensors_header(output / shard)
            self.assertEqual(metadata, {"format": "mlx"})
            written.update(tensors)
        self.assertEqual(index["metadata"]["total_size"],
                         sum(e["data_offsets"][1] - e["data_offsets"][0] for e in written.values()))
        self.assertEqual(written[converter.LM_HEAD]["dtype"], "BF16")
        self.assertEqual(written[converter.LM_HEAD]["shape"], [3, 128])
        self.assertEqual(written["language_model.model.embed_tokens.weight"]["dtype"], "U32")
        self.assertEqual(written["language_model.model.embed_tokens.scales"]["shape"], [300, 2])
        self.assertEqual(written["language_model.model.layers.0.linear_attn.conv1d.weight"]["shape"], [256, 4, 1])
        self.assertEqual(written["vision_tower.patch_embed.proj.weight"]["shape"], [16, 2, 4, 4, 3])
        self.assertEqual(written["vision_tower.blocks.0.attn.qkv.weight"]["dtype"], "BF16")
        ops = {key: value.ops for shard in saved.values() for key, value in shard[0].items()}
        self.assertEqual(ops["language_model.model.norm.weight"], ("add(1.0)",))
        self.assertEqual(ops["language_model.model.layers.0.linear_attn.norm.weight"], ())
        self.assertEqual(ops["language_model.model.layers.0.linear_attn.A_log"], ())
        self.assertEqual(ops[converter.LM_HEAD], ())
        self.assertEqual(saved[SHARDS[1]][1], {"format": "mlx"})

        config = json.loads((output / "config.json").read_text())
        self.assertEqual(config["model_type"], "pplx_decider_qwen35")
        self.assertEqual(config["decision"]["options"], 3)
        self.assertEqual(config["decision"]["codes"], ["A", "B", "C"])
        self.assertEqual(config["architectures"], ["Qwen3_5Model"])
        for name in converter.COPIED_METADATA:
            self.assertEqual((output / name).read_bytes(), (source / name).read_bytes())
        for name in ("preprocessor_config.json", "processor_config.json", "video_preprocessor_config.json"):
            self.assertTrue((output / name).is_file())
        self.assertFalse((output / converter.READOUT).exists())

        self.assertEqual(receipt["mode"], "decider")
        self.assertEqual(receipt["release_manifest_sha256"], policy.manifest_sha256)
        self.assertEqual(receipt["head"], {"source": "readout", "key": converter.LM_HEAD, "quantized": False, "shape": [3, 128]})
        self.assertEqual(receipt["tensor_counts"]["quantized"], 3)
        self.assertEqual(receipt["tensor_counts"]["copied"], 14)
        self.assertEqual(receipt["tensor_counts"]["transformed"],
                         {"conv1d_moveaxis": 1, "norm_plus_one": 5, "patch_embed_transpose": 1})
        self.assertEqual(set(receipt["source_payload_sha256"]), {*SHARDS, converter.READOUT})
        self.assertEqual(receipt["source_dropped_keys"], [])
        self.assertEqual(receipt["runtime_provenance"], {"synthetic_stub": True})
        for name, digest in {**receipt["output_files_sha256"], **receipt["output_shard_sha256"]}.items():
            self.assertEqual(provenance.sha256_file(output / name), digest)
        digests = json.loads((output / "shard-digests.json").read_text())
        self.assertEqual({item["file"] for item in digests["source_payloads"]}, {*SHARDS, converter.READOUT})
        self.assertIn("Do not upload", (output / "README.md").read_text())
        self.assertTrue((output / "conversion-receipt.json").is_file())

    def test_existing_output_is_refused(self) -> None:
        source, policy = self.make_decider()
        (self.root / "out").mkdir()
        with self.assertRaisesRegex(ValueError, "must not exist"):
            self.convert(source, policy)

    def assert_refused_before_output(self, source: Path, policy, message: str) -> None:
        with self.assertRaisesRegex(ValueError, message):
            self.convert(source, policy)
        self.assertFalse((self.root / "out").exists())

    def test_tampered_source_is_refused_before_writing(self) -> None:
        source, policy = self.make_decider()
        (source / converter.READOUT).write_bytes((source / converter.READOUT).read_bytes()[:-1] + b"\x01")
        self.assert_refused_before_output(source, policy, "source identity verification failed")

    def test_tampered_shard_is_refused_before_a_receipt(self) -> None:
        source, policy = self.make_decider()
        path = source / SHARDS[1]
        path.write_bytes(path.read_bytes()[:-1] + b"\x01")
        with self.assertRaisesRegex(ValueError, f"source payload hash mismatch: {SHARDS[1]}"):
            self.convert(source, policy)
        self.assertFalse((self.root / "out" / "conversion-receipt.json").exists())

    def test_readout_and_lm_head_together_are_refused(self) -> None:
        tensors = copy.deepcopy(DECIDER_TENSORS)
        tensors[SHARDS[1]]["lm_head.weight"] = [300, 128]
        source, policy = self.make_decider(tensors=tensors)
        self.assert_refused_before_output(source, policy, "both lm_head.weight and readout")

    def test_readout_shape_must_match_the_options(self) -> None:
        source, policy = self.make_decider(readout_shape=(4, 128))
        self.assert_refused_before_output(source, policy, r"readout must be BF16 \[3, 128\]")

    def test_converted_source_shards_are_refused(self) -> None:
        source, policy = self.make_decider(shard_format="mlx")
        self.assert_refused_before_output(source, policy, "already in mlx format")

    def test_non_divisible_quantization_candidate_is_refused(self) -> None:
        tensors = copy.deepcopy(DECIDER_TENSORS)
        tensors[SHARDS[0]]["language_model.layers.0.linear_attn.in_proj_a.weight"] = [4, 100]
        source, policy = self.make_decider(tensors=tensors)
        self.assert_refused_before_output(source, policy, "not divisible by 64")

    def test_decision_codes_must_match_the_tokenizer(self) -> None:
        source, policy = self.make_decider(vocab={"A": 10, "B": 12, "C": 11})
        self.assert_refused_before_output(source, policy, "decision codes do not map")

    def test_cli_requires_conformance_flags_together(self) -> None:
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as raised:
            converter.main(["--conformance-source", "a", "--output", "b"])
        self.assertEqual(raised.exception.code, 2)


class ConformanceTests(Fixture):
    def reference_from(self, pack: Path, name: str = "reference") -> Path:
        reference = self.root / name
        shutil.copytree(pack, reference)
        self.hub_metadata(reference, provenance.REFERENCE_REPO, provenance.REFERENCE_REVISION)
        return reference

    def test_base_model_takes_the_same_path_with_a_quantized_head(self) -> None:
        base = self.make_base()
        with self.stub_mlx():
            receipt = converter.convert(base, self.root / "converted", mode="conformance")
        index = json.loads((self.root / "converted" / provenance.INDEX).read_text())["weight_map"]
        self.assertIn("language_model.lm_head.scales", index)
        self.assertFalse(any("mtp." in key for key in index))
        self.assertEqual(receipt["source_dropped_keys"], ["mtp.fc.weight"])
        self.assertEqual(receipt["head"]["source"], "source")
        self.assertIsNone(receipt["decision"])
        config = json.loads((self.root / "converted" / "config.json").read_text())
        self.assertEqual(config["model_type"], "qwen3_5")
        self.assertNotIn("decision", config)

    def test_decider_source_in_conformance_mode_is_refused(self) -> None:
        source, _ = self.make_decider()
        self.hub_metadata(source, provenance.BASE_REPO, provenance.BASE_REVISION)
        with self.stub_mlx(), self.assertRaisesRegex(ValueError, "requires the source lm_head head"):
            converter.convert(source, self.root / "converted", mode="conformance")

    def test_conformance_run_reports_identical_layout(self) -> None:
        base = self.make_base()
        with self.stub_mlx():
            converter.convert(base, self.root / "first", mode="conformance")
        reference = self.reference_from(self.root / "first")
        report_path = self.root / "report.json"
        with self.stub_mlx():
            report = converter.run_conformance(base, reference, self.root / "second", report_path)
        self.assertTrue(report["layout_identical"])
        self.assertEqual(report["tensors_compared"], 23 + 2)
        self.assertEqual(report["bit_identical_tensors"], report["tensors_compared"])
        self.assertEqual(report["reference_evidence"]["revision"], provenance.REFERENCE_REVISION)
        self.assertEqual(json.loads(report_path.read_text())["layout_identical"], True)
        with self.stub_mlx(), self.assertRaisesRegex(ValueError, "report must not exist"):
            converter.run_conformance(base, reference, self.root / "third", report_path)

    def test_compare_reports_value_and_layout_differences(self) -> None:
        base = self.make_base()
        with self.stub_mlx():
            converter.convert(base, self.root / "ours", mode="conformance")
        reference = self.reference_from(self.root / "ours")
        layout, _ = compare.pack_layout(reference)
        for key in ("language_model.lm_head.scales", "vision_tower.pos_embed.weight"):
            entry = layout[key]
            with entry["path"].open("r+b") as handle:
                handle.seek(entry["offset"])
                first = handle.read(1)[0]
                handle.seek(entry["offset"])
                handle.write(bytes([first ^ 0xFF]))
        numeric = types.SimpleNamespace(
            dense=lambda ours, ref: {"max_abs_diff": 0.5},
            quantized=lambda ours, ref: {"max_abs_diff": 0.25, "packed_words_differing": 0})
        report = compare.compare_packs(self.root / "ours", reference, numeric)
        self.assertTrue(report["layout_identical"])
        self.assertEqual(sorted(report["differing_tensors"]),
                         ["language_model.lm_head.scales", "vision_tower.pos_embed.weight"])
        self.assertEqual({(v["tensor"], v["kind"]) for v in report["value_differences"]},
                         {("language_model.lm_head", "quantized"), ("vision_tower.pos_embed.weight", "dense")})
        self.assertEqual(report["max_abs_diff"], 0.5)

        tensors, metadata, _ = provenance.read_safetensors_header(reference / SHARDS[1])
        replaced = {k: (e["dtype"], e["shape"], zeros(e["dtype"], e["shape"])) for k, e in tensors.items()}
        replaced["vision_tower.pos_embed.weight"] = ("F32", [8, 16], zeros("F32", [8, 16]))
        replaced["language_model.model.norm.weight"] = ("BF16", [64], zeros("BF16", [64]))
        replaced.pop("vision_tower.patch_embed.proj.bias")
        write_safetensors(reference / SHARDS[1], replaced, metadata)
        index = json.loads((reference / provenance.INDEX).read_text())
        index["weight_map"].pop("vision_tower.patch_embed.proj.bias")
        (reference / provenance.INDEX).write_text(json.dumps(index))
        report = compare.compare_packs(self.root / "ours", reference, numeric)
        self.assertFalse(report["layout_identical"])
        self.assertEqual(report["extra_in_ours"], ["vision_tower.patch_embed.proj.bias"])
        self.assertEqual([m["key"] for m in report["dtype_mismatch"]], ["vision_tower.pos_embed.weight"])
        self.assertEqual([m["key"] for m in report["shape_mismatch"]], ["language_model.model.norm.weight"])

    def test_compare_cli_self_comparison_and_report_preservation(self) -> None:
        base = self.make_base()
        with self.stub_mlx():
            converter.convert(base, self.root / "ours", mode="conformance")
        report = self.root / "report.json"
        args = ["--ours", str(self.root / "ours"), "--reference", str(self.root / "ours"), "--report", str(report)]
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(compare.main(args), 0)
        before = report.read_bytes()
        result = json.loads(before)
        self.assertEqual(result["bit_identical_tensors"], result["tensors_compared"])
        self.assertEqual(result["config_differences"], [])
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as raised:
            compare.main(args)
        self.assertEqual(raised.exception.code, 2)
        self.assertEqual(report.read_bytes(), before)


if __name__ == "__main__":
    unittest.main(verbosity=2)
