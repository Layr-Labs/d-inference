#!/usr/bin/env python3
"""Convert official Qwen4Exp BF16 to affine Q4/g64 with in-tree MTP.

Shard-streaming: never concatenates the 128-part n-gram/PLE table and never
loads the full 180B parameter set into unified memory. Nemotron's converter
is used only as a receipt/security pattern.

Run from a neutral working directory (not a folder that contains profile.py).
This isolated hardening copy enforces the source pin and writes complete
source/output shard digests for future conversions. It does not attest the
historical September 10 output. No upload, registration, or publication.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import time
from pathlib import Path
from typing import Any, Iterable

from qwen38_provenance import (
    SOURCE_REPO,
    SOURCE_REVISION,
    make_shard_manifest,
    runtime_provenance,
    verify_source,
)


GROUP_SIZE = 64
BITS = 4
MODE = "affine"
NGRAM_KEY_RE = re.compile(r"\.ngram_embedding\.(?:shard_|shards\.)(\d+)(?:\.|$)")
SOURCE_REVISION_FIELD = "source_revision"
METADATA_NAMES = (
    "LICENSE",
    "README.md",
    "chat_template.jinja",
    "generation_config.json",
    "merges.txt",
    "preprocessor_config.json",
    "video_preprocessor_config.json",
    "tokenizer.json",
    "tokenizer_config.json",
    "vocab.json",
    ".gitattributes",
)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def classify_key(key: str) -> str:
    if key.startswith("mtp."):
        return "mtp"
    if NGRAM_KEY_RE.search(key):
        return "ngram"
    if ".ple." in key:
        return "ple"
    if key.startswith("model.visual") or key.startswith("vision_tower") or ".visual." in key:
        return "vision"
    return "target"


def ngram_part(key: str) -> int | None:
    match = NGRAM_KEY_RE.search(key)
    return int(match.group(1)) if match else None


def quantized_base(key: str) -> str:
    if key.endswith(".weight"):
        return key[: -len(".weight")]
    return key


def quant_params_for_shape(shape: tuple[int, ...], dtype: str) -> tuple[int, int] | None:
    """Return (group_size, bits) or None to leave the tensor unchanged.

    Global policy is Q4/g64. The official last-dimension 160 n-gram rows
    are not divisible by 64; they quantize Q4/g32 so the 51B table stays packed.
    """
    if any(token in dtype.lower() for token in ("int", "uint", "bool")):
        return None
    if len(shape) < 2:
        return None
    last = shape[-1]
    if last % GROUP_SIZE == 0:
        return GROUP_SIZE, BITS
    if last % 32 == 0:
        return 32, BITS
    return None


def should_quantize(shape: tuple[int, ...], dtype: str) -> bool:
    return quant_params_for_shape(shape, dtype) is not None


def inventory_from_index(index: dict[str, Any]) -> dict[str, Any]:
    weight_map: dict[str, str] = index["weight_map"]
    classes: dict[str, int] = {}
    ngram_parts: set[int] = set()
    mtp_keys: list[str] = []
    for key in weight_map:
        kind = classify_key(key)
        classes[kind] = classes.get(kind, 0) + 1
        part = ngram_part(key)
        if part is not None:
            ngram_parts.add(part)
        if kind == "mtp":
            mtp_keys.append(key)
    expected = set(range(128))
    return {
        "indexed_keys": len(weight_map),
        "shard_files": len(set(weight_map.values())),
        "classes": classes,
        "mtp_keys": sorted(mtp_keys),
        "mtp_count": len(mtp_keys),
        "ngram_parts": sorted(ngram_parts),
        "ngram_complete": ngram_parts == expected,
        "metadata_total_size": (index.get("metadata") or {}).get("total_size"),
    }


def _validate_source(
    source: Path, expected_revision: str | None, *, require_shards: bool = True
) -> dict[str, Any]:
    if expected_revision != SOURCE_REVISION:
        raise ValueError("source revision must equal the pinned official revision")
    evidence = verify_source(source, require_shards=require_shards)
    if not evidence["ok"]:
        raise ValueError("source identity verification failed: " + "; ".join(evidence["errors"]))
    config = json.loads((source / "config.json").read_text())
    if config.get("model_type") != "qwen4_exp":
        raise ValueError(f"unexpected model_type: {config.get('model_type')!r}")
    text = config.get("text_config") or {}
    if text.get("model_type") != "qwen4_exp_text":
        raise ValueError("expected qwen4_exp_text")
    if int(text.get("mtp_num_hidden_layers") or 0) != 1:
        raise ValueError("expected mtp_num_hidden_layers=1")
    index = json.loads((source / "model.safetensors.index.json").read_text())
    inventory = inventory_from_index(index)
    if not inventory["ngram_complete"]:
        raise ValueError(f"incomplete n-gram parts: {inventory['ngram_parts'][:8]}...")
    if inventory["mtp_count"] != 31:
        raise ValueError(f"unexpected MTP tensor count: {inventory['mtp_count']}")
    if require_shards:
        missing = [
            name
            for name in sorted(set(index["weight_map"].values()))
            if not (source / name).is_file()
        ]
        if missing:
            raise FileNotFoundError(
                f"source missing {len(missing)} shards, e.g. {missing[0]}"
            )
    return {
        "config": config,
        "index": index,
        "inventory": inventory,
        "source_revision": SOURCE_REVISION,
        "source_evidence": evidence,
        "config_sha256": sha256_file(source / "config.json"),
        "index_sha256": sha256_file(source / "model.safetensors.index.json"),
    }


def _copy_metadata(source: Path, output: Path) -> list[str]:
    copied: list[str] = []
    for name in METADATA_NAMES:
        src = source / name
        if not src.is_file():
            continue
        dest = output / name
        shutil.copy2(src, dest)
        os.chmod(dest, 0o600)
        copied.append(name)
    return copied


def validate_output_key_coverage(source_keys: Iterable[str], output_keys: Iterable[str]) -> None:
    """Every original tensor remains copied or has a complete affine triple.

    This is an identity/inventory invariant, including every embedded MTP
    tensor. It does not claim that quantization is numerically lossless.
    """
    outputs = set(output_keys)
    accounted: set[str] = set()
    for key in source_keys:
        base = quantized_base(key)
        triple = {f"{base}.weight", f"{base}.scales", f"{base}.biases"}
        companions = {f"{base}.scales", f"{base}.biases"}
        if outputs & companions:
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


def _quantize_once(array: Any, group_size: int, bits: int) -> tuple[Any, Any, Any]:
    import mlx.core as mx

    quantized, scales, biases = mx.quantize(
        array, group_size=group_size, bits=bits, mode=MODE
    )
    scales = scales.astype(mx.bfloat16)
    biases = biases.astype(mx.bfloat16)
    mx.eval(quantized, scales, biases)
    return quantized, scales, biases


def _quantize_chunked(
    array: Any, group_size: int, bits: int, chunk_rows: int
) -> tuple[Any, Any, Any]:
    import mlx.core as mx

    rows = int(array.shape[0])
    weights: list[Any] = []
    scales_parts: list[Any] = []
    biases_parts: list[Any] = []
    start = 0
    while start < rows:
        end = min(rows, start + chunk_rows)
        weight, scales, biases = _quantize_once(array[start:end], group_size, bits)
        weights.append(weight)
        scales_parts.append(scales)
        biases_parts.append(biases)
        start = end
    quantized = mx.concatenate(weights, axis=0)
    scales = mx.concatenate(scales_parts, axis=0)
    biases = mx.concatenate(biases_parts, axis=0)
    mx.eval(quantized, scales, biases)
    return quantized, scales, biases


def _chunk_rows_for(array: Any) -> int:
    rows = int(array.shape[0])
    trailing = 1
    for dim in array.shape[1:]:
        trailing *= int(dim)
    size = max(1, int(getattr(array, "size", rows * trailing)))
    nbytes = int(getattr(array, "nbytes", 0)) or (size * 2)
    item = max(1, nbytes // size)
    budget = 64 * 1024 * 1024
    return max(1, min(rows, budget // max(1, trailing * item)))


def _quantize_array(array: Any, group_size: int, bits: int) -> tuple[Any, Any, Any]:
    import mlx.core as mx

    try:
        return _quantize_once(array, group_size, bits)
    except RuntimeError as exc:
        message = str(exc)
        if "GPU Timeout" not in message and "kIOGPUCommandBufferCallbackErrorTimeout" not in message:
            raise
        mx.clear_cache()
        mx.synchronize()
        chunk_rows = _chunk_rows_for(array)
        print(
            f"gpu timeout; retry chunked rows={chunk_rows} shape={tuple(array.shape)}",
            flush=True,
        )
        return _quantize_chunked(array, group_size, bits, chunk_rows)


def convert_shard(
    source_file: Path,
    keys: Iterable[str],
) -> dict[str, Any]:
    import mlx.core as mx

    # USB-backed safetensors must not enter GPU as a single command buffer.
    # Loading on CPU, then quantizing, keeps the Metal watchdog off the disk path.
    loaded = mx.load(str(source_file), stream=mx.cpu)
    if loaded:
        mx.eval(*loaded.values())
    out: dict[str, Any] = {}
    stats: dict[str, Any] = {
        "copied": 0,
        "quantized": 0,
        "ngram": 0,
        "mtp": 0,
        "exceptions": [],
    }
    try:
        for key in keys:
            tensor = loaded[key]
            kind = classify_key(key)
            shape = tuple(tensor.shape)
            dtype = str(tensor.dtype)
            params = quant_params_for_shape(shape, dtype)
            if params is not None:
                group_size, bits = params
                weight, scales, biases = _quantize_array(tensor, group_size, bits)
                base = quantized_base(key)
                out[f"{base}.weight"] = weight
                out[f"{base}.scales"] = scales
                out[f"{base}.biases"] = biases
                stats["quantized"] += 1
                if group_size != GROUP_SIZE or bits != BITS:
                    stats["exceptions"].append(
                        {
                            "key": base,
                            "group_size": group_size,
                            "bits": bits,
                            "mode": MODE,
                        }
                    )
            else:
                out[key] = tensor
                stats["copied"] += 1
            if kind == "ngram":
                stats["ngram"] += 1
            elif kind == "mtp":
                stats["mtp"] += 1
        return {"tensors": out, "stats": stats}
    finally:
        del loaded
        mx.clear_cache()


def write_model_card(output: Path, receipt: dict[str, Any]) -> None:
    card = f"""---
library_name: mlx
tags:
- mlx
- qwen4_exp
- q4
---

# Qwen3.8-Flash-Next MLX Q4/g64 + embedded MTP

Private conversion from `{receipt.get('source_repo')}` revision
`{receipt.get('source_revision')}`.

- Global quantization: affine 4-bit, group size 64. This is **Q4**, not oQ4e.
- Trained MTP head retained in-tree under `mtp.*`.
- 128 n-gram/PLE shards remain packed safetensors for SSD row gathers.
- Vision tensors may be present; Darkbloom serving does not advertise vision
  until a separate qualification passes.
- Do not upload this tree without a new explicit authorization.
"""
    path = output / "README.md"
    path.write_text(card)
    os.chmod(path, 0o600)


def convert(source: Path, output: Path, source_revision: str, source_repo: str) -> dict[str, Any]:
    os.umask(0o077)
    source = source.resolve()
    output = output.absolute()
    if output.exists():
        raise ValueError(f"output must not exist: {output}")
    if source_repo != SOURCE_REPO:
        raise ValueError("source repository must equal the pinned official repository")
    meta = _validate_source(source, source_revision)
    index = meta["index"]
    estimated = int((meta["inventory"]["metadata_total_size"] or 0) * 0.35) + 8 * 1024**3
    free = shutil.disk_usage(output.parent).free
    if free < estimated:
        raise RuntimeError(f"insufficient disk: free={free} require~{estimated}")
    import mlx.core as mx

    runtime = runtime_provenance(mx)
    output.mkdir(mode=0o700)

    mx.reset_peak_memory()
    started = time.time()
    weight_map: dict[str, str] = {}
    shard_stats: list[dict[str, Any]] = []
    exceptions: list[dict[str, Any]] = []
    output_digests: list[dict[str, Any]] = []
    source_digests = {
        item["file"]: item for item in meta["source_evidence"]["source_shards"]
    }
    by_file: dict[str, list[str]] = {}
    for key, filename in index["weight_map"].items():
        by_file.setdefault(filename, []).append(key)

    shard_files = sorted(by_file.items())
    for index_i, (filename, keys) in enumerate(shard_files, start=1):
        print(
            f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} "
            f"shard {index_i}/{len(shard_files)} {filename} keys={len(keys)}",
            flush=True,
        )
        source_file = source / filename
        actual_source_digest = sha256_file(source_file)
        if actual_source_digest != source_digests[filename]["expected_sha256"]:
            raise ValueError(f"source shard payload hash mismatch: {filename}")
        source_digests[filename]["sha256"] = actual_source_digest
        converted = convert_shard(source_file, keys)
        validate_output_key_coverage(keys, converted["tensors"])
        dest = output / filename
        mx.save_safetensors(str(dest), converted["tensors"])
        os.chmod(dest, 0o600)
        output_digests.append({
            "file": filename,
            "bytes": dest.stat().st_size,
            "sha256": sha256_file(dest),
        })
        for name in converted["tensors"]:
            weight_map[name] = filename
        shard_exceptions = converted["stats"].pop("exceptions", [])
        exceptions.extend(shard_exceptions)
        shard_stats.append({"file": filename, **converted["stats"], "bytes": dest.stat().st_size})
        del converted
        mx.clear_cache()
        mx.synchronize()

    out_index = {
        "metadata": {
            "total_size": sum(item["bytes"] for item in shard_stats),
            "format": "mlx",
        },
        "weight_map": weight_map,
    }
    index_path = output / "model.safetensors.index.json"
    index_path.write_text(json.dumps(out_index, indent=2) + "\n")
    os.chmod(index_path, 0o600)

    config = meta["config"]
    quant: dict[str, Any] = {"group_size": GROUP_SIZE, "bits": BITS, "mode": MODE}
    for item in exceptions:
        quant[item["key"]] = {
            "bits": item["bits"],
            "group_size": item["group_size"],
            "mode": item["mode"],
        }
    config["quantization"] = quant
    config["quantization_config"] = quant
    config_path = output / "config.json"
    config_path.write_text(json.dumps(config, indent=2) + "\n")
    os.chmod(config_path, 0o600)
    copied = _copy_metadata(source, output)
    copied_set = set(copied)

    out_inventory = inventory_from_index(out_index)
    validate_output_key_coverage(index["weight_map"], weight_map)
    if not out_inventory["ngram_complete"]:
        # Quantized keys are base.weight; ngram_part still matches shard_N.
        ngram_weight_parts = {
            ngram_part(k)
            for k in weight_map
            if classify_key(k) == "ngram" and k.endswith(".weight")
        }
        if ngram_weight_parts != set(range(128)):
            raise ValueError(f"quantized n-gram parts incomplete: {sorted(ngram_weight_parts)[:8]}")

    mtp_quantized = sorted(
        k for k in weight_map if k.startswith("mtp.") and k.endswith(".weight")
    )
    if not mtp_quantized:
        raise ValueError("MTP head was not quantized into the output")

    manifest = make_shard_manifest(meta["source_evidence"], output_digests)
    manifest_path = output / "shard-digests.json"
    with manifest_path.open("x", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2, sort_keys=True)
        handle.write("\n")
    os.chmod(manifest_path, 0o600)

    receipt = {
        "source_repo": source_repo,
        SOURCE_REVISION_FIELD: source_revision,
        "source_config_sha256": meta["config_sha256"],
        "source_index_sha256": meta["index_sha256"],
        "source_mtp_tensors": meta["inventory"]["mtp_count"],
        "source_indexed_keys": meta["inventory"]["indexed_keys"],
        "output_indexed_keys": len(weight_map),
        "output_mtp_weight_tensors": mtp_quantized,
        "output_mtp_weight_count": len(mtp_quantized),
        "source_tensor_identity_count": len(index["weight_map"]),
        "all_source_tensor_identities_preserved": True,
        "ngram_parts": 128,
        "quantization": {
            "group_size": GROUP_SIZE,
            "bits": BITS,
            "mode": MODE,
            "label": "Q4",
            "per_tensor_exceptions": len(exceptions),
        },
        "oq4e": False,
        "copied_metadata": sorted(copied_set),
        "shard_stats": shard_stats,
        "peak_memory_bytes": int(mx.get_peak_memory()),
        "elapsed_seconds": round(time.time() - started, 3),
        "load_stream": "cpu",
        "converter_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "provenance_helper_sha256": sha256_file(Path(__file__).with_name("qwen38_provenance.py")),
        "python": sys.version.split()[0],
        "runtime_provenance": runtime,
        "source_payloads_verified": True,
        "source_shard_hash_checked": len(source_digests),
        "output_shard_hash_checked": len(output_digests),
        "shard_digest_manifest": {
            "file": manifest_path.name,
            "sha256": sha256_file(manifest_path),
        },
        "output_config_sha256": sha256_file(config_path),
        "output_index_sha256": sha256_file(index_path),
        "output_metadata_sha256": {
            name: sha256_file(output / name) for name in sorted(copied_set)
            if name != "README.md"
        },
    }
    write_model_card(output, receipt)
    receipt["output_metadata_sha256"]["README.md"] = sha256_file(output / "README.md")
    receipt_path = output / "conversion-receipt.json"
    with receipt_path.open("x", encoding="utf-8") as handle:
        json.dump(receipt, handle, indent=2, sort_keys=True)
        handle.write("\n")
    os.chmod(receipt_path, 0o600)
    return receipt


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--source-repo", default="Qwen/Qwen3.8-Flash-Next")
    parser.add_argument(
        "--source-revision",
        default="de4b8e4d43b917e7706784d8bb445c9af86a3540",
    )
    parser.add_argument(
        "--inventory-only",
        action="store_true",
        help="Validate the source index without writing weights",
    )
    args = parser.parse_args(argv)
    if args.source_repo != SOURCE_REPO or args.source_revision != SOURCE_REVISION:
        parser.error("source repository/revision must equal the pinned official source")
    os.umask(0o077)
    if args.inventory_only:
        meta = _validate_source(
            args.source.resolve(), args.source_revision, require_shards=False
        )
        json.dump(
            {
                "ok": True,
                "inventory": {
                    k: v
                    for k, v in meta["inventory"].items()
                    if k != "mtp_keys"
                },
                "mtp_count": meta["inventory"]["mtp_count"],
                "config_sha256": meta["config_sha256"],
                "index_sha256": meta["index_sha256"],
                "source_revision": meta["source_revision"],
                "source_payloads_verified": False,
                "verification_level": "metadata-and-inventory",
            },
            sys.stdout,
            indent=2,
            sort_keys=True,
        )
        sys.stdout.write("\n")
        return 0
    receipt = convert(args.source, args.output, args.source_revision, args.source_repo)
    print(
        json.dumps(
            {
                "ok": True,
                "output": str(args.output),
                "output_indexed_keys": receipt["output_indexed_keys"],
                "mtp_weight_count": receipt["output_mtp_weight_count"],
                "elapsed_seconds": receipt["elapsed_seconds"],
                "peak_memory_bytes": receipt["peak_memory_bytes"],
            },
            sort_keys=True,
        ),
        flush=True,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
