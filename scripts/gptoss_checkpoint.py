#!/usr/bin/env python3
"""Offline GPT-OSS publisher MXFP4 repacking; no inference or requantization.

The plan command reads saved headers only. Conversion needs a verified local
publisher snapshot and an exclusive resource window. It leaves failed output
marked incomplete and never overwrites a source or existing destination.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import shutil
import struct

CHUNK = 4 * 1024 * 1024
WIDTHS = {"U8": 1, "BF16": 2, "U32": 4}
PROMPT_FILES = ("tokenizer.json", "tokenizer_config.json", "chat_template.jinja",
                "special_tokens_map.json", "generation_config.json")


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Duplicate JSON key: {key}")
        result[key] = value
    return result


def read_json(path):
    return json.loads(Path(path).read_text(), object_pairs_hook=unique_object)


def save_json(path, value, *, exclusive=False):
    with Path(path).open("x" if exclusive else "w") as handle:
        handle.write(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n")


def sha256(path):
    with Path(path).open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def safe_child(root, name):
    if not isinstance(name, str) or Path(name).name != name or name in ("", ".", ".."):
        raise ValueError(f"Expected a plain checkpoint filename: {name!r}")
    return root / name


def tensor_bytes(tensor):
    shape = tensor["shape"]
    if not shape or any(type(n) is not int or n <= 0 for n in shape):
        raise ValueError(f"Invalid tensor shape: {shape}")
    return math.prod(shape) * WIDTHS[tensor["dtype"]]


def expected_publisher(config):
    if config.get("model_type") != "gpt_oss":
        raise ValueError("Only GPT-OSS publisher checkpoints are supported")
    h, m, e = (config[k] for k in ("hidden_size", "intermediate_size", "num_local_experts"))
    q = config["num_attention_heads"] * config["head_dim"]
    kv = config["num_key_value_heads"] * config["head_dim"]
    if h % 32 or m % 32:
        raise ValueError("MXFP4 input dimensions must be divisible by 32")
    tensors = {}

    def add(key, shape, dtype="BF16"):
        tensors[key] = {"shape": shape, "dtype": dtype}

    add("model.embed_tokens.weight", [config["vocab_size"], h])
    add("lm_head.weight", [config["vocab_size"], h])
    add("model.norm.weight", [h])
    for i in range(config["num_hidden_layers"]):
        p = f"model.layers.{i}."
        for norm in ("input_layernorm", "post_attention_layernorm"):
            add(p + norm + ".weight", [h])
        for name, out, inp in (("q_proj", q, h), ("k_proj", kv, h),
                               ("v_proj", kv, h), ("o_proj", h, q)):
            add(p + "self_attn." + name + ".weight", [out, inp])
            add(p + "self_attn." + name + ".bias", [out])
        add(p + "self_attn.sinks", [config["num_attention_heads"]])
        add(p + "mlp.router.weight", [e, h])
        add(p + "mlp.router.bias", [e])
        for name, out, inp in (("gate_up_proj", 2 * m, h), ("down_proj", h, m)):
            add(p + "mlp.experts." + name + "_blocks", [e, out, inp // 32, 16], "U8")
            add(p + "mlp.experts." + name + "_scales", [e, out, inp // 32], "U8")
            add(p + "mlp.experts." + name + "_bias", [e, out])
    return tensors


def make_plan(headers, config):
    expected = expected_publisher(config)
    if headers.keys() != expected.keys():
        raise ValueError(f"Publisher inventory mismatch: missing={sorted(expected.keys()-headers.keys())}, "
                         f"extra={sorted(headers.keys()-expected.keys())}")
    result = {}
    for name, source in sorted(headers.items()):
        if any(source[k] != expected[name][k] for k in ("dtype", "shape")):
            raise ValueError(f"Unexpected publisher geometry: {name}: {source}")
        match = re.fullmatch(r"(.+\.experts\.)(gate_up_proj|down_proj)_(blocks|scales|bias)", name)
        if not match:
            result[name] = {"source": name, "dtype": source["dtype"], "shape": source["shape"],
                            "row_parity": None, "operation": "byte_copy"}
            continue
        prefix, projection, kind = match.groups()
        shape = source["shape"][:]
        suffix = {"blocks": "weight", "scales": "scales", "bias": "bias"}[kind]
        dtype = "U32" if kind == "blocks" else source["dtype"]
        if kind == "blocks":
            # Four adjacent uint8 bytes are one little-endian uint32 word;
            # neither nibble order nor the E8M0 scale bits are changed.
            shape = shape[:-2] + [shape[-2] * shape[-1] // 4]
        halves = (("gate_proj", 0), ("up_proj", 1)) if projection == "gate_up_proj" else ((projection, None),)
        for output, parity in halves:
            out_shape = shape[:]
            if parity is not None:
                out_shape[1] //= 2
            result[prefix + output + "." + suffix] = {
                "source": name, "dtype": dtype, "shape": out_shape,
                "row_parity": parity, "operation": "byte_preserving_repack"}
    if sum(map(tensor_bytes, headers.values())) != sum(map(tensor_bytes, result.values())):
        raise ValueError("Repacking changed the total tensor byte count")
    return result


def compare_inventory(plan, current):
    """Account for every current tensor, including affine auxiliaries removed."""
    used, restored = set(), []
    for name, output in plan.items():
        old = current.get(name)
        if old is None:
            raise ValueError(f"Current checkpoint is missing {name}")
        used.add(name)
        if (old["dtype"], old["shape"]) == (output["dtype"], output["shape"]):
            continue
        if output["dtype"] != "BF16" or not name.endswith(".weight") or len(output["shape"]) != 2:
            raise ValueError(f"Unexpected current tensor difference: {name}")
        rows, cols = output["shape"]
        if cols % 64 or (old["dtype"], old["shape"]) != ("U32", [rows, cols // 4]):
            raise ValueError(f"Expected affine Q8/group-64 geometry: {name}")
        for suffix in ("scales", "biases"):
            aux_name = name[:-6] + suffix
            aux = current.get(aux_name, {})
            if (aux.get("dtype"), aux.get("shape")) != ("BF16", [rows, cols // 64]):
                raise ValueError(f"Invalid affine auxiliary: {aux_name}")
            used.add(aux_name)
        restored.append(name)
    if used != current.keys():
        raise ValueError(f"Unaccounted current tensors: {sorted(current.keys()-used)}")
    return restored


class Checkpoint:
    """Validated safetensors/index reader with bounded payload reads."""
    def __init__(self, root):
        self.root = Path(root)
        index = read_json(self.root / "model.safetensors.index.json")["weight_map"]
        indexed_paths = {safe_child(self.root, name) for name in index.values()}
        if set(self.root.rglob("*.safetensors")) != indexed_paths:
            raise ValueError("Checkpoint contains unindexed or missing safetensors files")
        self.headers, self.starts = {}, {}
        for name in sorted(set(index.values())):
            path = safe_child(self.root, name)
            with path.open("rb") as handle:
                prefix = handle.read(8)
                if len(prefix) != 8:
                    raise ValueError(f"Truncated safetensors prefix: {name}")
                size = struct.unpack("<Q", prefix)[0]
                if not 2 <= size <= 16 * 1024 * 1024:
                    raise ValueError(f"Invalid safetensors header length: {name}")
                header = json.loads(handle.read(size), object_pairs_hook=unique_object)
            self.starts[name] = 8 + size
            spans = []
            for key, tensor in header.items():
                if key == "__metadata__":
                    continue
                if key in self.headers or index.get(key) != name:
                    raise ValueError(f"Index/header disagreement: {key}")
                lo, hi = tensor["data_offsets"]
                if type(lo) is not int or type(hi) is not int or lo < 0 or hi - lo != tensor_bytes(tensor):
                    raise ValueError(f"Invalid tensor span: {key}")
                spans.append((lo, hi))
                self.headers[key] = dict(tensor, shard=name)
            cursor = 0
            for lo, hi in sorted(spans):
                if lo != cursor:
                    raise ValueError(f"Overlapping or unaccounted payload in {name}")
                cursor = hi
            if 8 + size + cursor != path.stat().st_size:
                raise ValueError(f"Truncated or trailing payload in {name}")
        if self.headers.keys() != index.keys():
            raise ValueError("Index names absent from shard headers")

    def chunks(self, name, offset=0, length=None):
        t = self.headers[name]
        total = tensor_bytes(t)
        length = total - offset if length is None else length
        if offset < 0 or length < 0 or offset + length > total:
            raise ValueError(f"Out-of-range tensor read: {name}")
        with (self.root / t["shard"]).open("rb") as handle:
            handle.seek(self.starts[t["shard"]] + t["data_offsets"][0] + offset)
            while length:
                block = handle.read(min(CHUNK, length))
                if not block:
                    raise ValueError(f"Truncated tensor during read: {name}")
                length -= len(block)
                yield block

    def read(self, name, offset, length):
        return b"".join(self.chunks(name, offset, length))


def mapped_chunks(checkpoint, entry):
    name, parity = entry["source"], entry["row_parity"]
    if parity is None:
        yield from checkpoint.chunks(name)
        return
    shape = checkpoint.headers[name]["shape"]
    row_bytes = tensor_bytes(checkpoint.headers[name]) // (shape[0] * shape[1])
    pair_bytes = 2 * row_bytes
    # Read whole pairs so row selection never crosses an expert boundary.
    # Each expert has an even gate/up row count, including bias rows.
    pairs_per_read = max(1, CHUNK // pair_bytes)
    total = shape[0] * shape[1] // 2
    for start in range(0, total, pairs_per_read):
        count = min(pairs_per_read, total - start)
        block = checkpoint.read(name, start * pair_bytes, count * pair_bytes)
        yield b"".join(block[i * pair_bytes + parity * row_bytes:
                             i * pair_bytes + (parity + 1) * row_bytes] for i in range(count))


def write_weights(path, checkpoint, plan):
    header, cursor = {"__metadata__": {"format": "mlx"}}, 0
    for name, t in sorted(plan.items()):
        length = tensor_bytes(t)
        header[name] = {"dtype": t["dtype"], "shape": t["shape"], "data_offsets": [cursor, cursor + length]}
        cursor += length
    encoded = json.dumps(header, separators=(",", ":")).encode()
    encoded += b" " * (-len(encoded) % 8)
    digests = {}
    with path.open("xb") as handle:
        handle.write(struct.pack("<Q", len(encoded)))
        handle.write(encoded)
        for name, entry in sorted(plan.items()):
            digest, written = hashlib.sha256(), 0
            for chunk in mapped_chunks(checkpoint, entry):
                handle.write(chunk)
                digest.update(chunk)
                written += len(chunk)
            if written != tensor_bytes(entry):
                raise ValueError(f"Incorrect mapped byte count: {name}")
            digests[name] = digest.hexdigest()
    return digests


def candidate_config(source, plan):
    config = dict(source)
    policy = {"group_size": 32, "bits": 4, "mode": "mxfp4"}
    for name, tensor in plan.items():
        if name.endswith(".weight") and tensor["dtype"] == "BF16":
            policy[name[:-7]] = False
    config["quantization"] = policy
    config["quantization_config"] = policy
    return config


def bf16_values(raw):
    return [struct.unpack("<f", struct.pack("<I", word << 16))[0]
            for (word,) in struct.iter_unpack("<H", raw)]


def sampled_q8_error(publisher, current, name):
    rows, cols = publisher.headers[name]["shape"]
    selected = sorted({0, rows // 2, rows - 1})
    squared_error = squared_reference = maximum = 0.0
    for row in selected:
        reference = bf16_values(publisher.read(name, row * cols * 2, cols * 2))
        quantized = current.read(name, row * cols, cols)
        scales = bf16_values(current.read(name[:-6] + "scales", row * cols // 32, cols // 32))
        biases = bf16_values(current.read(name[:-6] + "biases", row * cols // 32, cols // 32))
        for j, (value, code) in enumerate(zip(reference, quantized)):
            reconstructed = code * scales[j // 64] + biases[j // 64]
            if not math.isfinite(value) or not math.isfinite(reconstructed):
                raise ValueError(f"Nonfinite Q8 sample: {name}, row={row}, col={j}")
            delta = abs(value - reconstructed)
            maximum = max(maximum, delta)
            squared_error += delta * delta
            squared_reference += value * value
    return {"sampled_rows": selected, "sampled_values": len(selected) * cols,
            "max_absolute_error": maximum, "rmse": math.sqrt(squared_error / (len(selected) * cols)),
            "relative_l2": math.sqrt(squared_error / squared_reference) if squared_reference else None,
            "reference": "publisher BF16 versus exact affine reconstruction; no matmul rounding"}


def verify_files(root, expected_hashes, names):
    # Validate the complete receipt before starting any multi-gigabyte scans.
    for name in sorted(names):
        expected = expected_hashes.get(name, "")
        if not isinstance(expected, str) or not re.fullmatch(r"[0-9a-f]{64}", expected):
            raise ValueError(f"Missing authenticated checkpoint hash: {name}")
        safe_child(root, name)
    hashes = {}
    for name in sorted(names):
        hashes[name] = sha256(safe_child(root, name))
        if hashes[name] != expected_hashes[name]:
            raise ValueError(f"Checkpoint hash mismatch: {name}")
    return hashes


def verify_source(root, manifest, names):
    if manifest.get("repo") != "openai/gpt-oss-20b" or not re.fullmatch(r"[0-9a-f]{40}", manifest.get("revision", "")):
        raise ValueError("Source manifest must bind openai/gpt-oss-20b to an immutable revision")
    return verify_files(root, manifest.get("files", {}), names)


def convert(args):
    source, output = args.source.resolve(), args.output.resolve()
    current_root, receipt = args.current.resolve(), args.receipt.resolve()
    if any(output.is_relative_to(root) or root.is_relative_to(output) for root in (source, current_root)):
        raise ValueError("Output must be separate from immutable source/current checkpoints")
    if receipt.exists() or any(receipt.is_relative_to(root) for root in (source, current_root, output)):
        raise ValueError("Receipt must be a new file outside the checkpoints")
    if output.exists():
        raise ValueError("Output must be a new directory; incomplete runs are retained")
    checkpoint = Checkpoint(source)
    config = read_json(source / "config.json")
    plan = make_plan(checkpoint.headers, config)
    size = sum(map(tensor_bytes, plan.values()))
    if size > args.max_output_gib * 2**30:
        raise ValueError("Candidate exceeds --max-output-gib; allocate staging before conversion")
    if shutil.disk_usage(output.parent).free < size + (args.reserve_gib * 2**30) + 64 * 2**20:
        raise ValueError("Insufficient free space after preserving the requested disk reserve")
    manifest = read_json(args.source_manifest)
    required = set(checkpoint.starts) | {"config.json", "model.safetensors.index.json", "LICENSE", "README.md", "USAGE_POLICY"} | set(PROMPT_FILES)
    source_hashes = verify_source(source, manifest, required)
    current = Checkpoint(args.current)
    restored = compare_inventory(plan, current.headers)
    current_config = read_json(args.current / "config.json")
    source_arch = {k: v for k, v in config.items() if k not in ("quantization", "quantization_config")}
    current_arch = {k: v for k, v in current_config.items() if k not in ("quantization", "quantization_config")}
    if source_arch != current_arch:
        raise ValueError("Current/publisher architecture configs differ beyond quantization")
    policy = current_config["quantization"]
    for name in restored:
        layer_policy = policy.get(name[:-7])
        # BaseConfiguration.Quantization.mode defaults to affine for each
        # per-layer object; it does not inherit the global MXFP4 mode.
        if not isinstance(layer_policy, dict) or {"mode": "affine", **layer_policy} != {
            "group_size": 64, "bits": 8, "mode": "affine"
        }:
            raise ValueError(f"Current non-expert quantization is not affine Q8/group-64: {name}: {layer_policy!r}")
    mxfp4 = {"group_size": 32, "bits": 4, "mode": "mxfp4"}
    default = {key: policy.get(key) for key in mxfp4}
    for name, entry in plan.items():
        if entry["dtype"] == "U32" and policy.get(name[:-7], default) != mxfp4:
            raise ValueError(f"Current expert policy differs from publisher MXFP4: {name}")
    # Bind the actual comparison inputs, including unsampled Q8 rows, to the
    # prior receipt. A receipt's own hash cannot authenticate the local shards.
    current_receipt = unique_object((row["file"], row["sha256"])
                                    for row in read_json(args.current_receipt))
    current_required = set(current.starts) | {"config.json", "model.safetensors.index.json"} | set(PROMPT_FILES)
    current_hashes = verify_files(current_root, current_receipt, current_required)
    prompt_hashes = {name: current_hashes[name] for name in PROMPT_FILES}
    output.mkdir()
    marker = output / "INCOMPLETE"
    marker.write_text("Do not load; conversion and validation have not completed.\n")
    digests = write_weights(output / "model.safetensors", checkpoint, plan)
    save_json(output / "model.safetensors.index.json", {
        "metadata": {"total_size": size}, "weight_map": {k: "model.safetensors" for k in plan}})
    # Read back independently through the safetensors index, including every byte.
    candidate = Checkpoint(output)
    if candidate.headers.keys() != plan.keys() or any(
        (candidate.headers[name]["dtype"], candidate.headers[name]["shape"])
        != (entry["dtype"], entry["shape"]) for name, entry in plan.items()
    ):
        raise ValueError("Output tensor inventory/geometry differs from the plan")
    comparisons = {}
    for name, expected in digests.items():
        digest = hashlib.sha256()
        for chunk in candidate.chunks(name):
            digest.update(chunk)
        if digest.hexdigest() != expected:
            raise ValueError(f"Output readback mismatch: {name}")
        if name in restored:
            comparisons[name] = {"classification": "restore_publisher_bf16",
                                 **sampled_q8_error(checkpoint, current, name)}
        else:
            old = hashlib.sha256()
            for chunk in current.chunks(name):
                old.update(chunk)
            comparisons[name] = {"classification": "mapped_byte_comparison", "current_sha256": old.hexdigest(),
                                 "publisher_mapped_sha256": expected, "equal": old.hexdigest() == expected}
    save_json(output / "config.json", candidate_config(config, plan))
    for name in PROMPT_FILES:
        shutil.copyfile(args.current / name, output / name)
        if sha256(output / name) != prompt_hashes[name]:
            raise ValueError(f"Prompt changed during conversion: {name}")
    for name in ("LICENSE", "USAGE_POLICY"):
        shutil.copyfile(source / name, output / name)
    shutil.copyfile(source / "README.md", output / "PUBLISHER-README.md")
    mismatch = any(row.get("equal") is False for row in comparisons.values())
    receipt = {"schema": 1, "status": "validation_failed" if mismatch else "converted_not_qualified", "source_repo": manifest["repo"],
               "source_revision": manifest["revision"], "source_sha256": source_hashes,
               "source_manifest_sha256": sha256(args.source_manifest),
               "resource_window": args.resource_window, "converter_sha256": sha256(Path(__file__)),
               "current_receipt_sha256": sha256(args.current_receipt),
               "current_sha256": current_hashes,
               "current_file_verification": "all indexed shards, config/index and prompt files freshly verified against supplied receipt",
               "prompt_policy": "current prompt contract retained for weight-only comparison",
               "prompt_sha256": prompt_hashes, "tensor_sha256": digests, "comparisons": comparisons,
               "output_sha256": {p.name: sha256(p) for p in sorted(output.iterdir()) if p.name != "INCOMPLETE"}}
    save_json(args.receipt, receipt, exclusive=True)
    # A mismatch remains explicit in the receipt; it is not quietly approved.
    if mismatch:
        raise ValueError("Publisher/current preserved tensors differ; inspect receipt; output remains INCOMPLETE")
    marker.unlink()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    plan_parser = commands.add_parser("plan", help="Header-only accounting; no weight reads")
    plan_parser.add_argument("--headers", type=Path, required=True)
    plan_parser.add_argument("--config", type=Path, required=True)
    plan_parser.add_argument("--current-headers", type=Path, required=True)
    plan_parser.add_argument("--output", type=Path, required=True)
    convert_parser = commands.add_parser("convert")
    for arg in ("source", "source-manifest", "current", "current-receipt", "output", "receipt"):
        convert_parser.add_argument("--" + arg, type=Path, required=True)
    convert_parser.add_argument("--resource-window", required=True, help="Parent-allocated exclusive window receipt/reference")
    convert_parser.add_argument("--max-output-gib", type=float, default=1)
    convert_parser.add_argument("--reserve-gib", type=float, default=20)
    args = parser.parse_args()
    if args.command == "convert":
        if not math.isfinite(args.reserve_gib) or not math.isfinite(args.max_output_gib) or args.reserve_gib < 20 or args.max_output_gib <= 0:
            parser.error("Reserve must be at least 20 GiB; output budget must be positive")
        convert(args)
    else:
        headers, current = read_json(args.headers), read_json(args.current_headers)
        plan = make_plan(headers, read_json(args.config))
        restored = compare_inventory(plan, current)
        save_json(args.output, {"status": "header_plan_only", "tensor_count": len(plan),
                              "tensor_bytes": sum(map(tensor_bytes, plan.values())),
                              "current_tensor_bytes": sum(map(tensor_bytes, current.values())),
                              "restored_bf16_modules": restored, "tensors": plan}, exclusive=True)
        print(f"{len(plan)} output tensors; {len(restored)} BF16 modules restored; no payload read")


if __name__ == "__main__":
    main()
