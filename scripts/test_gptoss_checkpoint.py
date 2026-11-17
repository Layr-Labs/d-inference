"""Small CPU fixtures; these tests never load MLX or real model payloads."""
import hashlib
import json
import math
import random
from pathlib import Path
import struct
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import gptoss_checkpoint as g


CONFIG = {"model_type": "gpt_oss", "hidden_size": 64, "intermediate_size": 64,
          "num_local_experts": 2, "num_attention_heads": 2, "num_key_value_heads": 1,
          "head_dim": 32, "num_hidden_layers": 1, "vocab_size": 4}


def fixture(root):
    headers = g.expected_publisher(CONFIG)
    payloads = {}
    for i, (name, tensor) in enumerate(sorted(headers.items())):
        size = g.tensor_bytes(tensor)
        # Arbitrary bytes deliberately include all nibbles, E8M0 special values,
        # signed zeros and BF16 patterns. Repacking must never interpret them.
        payloads[name] = random.Random(i).randbytes(size)
    write_fixture(root, headers, payloads)
    return headers, payloads


def write_fixture(root, headers, payloads):
    root.mkdir(exist_ok=True)
    offset, result = 0, {}
    for name, t in headers.items():
        length = len(payloads[name])
        result[name] = {"dtype": t["dtype"], "shape": t["shape"], "data_offsets": [offset, offset + length]}
        offset += length
    encoded = json.dumps(result).encode()
    with (root / "model.safetensors").open("wb") as handle:
        handle.write(struct.pack("<Q", len(encoded)))
        handle.write(encoded)
        for name in headers:
            handle.write(payloads[name])
    g.save_json(root / "model.safetensors.index.json", {"weight_map": {k: "model.safetensors" for k in headers}})


class RepackTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.headers, self.payloads = fixture(self.root / "source")
        self.source = g.Checkpoint(self.root / "source")
        self.plan = g.make_plan(self.headers, CONFIG)

    def tearDown(self):
        self.tmp.cleanup()

    def test_every_byte_has_an_independent_mapping_and_readback(self):
        dest = self.root / "candidate"
        dest.mkdir()
        # Force chunks to end inside ordinary rows/pairs to exercise bounded IO.
        with patch.object(g, "CHUNK", 73):
            hashes = g.write_weights(dest / "model.safetensors", self.source, self.plan)
        g.save_json(dest / "model.safetensors.index.json", {"weight_map": {k: "model.safetensors" for k in self.plan}})
        actual = g.Checkpoint(dest)
        for name, entry in self.plan.items():
            raw = self.payloads[entry["source"]]
            if entry["row_parity"] is not None:
                # Independent oracle iterates experts then rows, not flat pairs.
                shape = self.headers[entry["source"]]["shape"]
                row_size = len(raw) // (shape[0] * shape[1])
                expected = bytearray()
                for expert in range(shape[0]):
                    for row in range(entry["row_parity"], shape[1], 2):
                        start = (expert * shape[1] + row) * row_size
                        expected.extend(raw[start:start + row_size])
                raw = bytes(expected)
            self.assertEqual(b"".join(actual.chunks(name)), raw, name)
            self.assertEqual(hashes[name], hashlib.sha256(raw).hexdigest(), name)
            self.assertEqual(actual.headers[name]["shape"], entry["shape"])
        self.assertEqual(sum(map(g.tensor_bytes, self.headers.values())),
                         sum(map(g.tensor_bytes, self.plan.values())))

    def test_nibble_and_scale_decode_preserved(self):
        # E2M1: low nibble first, signed zero included; E8M0 has bias 127.
        lut = [0, .5, 1, 1.5, 2, 3, 4, 6, -0., -.5, -1, -1.5, -2, -3, -4, -6]
        packed = bytes(range(16)) * 2
        words = struct.unpack("<8I", packed)
        actual = [lut[(word >> shift) & 15] for word in words for shift in range(0, 32, 4)]
        expected = [lut[code] for byte in packed for code in (byte & 15, byte >> 4)]
        self.assertEqual([struct.pack("<f", x) for x in actual], [struct.pack("<f", x) for x in expected])
        self.assertEqual([math_value * 2**(126-127) for math_value in actual[:4]], [0, 0, .25, 0])

    def test_packed_output_numeric_oracle_uses_named_gate_and_up_rows(self):
        # Do not use the plan's parity/source fields to choose expected rows:
        # reversing those fields must fail this independent numeric oracle.
        prefix = "model.layers.0.mlp.experts."
        lut = [0., .5, 1., 1.5, 2., 3., 4., 6., -0., -.5, -1., -1.5, -2., -3., -4., -6.]
        for projection, source_projection, parity in (("gate_proj", "gate_up_proj", 0),
                                                       ("up_proj", "gate_up_proj", 1),
                                                       ("down_proj", "down_proj", None)):
            weight = self.plan[prefix + projection + ".weight"]
            scale = self.plan[prefix + projection + ".scales"]
            self.assertEqual(weight["shape"], [2, 64, 8])
            self.assertEqual(weight["dtype"], "U32")
            packed = b"".join(g.mapped_chunks(self.source, weight))
            scales = b"".join(g.mapped_chunks(self.source, scale))
            source_blocks = self.payloads[prefix + source_projection + "_blocks"]
            source_scales = self.payloads[prefix + source_projection + "_scales"]
            for expert in range(2):
                for row in range(64):
                    source_row = expert * (128 if parity is not None else 64) + (2 * row + parity if parity is not None else row)
                    out_row = expert * 64 + row
                    words = struct.unpack_from("<8I", packed, out_row * 32)
                    for col in range(64):
                        # Publisher bytes: adjacent low/high E2M1 codes, with
                        # one E8M0 exponent per group of 32 input columns.
                        byte = source_blocks[source_row * 32 + col // 2]
                        code = (byte >> (4 * (col % 2))) & 15
                        exponent, fraction = (code >> 1) & 3, code & 1
                        magnitude = fraction * .5 if exponent == 0 else (1 + fraction * .5) * 2**(exponent-1)
                        value = math.copysign(magnitude, -1 if code & 8 else 1)
                        source_scale = source_scales[source_row * 2 + col // 32]
                        self.assertEqual(scales[out_row * 2 + col // 32], source_scale)
                        if source_scale == 255:  # Reserved scale bits checked bytewise above.
                            continue
                        expected = math.ldexp(value, source_scale - 127)
                        actual = math.ldexp(lut[(words[col // 8] >> (4 * (col % 8))) & 15], source_scale - 127)
                        self.assertEqual(struct.pack("<d", actual), struct.pack("<d", expected))

    def test_rejects_missing_extra_wrong_shape_and_dtype(self):
        for mutate in (lambda h: h.pop(next(iter(h))),
                       lambda h: h.update(extra={"shape": [1], "dtype": "BF16"}),
                       lambda h: h[next(iter(h))].update(shape=[1]),
                       lambda h: h[next(iter(h))].update(dtype="F16")):
            headers = json.loads(json.dumps(self.headers))
            mutate(headers)
            with self.assertRaises(ValueError):
                g.make_plan(headers, CONFIG)

    def test_partial_blocks_rejected(self):
        with self.assertRaises(ValueError):
            g.expected_publisher(dict(CONFIG, hidden_size=63))

    def test_bf16_modules_are_explicitly_excluded(self):
        config = g.candidate_config(CONFIG, self.plan)
        self.assertEqual(config["quantization"]["mode"], "mxfp4")
        self.assertIs(config["quantization"]["model.embed_tokens"], False)
        self.assertIs(config["quantization"]["lm_head"], False)
        self.assertNotIn("model.layers.0.mlp.experts.gate_proj", config["quantization"])
        self.assertEqual(config["quantization"], config["quantization_config"])

    def test_inventory_accounts_for_q8_auxiliaries(self):
        current = json.loads(json.dumps(self.plan))
        name = "model.embed_tokens.weight"
        current[name].update(dtype="U32", shape=[4, 16])
        for suffix in ("scales", "biases"):
            current[name[:-6]+suffix] = {"dtype": "BF16", "shape": [4, 1]}
        self.assertEqual(g.compare_inventory(self.plan, current), [name])
        current["unexpected"] = {"dtype": "BF16", "shape": [1]}
        with self.assertRaises(ValueError):
            g.compare_inventory(self.plan, current)

    def test_affine_numeric_reference(self):
        source, current = self.root / "bf16", self.root / "q8"
        name = "model.embed_tokens.weight"
        # 1.0 BF16; uint8 codes=2, scale=.5, bias=0 => exact reconstruction.
        write_fixture(source, {name: {"dtype": "BF16", "shape": [4, 64]}}, {name: b"\x80\x3f" * 256})
        hs = {name: {"dtype": "U32", "shape": [4, 16]},
              name[:-6]+"scales": {"dtype": "BF16", "shape": [4, 1]},
              name[:-6]+"biases": {"dtype": "BF16", "shape": [4, 1]}}
        write_fixture(current, hs, {name: b"\x02"*256, name[:-6]+"scales": b"\x00\x3f"*4,
                                    name[:-6]+"biases": b"\x00\x00"*4})
        result = g.sampled_q8_error(g.Checkpoint(source), g.Checkpoint(current), name)
        self.assertEqual(result["sampled_rows"], [0, 2, 3])
        self.assertEqual(result["rmse"], 0)
        self.assertEqual(result["max_absolute_error"], 0)

    def test_rejects_truncation_unmapped_tensor_and_path_escape(self):
        shard = self.root / "source/model.safetensors"
        shard.write_bytes(shard.read_bytes()[:-1])
        with self.assertRaises(ValueError):
            g.Checkpoint(shard.parent)
        fixture(shard.parent)
        index = g.read_json(shard.parent / "model.safetensors.index.json")
        index["weight_map"].pop(next(iter(index["weight_map"])))
        g.save_json(shard.parent / "model.safetensors.index.json", index)
        with self.assertRaises(ValueError):
            g.Checkpoint(shard.parent)
        with self.assertRaises(ValueError):
            g.safe_child(self.root, "../outside")

    def test_duplicate_keys_rejected(self):
        path = self.root / "bad.json"
        path.write_text('{"a": 1, "a": 2}')
        with self.assertRaises(ValueError):
            g.read_json(path)

    def test_source_identity_refuses_missing_or_bad_hash(self):
        manifest = {"repo": "openai/gpt-oss-20b", "revision": "a"*40, "files": {}}
        with self.assertRaises(ValueError):
            g.verify_source(self.source.root, manifest, {"model.safetensors"})
        manifest["files"]["model.safetensors"] = "0"*64
        with self.assertRaises(ValueError):
            g.verify_source(self.source.root, manifest, {"model.safetensors"})

    def conversion_fixture(self, name="model.embed_tokens.weight"):
        source, current = self.source.root, self.root / "current"
        rows, cols = self.headers[name]["shape"]
        self.payloads[name] = b"\x80\x3f" * (rows * cols)
        write_fixture(source, self.headers, self.payloads)
        publisher = g.Checkpoint(source)
        hs = json.loads(json.dumps(self.plan))
        payloads = {key: b"".join(g.mapped_chunks(publisher, entry)) for key, entry in self.plan.items()}
        hs[name].update(dtype="U32", shape=[rows, cols // 4])
        payloads[name] = b"\x02" * (rows * cols)
        for suffix, value in (("scales", b"\x00\x3f"), ("biases", b"\x00\x00")):
            hs[name[:-6]+suffix] = {"dtype": "BF16", "shape": [rows, cols // 64]}
            payloads[name[:-6]+suffix] = value * (rows * cols // 64)
        write_fixture(current, hs, payloads)
        g.save_json(source / "config.json", CONFIG)
        config = g.candidate_config(CONFIG, self.plan)
        config["quantization"][name[:-7]] = {"group_size": 64, "bits": 8, "mode": "affine"}
        g.save_json(current / "config.json", config)
        for filename in (*g.PROMPT_FILES, "LICENSE", "README.md", "USAGE_POLICY"):
            (source / filename).write_text("synthetic fixture\n")
            (current / filename).write_text("synthetic fixture\n")
        source_hashes = {p.name: g.sha256(p) for p in source.iterdir()}
        current_hashes = {p.name: g.sha256(p) for p in current.iterdir()}
        manifest = self.root / "source-manifest.json"
        g.save_json(manifest, {"repo": "openai/gpt-oss-20b", "revision": "a"*40, "files": source_hashes})
        receipt = self.root / "current-receipt.json"
        g.save_json(receipt, [{"file": k, "sha256": v} for k, v in current_hashes.items()])
        args = SimpleNamespace(source=source, output=self.root / "output", current=current,
                               source_manifest=manifest, current_receipt=receipt,
                               receipt=self.root / "conversion.json", max_output_gib=1,
                               reserve_gib=20, resource_window="synthetic CPU unit test")
        return args, source_hashes, current_hashes

    def convert(self, args):
        with patch.object(g.shutil, "disk_usage", return_value=SimpleNamespace(free=100*2**30)):
            g.convert(args)

    def test_complete_conversion_receipt_and_immutable_inputs(self):
        args, source_hashes, current_hashes = self.conversion_fixture()
        source, current = args.source, args.current
        name = "model.embed_tokens.weight"
        self.convert(args)
        self.assertFalse((args.output / "INCOMPLETE").exists())
        result = g.read_json(args.receipt)
        self.assertEqual(result["status"], "converted_not_qualified")
        self.assertEqual(result["current_sha256"], {k: current_hashes[k] for k in result["current_sha256"]})
        self.assertEqual(result["comparisons"][name]["rmse"], 0)
        self.assertTrue(all(row.get("equal", True) for row in result["comparisons"].values()))
        self.assertEqual(source_hashes, {p.name: g.sha256(p) for p in source.iterdir()})
        self.assertEqual(current_hashes, {p.name: g.sha256(p) for p in current.iterdir()})
        with self.assertRaises(ValueError):
            g.convert(args)


    def test_current_receipt_cannot_hide_an_unsampled_q8_change(self):
        args, _, _ = self.conversion_fixture()
        current = g.Checkpoint(args.current)
        tensor = current.headers["model.embed_tokens.weight"]
        # Row 1 is deliberately outside the numeric sample [0, 2, 3].
        offset = current.starts[tensor["shard"]] + tensor["data_offsets"][0] + 64
        with (args.current / tensor["shard"]).open("r+b") as handle:
            handle.seek(offset)
            handle.write(b"\x03")
        with self.assertRaisesRegex(ValueError, "hash mismatch"):
            self.convert(args)
        self.assertFalse(args.output.exists())

    def test_router_policy_uses_sdk_affine_default_under_mxfp4(self):
        name = "model.layers.0.mlp.router.weight"
        args, _, _ = self.conversion_fixture(name)
        config = g.read_json(args.current / "config.json")
        for key in ("quantization", "quantization_config"):
            self.assertEqual(config[key]["mode"], "mxfp4")
            del config[key][name[:-7]]["mode"]
        g.save_json(args.current / "config.json", config)
        rows = g.read_json(args.current_receipt)
        for row in rows:
            if row["file"] == "config.json":
                row["sha256"] = g.sha256(args.current / "config.json")
        g.save_json(args.current_receipt, rows)
        self.convert(args)
        result = g.read_json(args.receipt)
        self.assertEqual(result["status"], "converted_not_qualified")
        self.assertEqual(result["comparisons"][name]["classification"], "restore_publisher_bf16")
        self.assertEqual(result["comparisons"][name]["rmse"], 0)
        self.assertFalse((args.output / "INCOMPLETE").exists())

    def test_router_policy_rejects_incompatible_precision_and_missing_override(self):
        name = "model.layers.0.mlp.router.weight"
        args, _, _ = self.conversion_fixture(name)
        original = g.read_json(args.current / "config.json")
        incompatible = ({"group_size": 64, "bits": 8, "mode": "mxfp4"},
                        {"group_size": 64, "bits": 8, "mode": "mxfp8"},
                        {"group_size": 64, "bits": 8, "mode": ""},
                        {"group_size": 64, "bits": 4}, {"group_size": 32, "bits": 8},
                        {"group_size": 64}, False, None)
        for bad in incompatible:
            with self.subTest(policy=bad):
                config = json.loads(json.dumps(original))
                for key in ("quantization", "quantization_config"):
                    if bad is None:
                        del config[key][name[:-7]]
                    else:
                        config[key][name[:-7]] = bad
                g.save_json(args.current / "config.json", config)
                with self.assertRaisesRegex(ValueError, "affine Q8/group-64: model.layers.0.mlp.router.weight"):
                    self.convert(args)
                self.assertFalse(args.output.exists())

    def test_missing_and_duplicate_current_receipt_entries_refused(self):
        args, _, _ = self.conversion_fixture()
        rows = g.read_json(args.current_receipt)
        for bad in ([r for r in rows if not r["file"].endswith(".safetensors")], rows + rows[:1]):
            g.save_json(args.current_receipt, bad)
            with self.assertRaises(ValueError):
                self.convert(args)
            self.assertFalse(args.output.exists())

    def test_preserved_mismatch_leaves_failed_receipt_and_marker(self):
        args, _, _ = self.conversion_fixture()
        current = g.Checkpoint(args.current)
        t = current.headers["model.norm.weight"]
        shard = args.current / t["shard"]
        with shard.open("r+b") as handle:
            handle.seek(current.starts[t["shard"]] + t["data_offsets"][0])
            original = handle.read(1)
            handle.seek(-1, 1)
            handle.write(bytes([original[0] ^ 1]))
        rows = g.read_json(args.current_receipt)
        for row in rows:
            row["sha256"] = g.sha256(args.current / row["file"])
        g.save_json(args.current_receipt, rows)
        with self.assertRaisesRegex(ValueError, "preserved tensors differ"):
            self.convert(args)
        self.assertTrue((args.output / "INCOMPLETE").exists())
        self.assertEqual(g.read_json(args.receipt)["status"], "validation_failed")

    def test_output_header_corruption_is_rejected(self):
        args, _, _ = self.conversion_fixture()
        original = g.write_weights
        def corrupt(path, checkpoint, plan):
            digests = original(path, checkpoint, plan)
            with path.open("r+b") as handle:
                size = struct.unpack("<Q", handle.read(8))[0]
                header = handle.read(size)
                # Same byte length and payload size; wrong dtype must still fail.
                header = header.replace(b'"dtype":"BF16"', b'"dtype":"U8"  ', 1)
                header = header.replace(b'"shape":[4,64]', b'"shape":[8,64]', 1)
                handle.seek(8)
                handle.write(header)
            return digests
        with patch.object(g, "write_weights", side_effect=corrupt):
            with self.assertRaises(ValueError):
                self.convert(args)
        self.assertTrue((args.output / "INCOMPLETE").exists())

    def test_output_payload_corruption_is_rejected(self):
        args, _, _ = self.conversion_fixture()
        original = g.write_weights
        def corrupt(path, checkpoint, plan):
            digests = original(path, checkpoint, plan)
            with path.open("r+b") as handle:
                handle.seek(-1, 2)
                value = handle.read(1)[0]
                handle.seek(-1, 2)
                handle.write(bytes([value ^ 1]))
            return digests
        with patch.object(g, "write_weights", side_effect=corrupt):
            with self.assertRaisesRegex(ValueError, "readback mismatch"):
                self.convert(args)
        self.assertTrue((args.output / "INCOMPLETE").exists())

    def test_extra_loader_visible_shard_is_rejected(self):
        (self.source.root / "stale.safetensors").write_bytes(b"stale")
        with self.assertRaisesRegex(ValueError, "unindexed"):
            g.Checkpoint(self.source.root)

    def test_existing_plan_output_and_receipt_are_never_overwritten(self):
        path = self.root / "existing.json"
        path.write_text("immutable")
        with self.assertRaises(FileExistsError):
            g.save_json(path, {}, exclusive=True)
        self.assertEqual(path.read_text(), "immutable")
        args, _, _ = self.conversion_fixture()
        args.output = args.source / "candidate"
        with self.assertRaisesRegex(ValueError, "separate"):
            self.convert(args)
        self.assertFalse(args.output.exists())

    def test_multigroup_affine_reference_with_signed_scales_and_biases(self):
        name = "model.embed_tokens.weight"
        rows, cols = 5, 128
        codes, scales, biases, values = bytearray(), bytearray(), bytearray(), bytearray()
        def bf16(value):
            return struct.pack("<f", value)[2:]
        for row in range(rows):
            for group in range(2):
                scale, bias = (-1 if group else 1) * 2**(row-4), row - 2
                scales.extend(bf16(scale)); biases.extend(bf16(bias))
                for col in range(64):
                    code = (col * 17 + row * 23 + group * 31) % 256
                    codes.append(code)
                    values.extend(bf16(code * scale + bias))
        source, current = self.root / "numeric-source", self.root / "numeric-current"
        write_fixture(source, {name: {"dtype": "BF16", "shape": [rows, cols]}}, {name: values})
        hs = {name: {"dtype": "U32", "shape": [rows, cols//4]},
              name[:-6]+"scales": {"dtype": "BF16", "shape": [rows, 2]},
              name[:-6]+"biases": {"dtype": "BF16", "shape": [rows, 2]}}
        write_fixture(current, hs, {name: codes, name[:-6]+"scales": scales, name[:-6]+"biases": biases})
        actual = g.sampled_q8_error(g.Checkpoint(source), g.Checkpoint(current), name)
        errors = []
        references = []
        for row in (0, 2, 4):
            for col in range(cols):
                idx = row * cols + col
                reference = struct.unpack("<f", b"\0\0" + values[2*idx:2*idx+2])[0]
                restored = codes[idx] * (-1 if col >= 64 else 1) * 2**(row-4) + row - 2
                errors.append(abs(restored - reference)); references.append(reference)
        self.assertEqual(actual["sampled_values"], 384)
        self.assertAlmostEqual(actual["rmse"], (sum(e*e for e in errors)/384)**.5)
        self.assertEqual(actual["max_absolute_error"], max(errors))
        self.assertAlmostEqual(actual["relative_l2"], (sum(e*e for e in errors)/sum(v*v for v in references))**.5)


if __name__ == "__main__":
    unittest.main()
