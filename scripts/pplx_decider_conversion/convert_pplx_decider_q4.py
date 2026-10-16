#!/usr/bin/env python3
"""Convert pplx-decider-v1-27b BF16 to the served Qwen3.8-27B MLX Q4/g64 layout.

Shard-streaming: each source shard is loaded on the CPU stream, renamed to
the mlx-vlm `qwen3_5` names, transformed as mlx-vlm sanitize does, quantized
and written as one `format: mlx` output shard. The decider readout becomes a
BF16 `language_model.lm_head.weight`. The conformance mode converts the base
model with the same code path and compares the result with the served pack.

Run from a neutral working directory. No download, upload or registration.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import shutil
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

from compare_pack_layout import compare_packs
from pplx_decider_provenance import (
    BASE_REPO,
    BASE_REVISION,
    INDEX,
    REFERENCE_REPO,
    REFERENCE_REVISION,
    SAFE_NAME_RE,
    make_shard_manifest,
    read_safetensors_header,
    runtime_provenance,
    sha256_file,
    verify_hub_snapshot,
    verify_release,
)


GROUP_SIZE = 64
BITS = 4
MODE = "affine"
QUANTIZATION = {"group_size": GROUP_SIZE, "bits": BITS, "mode": MODE}
DECIDER_MODEL_TYPE = "pplx_decider_qwen35"
MAX_INPUT_TOKENS = 8192
LM_HEAD = "language_model.lm_head.weight"
READOUT = "readout.safetensors"
NORM_SUFFIXES = (
    ".input_layernorm.weight",
    ".post_attention_layernorm.weight",
    "model.norm.weight",
    ".q_norm.weight",
    ".k_norm.weight",
)
DECISION_REQUIRED = ("format_version", "codes", "token_ids", "temperature")
DECISION_DROPPED = ("step", "provenance", "base_model", "revision")
CODE_RE = re.compile(r"[A-Z]{1,2}\Z")
COPIED_METADATA = (
    "tokenizer.json",
    "tokenizer_config.json",
    "chat_template.jinja",
    "decision_config.json",
    "LICENSE",
    "NOTICE",
)
SNAPSHOT_NAMES = ("config.json", INDEX, "processor_config.json", *COPIED_METADATA)
SHARD_METADATA = {"format": "mlx"}


@dataclass(frozen=True)
class TensorPlan:
    source: str
    target: str
    file: str
    source_shape: tuple[int, ...]
    target_shape: tuple[int, ...]
    transform: str | None
    quantize: bool


def pack_key(key: str) -> str | None:
    """Source name -> pack name (design §3). None: dropped as mlx-vlm drops it.

    Accepts the decider layout (`language_model.*`, `visual.*`) and the
    upstream layout (`model.language_model.*`, `model.visual.*`, `lm_head.weight`).
    """
    if "mtp." in key or "position_ids" in key:
        return None
    name = key[len("model."):] if key.startswith("model.") else key
    if name in ("lm_head.weight", LM_HEAD):
        return LM_HEAD
    if name.startswith("language_model."):
        rest = name[len("language_model."):]
        if rest.startswith(("model.", "lm_head")):
            raise ValueError(f"source key is already in pack layout: {key}")
        return "language_model.model." + rest
    if name.startswith("visual."):
        return "vision_tower." + name[len("visual."):]
    raise ValueError(f"unmapped source key: {key}")


def transform_for(key: str, shape: tuple[int, ...], in_channels: int) -> tuple[str | None, tuple[int, ...]]:
    """mlx-vlm 0.5.0 `qwen3_5` / `qwen3_vl` sanitize, keyed on the pack name."""
    if "conv1d.weight" in key and shape[-1] != 1:
        if len(shape) != 3:
            raise ValueError(f"unexpected conv1d shape: {key} {shape}")
        return "conv1d_moveaxis", (shape[0], shape[2], shape[1])
    if key.endswith(NORM_SUFFIXES) and len(shape) == 1:
        return "norm_plus_one", shape
    if key.endswith("patch_embed.proj.weight") and shape[-1] != in_channels:
        if len(shape) != 5 or shape[1] != in_channels:
            raise ValueError(f"unexpected patch_embed shape: {key} {shape}")
        return "patch_embed_transpose", (shape[0], shape[2], shape[3], shape[4], shape[1])
    return None, shape


def apply_transform(name: str | None, value: Any) -> Any:
    if name == "conv1d_moveaxis":
        return value.moveaxis(2, 1)
    if name == "norm_plus_one":
        return value + 1.0
    if name == "patch_embed_transpose":
        return value.transpose(0, 2, 3, 4, 1)
    if name is not None:
        raise ValueError(f"unknown transform: {name}")
    return value


def should_quantize(key: str, shape: tuple[int, ...]) -> bool:
    """Every 2-D language tensor; refuse (no g32 fallback) when not divisible."""
    if not key.startswith("language_model.") or len(shape) != 2:
        return False
    if shape[-1] % GROUP_SIZE:
        raise ValueError(f"quantization candidate last dim not divisible by {GROUP_SIZE}: {key} {shape}")
    return True


def quantized_layout(base: str, shape: tuple[int, ...]) -> dict[str, tuple[str, tuple[int, ...]]]:
    rows, cols = shape
    packed = (rows, cols * BITS // 32)
    groups = (rows, cols // GROUP_SIZE)
    return {
        f"{base}.weight": ("U32", packed),
        f"{base}.scales": ("BF16", groups),
        f"{base}.biases": ("BF16", groups),
    }


def preflight_headers(source: Path, weight_map: dict[str, str]) -> dict[str, dict[str, Any]]:
    """Read every source shard header; refuse converted or inconsistent shards."""
    headers: dict[str, dict[str, Any]] = {}
    for name in sorted(set(weight_map.values())):
        if not SAFE_NAME_RE.fullmatch(name):
            raise ValueError(f"unsafe shard name: {name!r}")
        tensors, metadata, _ = read_safetensors_header(source / name)
        if metadata.get("format") == "mlx":
            raise ValueError(f"source shard is already in mlx format: {name}")
        if set(tensors) != {key for key, file in weight_map.items() if file == name}:
            raise ValueError(f"source index and shard header disagree: {name}")
        headers[name] = tensors
    return headers


def plan_tensors(
    weight_map: dict[str, str], headers: dict[str, dict[str, Any]], in_channels: int
) -> tuple[list[TensorPlan], list[str]]:
    plans: list[TensorPlan] = []
    dropped: list[str] = []
    targets: set[str] = set()
    for key, file in sorted(weight_map.items()):
        target = pack_key(key)
        if target is None:
            dropped.append(key)
            continue
        entry = headers[file][key]
        if entry["dtype"] != "BF16":
            raise ValueError(f"source tensor is not BF16: {key} {entry['dtype']}")
        if target in targets:
            raise ValueError(f"colliding pack name: {target}")
        targets.add(target)
        shape = tuple(int(dim) for dim in entry["shape"])
        transform, target_shape = transform_for(target, shape, in_channels)
        plans.append(TensorPlan(key, target, file, shape, target_shape, transform,
                                should_quantize(target, target_shape)))
    return plans, dropped


def select_head(plans: Iterable[TensorPlan], readout_present: bool) -> str:
    has_lm_head = any(plan.target == LM_HEAD for plan in plans)
    if has_lm_head and readout_present:
        raise ValueError("source has both lm_head.weight and readout.safetensors")
    if not has_lm_head and not readout_present:
        raise ValueError("source has neither lm_head.weight nor readout.safetensors")
    return "source" if has_lm_head else "readout"


def expected_layout(plans: Iterable[TensorPlan], readout_shape: tuple[int, ...] | None) -> dict[str, tuple[str, tuple[int, ...]]]:
    layout: dict[str, tuple[str, tuple[int, ...]]] = {}
    for plan in plans:
        if plan.quantize:
            layout.update(quantized_layout(plan.target[: -len(".weight")], plan.target_shape))
        else:
            layout[plan.target] = ("BF16", plan.target_shape)
    if readout_shape is not None:
        layout[LM_HEAD] = ("BF16", readout_shape)
    return layout


def validate_output_key_coverage(source_keys: Iterable[str], output_keys: Iterable[str]) -> None:
    """Every pack-named source tensor is copied or has a complete affine triple."""
    outputs = set(output_keys)
    accounted: set[str] = set()
    for key in source_keys:
        base = key[: -len(".weight")] if key.endswith(".weight") else key
        triple = {f"{base}.weight", f"{base}.scales", f"{base}.biases"}
        if outputs & {f"{base}.scales", f"{base}.biases"}:
            if not triple <= outputs:
                raise ValueError(f"incomplete quantized tensor identity: {key}")
            represented = triple
        elif key in outputs:
            represented = {key}
        else:
            raise ValueError(f"missing converted tensor identity: {key}")
        if represented & accounted:
            raise ValueError(f"colliding converted tensor identity: {key}")
        accounted.update(represented)
    if outputs != accounted:
        raise ValueError("unexpected converted tensor identities")
    if any("mtp." in key for key in outputs):
        raise ValueError("output contains mtp tensors")


def validate_source_config(config: dict[str, Any]) -> tuple[int, int, int]:
    text = config.get("text_config") or {}
    vision = config.get("vision_config") or {}
    if config.get("model_type") != "qwen3_5" or text.get("model_type") != "qwen3_5_text":
        raise ValueError("source config is not qwen3_5 / qwen3_5_text")
    if config.get("tie_word_embeddings") or text.get("tie_word_embeddings"):
        raise ValueError("tied word embeddings are not supported")
    for key in ("quantization", "quantization_config", "decision"):
        if key in config:
            raise ValueError(f"source config already has {key!r}")
    try:
        return int(text["hidden_size"]), int(text["vocab_size"]), int(vision["in_channels"])
    except (KeyError, TypeError, ValueError) as exc:
        raise ValueError("source config lacks hidden_size, vocab_size or in_channels") from exc


def decision_block(decision: dict[str, Any], tokenizer: dict[str, Any], vocab_size: int) -> dict[str, Any]:
    """`decision_config.json` minus training provenance, validated against the vocab."""
    unknown = set(decision) - set(DECISION_REQUIRED) - set(DECISION_DROPPED)
    if unknown or not set(DECISION_REQUIRED) <= set(decision):
        raise ValueError(f"unexpected decision_config keys: {sorted(unknown) or 'missing required'}")
    codes, token_ids, temperature = decision["codes"], decision["token_ids"], decision["temperature"]
    if decision["format_version"] != 1 or isinstance(decision["format_version"], bool):
        raise ValueError("decision format_version must be 1")
    if not isinstance(codes, list) or not 1 <= len(codes) <= 255 or len(set(codes)) != len(codes):
        raise ValueError("decision codes must be 1..255 unique entries")
    if not all(isinstance(code, str) and CODE_RE.fullmatch(code) for code in codes):
        raise ValueError("decision codes must match [A-Z]{1,2}")
    if (
        not isinstance(token_ids, list)
        or len(token_ids) != len(codes)
        or len(set(token_ids)) != len(token_ids)
        or not all(isinstance(t, int) and not isinstance(t, bool) and 0 <= t < vocab_size for t in token_ids)
    ):
        raise ValueError("decision token_ids must be unique in-vocabulary ids, one per code")
    if isinstance(temperature, bool) or not isinstance(temperature, (int, float)) or not math.isfinite(temperature) or temperature <= 0:
        raise ValueError("decision temperature must be finite and positive")
    vocab = (tokenizer.get("model") or {}).get("vocab")
    if not isinstance(vocab, dict):
        raise ValueError("tokenizer.json has no model vocab")
    mismatched = [code for code, token in zip(codes, token_ids) if vocab.get(code) != token]
    if mismatched:
        raise ValueError(f"decision codes do not map to their token ids: {mismatched[:8]}")
    return {
        "format_version": 1,
        "options": len(codes),
        "temperature": float(temperature),
        "codes": list(codes),
        "token_ids": list(token_ids),
        "max_input_tokens": MAX_INPUT_TOKENS,
    }


def output_config(config: dict[str, Any], decision: dict[str, Any] | None) -> dict[str, Any]:
    result = dict(config)
    result["quantization"] = dict(QUANTIZATION)
    result["quantization_config"] = dict(QUANTIZATION)
    if decision is not None:
        result["model_type"] = DECIDER_MODEL_TYPE
        result["decision"] = decision
    return dict(sorted(result.items()))


def derive_processor_files(processor: dict[str, Any]) -> dict[str, bytes]:
    """The served pack's three processor files, with the source's values."""
    try:
        image, video = processor["image_processor"], processor["video_processor"]
        processor_class = processor["processor_class"]
        if processor_class != "Qwen3VLProcessor":
            raise ValueError(f"unexpected processor_class: {processor_class!r}")

        def preprocessor(part: dict[str, Any], type_key: str, type_value: str) -> bytes:
            body = {
                "size": {"longest_edge": part["size"]["longest_edge"], "shortest_edge": part["size"]["shortest_edge"]},
                "patch_size": part["patch_size"],
                "temporal_patch_size": part["temporal_patch_size"],
                "merge_size": part["merge_size"],
                "image_mean": part["image_mean"],
                "image_std": part["image_std"],
                "processor_class": processor_class,
                type_key: type_value,
            }
            return json.dumps(body, indent=4).encode()

        shared = ("do_convert_rgb", "do_normalize", "do_rescale", "image_mean", "image_std",
                  "merge_size", "patch_size", "rescale_factor", "temporal_patch_size")
        image_out = {key: image[key] for key in shared}
        image_out.update(image_processor_type="Qwen3VLImageProcessor",
                         min_pixels=image["size"]["shortest_edge"], max_pixels=image["size"]["longest_edge"])
        video_out = {key: video[key] for key in (*shared, "max_frames", "min_frames", "video_processor_type")}
        video_out.update(fps=float(video["fps"]),
                         min_pixels=video["size"]["shortest_edge"], max_pixels=video["size"]["longest_edge"])
        combined = {"image_processor": image_out, "processor_class": processor_class, "video_processor": video_out}
        return {
            "preprocessor_config.json": preprocessor(image, "image_processor_type", "Qwen2VLImageProcessorFast"),
            "processor_config.json": (json.dumps(combined, indent=2, sort_keys=True) + "\n").encode(),
            "video_preprocessor_config.json": preprocessor(video, "video_processor_type", video["video_processor_type"]),
        }
    except (KeyError, TypeError) as exc:
        raise ValueError(f"processor_config.json lacks a served-layout field: {exc}") from exc


def _snapshot_metadata(source: Path, files: dict[str, dict[str, Any]]) -> dict[str, bytes]:
    """Capture metadata bytes once and recheck them against the verified digests."""
    snapshot: dict[str, bytes] = {}
    for name in SNAPSHOT_NAMES:
        item = files.get(name) or {}
        verified = item.get("expected_sha256") or item.get("sha256")
        path = source / name
        if not path.is_file():
            if verified:
                raise ValueError(f"metadata changed after verification: {name}")
            continue
        payload = path.read_bytes()
        if verified and hashlib.sha256(payload).hexdigest() != verified:
            raise ValueError(f"metadata changed after verification: {name}")
        snapshot[name] = payload
    return snapshot


def _write_new(path: Path, payload: bytes) -> None:
    with path.open("xb") as handle:
        handle.write(payload)
    os.chmod(path, 0o600)


def _verified_payload(source: Path, name: str, files: dict[str, dict[str, Any]], consumed: dict[str, str]) -> Path:
    """Hash a payload immediately before it is loaded."""
    expected = (files.get(name) or {}).get("expected_sha256")
    path = source / name
    actual = sha256_file(path)
    if not expected or actual != expected:
        raise ValueError(f"source payload hash mismatch: {name}")
    consumed[name] = actual
    return path


def convert_shard(source_file: Path, plans: list[TensorPlan]) -> tuple[dict[str, Any], dict[str, Any]]:
    import mlx.core as mx

    # Load on the CPU stream so disk reads never sit inside a GPU command buffer.
    loaded = mx.load(str(source_file), stream=mx.cpu)
    if loaded:
        mx.eval(*loaded.values())
    out: dict[str, Any] = {}
    stats: dict[str, Any] = {"copied": 0, "quantized": 0, "transformed": {}}
    try:
        for plan in plans:
            value = apply_transform(plan.transform, loaded[plan.source])
            if plan.transform:
                stats["transformed"][plan.transform] = stats["transformed"].get(plan.transform, 0) + 1
            if plan.quantize:
                weight, scales, biases = mx.quantize(value, group_size=GROUP_SIZE, bits=BITS, mode=MODE)
                scales = scales.astype(mx.bfloat16)
                biases = biases.astype(mx.bfloat16)
                mx.eval(weight, scales, biases)
                base = plan.target[: -len(".weight")]
                out[f"{base}.weight"] = weight
                out[f"{base}.scales"] = scales
                out[f"{base}.biases"] = biases
                stats["quantized"] += 1
            else:
                out[plan.target] = value
                stats["copied"] += 1
        return out, stats
    finally:
        del loaded
        mx.clear_cache()


def load_readout(path: Path) -> Any:
    import mlx.core as mx

    value = mx.load(str(path), stream=mx.cpu)["weight"]
    mx.eval(value)
    return value


def readout_shape(path: Path, options: int, hidden: int) -> tuple[int, ...]:
    tensors, _, _ = read_safetensors_header(path)
    if set(tensors) != {"weight"}:
        raise ValueError("readout.safetensors must hold exactly one tensor named 'weight'")
    entry = tensors["weight"]
    shape = tuple(int(dim) for dim in entry["shape"])
    if entry["dtype"] != "BF16" or shape != (options, hidden):
        raise ValueError(f"readout must be BF16 [{options}, {hidden}], got {entry['dtype']} {list(shape)}")
    return shape


def check_written_shard(path: Path, expected: dict[str, tuple[str, tuple[int, ...]]]) -> int:
    """Re-read the written header; return its tensor data byte count."""
    tensors, metadata, _ = read_safetensors_header(path)
    if metadata.get("format") != "mlx":
        raise ValueError(f"output shard lacks format=mlx metadata: {path.name}")
    if set(tensors) != set(expected):
        raise ValueError(f"output shard tensor set differs from plan: {path.name}")
    for key, (dtype, shape) in expected.items():
        if tensors[key]["dtype"] != dtype or tuple(tensors[key]["shape"]) != shape:
            raise ValueError(f"output tensor differs from plan: {key}")
    return sum(entry["data_offsets"][1] - entry["data_offsets"][0] for entry in tensors.values())


def model_card(mode: str, evidence: dict[str, Any]) -> bytes:
    if mode == "conformance":
        return (
            f"# Converter conformance output\n\nConversion of `{evidence['repo']}` revision "
            f"`{evidence['revision']}` with the pplx-decider converter, for layout comparison with "
            f"`{REFERENCE_REPO}`. Not for serving or publication.\n"
        ).encode()
    return f"""---
library_name: mlx
license: apache-2.0
base_model: {evidence['repo']}
tags:
- mlx
- qwen3_5
- q4
- {DECIDER_MODEL_TYPE}
---

# pplx-decider-v1-27b MLX Q4/g64

Private conversion of `{evidence['repo']}` revision `{evidence['revision']}`
(release manifest SHA-256 `{evidence.get('release_manifest_sha256')}`).

- Tensor layout of `{REFERENCE_REPO}`: mlx-vlm `qwen3_5` names, `format: mlx` shards.
- Affine 4-bit, group size 64, BF16 scales and biases, for every 2-D language
  tensor. Norms, conv1d, A_log, dt_bias and the vision tower stay BF16.
- `language_model.lm_head.weight` is the decider readout, BF16, not quantized.
  The `decision` block of `config.json` maps head rows to option codes and
  carries the calibration temperature.
- Apache-2.0; `LICENSE` and `NOTICE` are copied verbatim.
- Do not upload this tree without a new explicit authorization.
""".encode()


def convert(source: Path, output: Path, *, mode: str = "decider") -> dict[str, Any]:
    os.umask(0o077)
    source = source.resolve()
    output = output.absolute()
    if output.exists():
        raise ValueError(f"output must not exist: {output}")
    if mode == "decider":
        evidence = verify_release(source)
    elif mode == "conformance":
        evidence = verify_hub_snapshot(source, BASE_REPO, BASE_REVISION)
    else:
        raise ValueError(f"unknown mode: {mode}")
    if not evidence["ok"]:
        raise ValueError("source identity verification failed: " + "; ".join(evidence["errors"]))
    files = evidence["files"]
    snapshot = _snapshot_metadata(source, files)
    config = json.loads(snapshot["config.json"])
    index = json.loads(snapshot[INDEX])
    hidden, vocab_size, in_channels = validate_source_config(config)
    weight_map: dict[str, str] = index["weight_map"]
    if set(weight_map.values()) != set(evidence["shards"]):
        raise ValueError("source index shards differ from verified shards")
    headers = preflight_headers(source, weight_map)
    plans, dropped = plan_tensors(weight_map, headers, in_channels)
    head = select_head(plans, (source / READOUT).is_file())
    if head != ("readout" if mode == "decider" else "source"):
        raise ValueError(f"{mode} mode requires the {'readout' if mode == 'decider' else 'source lm_head'} head")
    decision = None
    head_shape = None
    if head == "readout":
        if "decision_config.json" not in snapshot or "tokenizer.json" not in snapshot:
            raise ValueError("readout head requires decision_config.json and tokenizer.json")
        decision = decision_block(json.loads(snapshot["decision_config.json"]),
                                  json.loads(snapshot["tokenizer.json"]), vocab_size)
        head_shape = readout_shape(source / READOUT, decision["options"], hidden)
    elif "decision_config.json" in snapshot:
        raise ValueError("decision_config.json present without a readout head")
    processor_files = (
        derive_processor_files(json.loads(snapshot["processor_config.json"]))
        if "processor_config.json" in snapshot else {}
    )
    if mode == "decider" and not processor_files:
        raise ValueError("decider conversion requires processor_config.json")
    config_out = output_config(config, decision)
    layout = expected_layout(plans, head_shape)
    source_targets = [plan.target for plan in plans] + ([LM_HEAD] if head == "readout" else [])
    validate_output_key_coverage(source_targets, layout)

    total_size = int((index.get("metadata") or {}).get("total_size") or 0)
    required = int(total_size * 0.35) + 8 * 1024**3
    free = shutil.disk_usage(output.parent).free
    if free < required:
        raise RuntimeError(f"insufficient disk: free={free} require~{required}")
    import mlx.core as mx

    runtime = runtime_provenance(mx)
    output.mkdir(mode=0o700)
    mx.reset_peak_memory()
    started = time.time()

    consumed: dict[str, str] = {}
    out_map: dict[str, str] = {}
    outputs: list[dict[str, Any]] = []
    shard_stats: list[dict[str, Any]] = []
    data_bytes = 0
    shard_names = sorted(evidence["shards"])
    for position, filename in enumerate(shard_names, start=1):
        shard_plans = [plan for plan in plans if plan.file == filename]
        print(f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} shard {position}/{len(shard_names)} "
              f"{filename} tensors={len(shard_plans)}", flush=True)
        tensors, stats = convert_shard(_verified_payload(source, filename, files, consumed), shard_plans)
        if head == "readout" and filename == shard_names[-1]:
            tensors[LM_HEAD] = load_readout(_verified_payload(source, READOUT, files, consumed))
            stats["readout"] = 1
        dest = output / filename
        mx.save_safetensors(str(dest), tensors, metadata=dict(SHARD_METADATA))
        os.chmod(dest, 0o600)
        data_bytes += check_written_shard(dest, {key: layout[key] for key in tensors})
        outputs.append({"file": filename, "bytes": dest.stat().st_size, "sha256": sha256_file(dest)})
        out_map.update(dict.fromkeys(tensors, filename))
        shard_stats.append({"file": filename, **stats})
        del tensors
        mx.clear_cache()
        mx.synchronize()

    validate_output_key_coverage(source_targets, out_map)
    if set(out_map) != set(layout):
        raise ValueError("output tensor set differs from plan")
    if head == "readout" and READOUT not in consumed:
        raise ValueError("readout was not consumed")

    out_index = {"metadata": {"total_size": data_bytes, "format": "mlx"}, "weight_map": dict(sorted(out_map.items()))}
    _write_new(output / INDEX, (json.dumps(out_index, indent=4) + "\n").encode())
    _write_new(output / "config.json", (json.dumps(config_out, indent=4) + "\n").encode())
    copied = [name for name in COPIED_METADATA if name in snapshot]
    for name in copied:
        _write_new(output / name, snapshot[name])
    for name, payload in processor_files.items():
        _write_new(output / name, payload)
    manifest = make_shard_manifest(evidence, consumed, outputs)
    _write_new(output / "shard-digests.json", (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode())
    _write_new(output / "README.md", model_card(mode, evidence))

    written = [INDEX, "config.json", *copied, *processor_files, "shard-digests.json", "README.md"]
    receipt = {
        "mode": mode,
        "source_repo": evidence["repo"],
        "source_revision": evidence["revision"],
        "release_manifest_sha256": evidence.get("release_manifest_sha256"),
        "source_metadata_snapshot_sha256": {
            name: hashlib.sha256(payload).hexdigest() for name, payload in sorted(snapshot.items())
        },
        "source_payloads_verified": True,
        "source_payload_sha256": dict(sorted(consumed.items())),
        "source_indexed_keys": len(weight_map),
        "source_dropped_keys": dropped,
        "output_indexed_keys": len(out_map),
        "all_source_tensor_identities_preserved": True,
        "head": {"source": head, "key": LM_HEAD, "quantized": head == "source",
                 "shape": list(head_shape) if head_shape else None},
        "decision": (
            {key: decision[key] for key in ("format_version", "options", "temperature", "max_input_tokens")}
            if decision else None
        ),
        "quantization": {
            **QUANTIZATION,
            "scales_biases_dtype": "bfloat16",
            "policy": "every 2-D language_model.* tensor except the readout head; last dim % 64 == 0 or refuse",
            "per_tensor_exceptions": 0,
        },
        "tensor_counts": {
            "quantized": sum(plan.quantize for plan in plans),
            "copied": sum(not plan.quantize for plan in plans) + (head == "readout"),
            "transformed": {
                name: sum(plan.transform == name for plan in plans)
                for name in sorted({plan.transform for plan in plans if plan.transform})
            },
        },
        "shard_metadata": SHARD_METADATA,
        "shard_stats": shard_stats,
        "load_stream": "cpu",
        "peak_memory_bytes": int(mx.get_peak_memory()),
        "elapsed_seconds": round(time.time() - started, 3),
        "converter_sha256": sha256_file(Path(__file__)),
        "provenance_helper_sha256": sha256_file(Path(__file__).with_name("pplx_decider_provenance.py")),
        "runtime_provenance": runtime,
        "output_shard_sha256": {item["file"]: item["sha256"] for item in outputs},
        "output_files_sha256": {name: sha256_file(output / name) for name in sorted(written)},
    }
    _write_new(output / "conversion-receipt.json", (json.dumps(receipt, indent=2, sort_keys=True) + "\n").encode())
    return receipt


def run_conformance(base: Path, reference: Path, output: Path, report_path: Path) -> dict[str, Any]:
    os.umask(0o077)
    if report_path.exists():
        raise ValueError(f"report must not exist: {report_path}")
    reference_evidence = verify_hub_snapshot(reference.resolve(), REFERENCE_REPO, REFERENCE_REVISION, hash_shards=True)
    if not reference_evidence["ok"]:
        raise ValueError("reference identity verification failed: " + "; ".join(reference_evidence["errors"]))
    receipt = convert(base, output, mode="conformance")
    report = compare_packs(output.absolute(), reference.resolve())
    report["base"] = {"repo": receipt["source_repo"], "revision": receipt["source_revision"],
                      "conversion_receipt_sha256": sha256_file(output.absolute() / "conversion-receipt.json")}
    report["reference_evidence"] = {
        key: reference_evidence[key]
        for key in ("repo", "revision", "verification_level", "source_payloads_verified", "shard_hash_checked")
    }
    report["runtime_provenance"] = receipt["runtime_provenance"]
    _write_new(report_path, (json.dumps(report, indent=2, sort_keys=True) + "\n").encode())
    return report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--source", type=Path, help="Verified pplx-decider download.")
    group.add_argument("--conformance-source", type=Path, help=f"Verified {BASE_REPO} download.")
    parser.add_argument("--conformance-reference", type=Path, help=f"Verified {REFERENCE_REPO} download.")
    parser.add_argument("--conformance-report", type=Path, help="New JSON report path.")
    parser.add_argument("--output", type=Path, required=True, help="New output directory.")
    args = parser.parse_args(argv)
    conformance = args.conformance_source is not None
    if conformance != (args.conformance_reference is not None) or conformance != (args.conformance_report is not None):
        parser.error("--conformance-source, --conformance-reference and --conformance-report go together")
    if conformance:
        report = run_conformance(args.conformance_source, args.conformance_reference, args.output, args.conformance_report)
        print(json.dumps({key: report[key] for key in ("layout_identical", "tensors_compared",
                                                        "bit_identical_tensors", "max_abs_diff")}, sort_keys=True))
        return 0 if report["layout_identical"] else 5
    receipt = convert(args.source, args.output, mode="decider")
    print(json.dumps({"ok": True, "output": str(args.output), "output_indexed_keys": receipt["output_indexed_keys"],
                      "elapsed_seconds": receipt["elapsed_seconds"], "peak_memory_bytes": receipt["peak_memory_bytes"]},
                     sort_keys=True), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
