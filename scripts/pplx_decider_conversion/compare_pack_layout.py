#!/usr/bin/env python3
"""Compare two MLX packs tensor by tensor: names, shapes, dtypes, then values.

Layout comes from the index and the safetensors headers (no MLX). Values are
compared byte for byte, streaming. Only tensors whose bytes differ are loaded
with MLX to report a max abs diff (dequantized for affine triples).
"""
from __future__ import annotations

import argparse
import contextlib
import json
import os
from pathlib import Path
from types import SimpleNamespace
from typing import Any

from pplx_decider_provenance import INDEX, SAFE_NAME_RE, read_safetensors_header

CHUNK = 16 * 1024 * 1024
ROW_CHUNK = 4096


def pack_layout(pack: Path) -> tuple[dict[str, dict[str, Any]], dict[str, str | None]]:
    weight_map = json.loads((pack / INDEX).read_text())["weight_map"]
    layout: dict[str, dict[str, Any]] = {}
    formats: dict[str, str | None] = {}
    for name in sorted(set(weight_map.values())):
        if not SAFE_NAME_RE.fullmatch(name):
            raise ValueError(f"unsafe shard name: {name!r}")
        tensors, metadata, data_start = read_safetensors_header(pack / name)
        formats[name] = metadata.get("format")
        if set(tensors) != {key for key, file in weight_map.items() if file == name}:
            raise ValueError(f"index and shard header disagree: {pack.name}/{name}")
        for key, entry in tensors.items():
            start, end = entry["data_offsets"]
            layout[key] = {"path": pack / name, "dtype": entry["dtype"], "shape": list(entry["shape"]),
                           "offset": data_start + start, "length": end - start}
    return layout, formats


def _bytes_equal(first: Any, second: Any, a: dict[str, Any], b: dict[str, Any]) -> bool:
    if a["length"] != b["length"]:
        return False
    first.seek(a["offset"])
    second.seek(b["offset"])
    remaining = a["length"]
    while remaining:
        size = min(CHUNK, remaining)
        if first.read(size) != second.read(size):
            return False
        remaining -= size
    return True


def _mlx_load(location: dict[str, Any], key: str) -> Any:
    import mlx.core as mx

    return mx.load(str(location["path"]))[key]


def _mlx_dense(ours: dict[str, Any], reference: dict[str, Any]) -> dict[str, Any]:
    import mlx.core as mx

    a = _mlx_load(ours["tensor"], ours["key"]).astype(mx.float32)
    b = _mlx_load(reference["tensor"], reference["key"]).astype(mx.float32)
    return {"max_abs_diff": float(mx.max(mx.abs(a - b)).item())}


def _mlx_quantized(ours: dict[str, Any], reference: dict[str, Any]) -> dict[str, Any]:
    import mlx.core as mx

    def parts(side: dict[str, Any]) -> list[Any]:
        return [_mlx_load(side[part], f"{side['base']}.{part}") for part in ("weight", "scales", "biases")]

    wa, sa, ba = parts(ours)
    wb, sb, bb = parts(reference)
    worst = 0.0
    words = 0
    for start in range(0, int(wa.shape[0]), ROW_CHUNK):
        rows = slice(start, start + ROW_CHUNK)
        da = mx.dequantize(wa[rows], sa[rows], ba[rows], group_size=64, bits=4, mode="affine").astype(mx.float32)
        db = mx.dequantize(wb[rows], sb[rows], bb[rows], group_size=64, bits=4, mode="affine").astype(mx.float32)
        worst = max(worst, float(mx.max(mx.abs(da - db)).item()))
        words += int(mx.sum(wa[rows] != wb[rows]).item())
    return {"max_abs_diff": worst, "packed_words_differing": words}


MLX_NUMERIC = SimpleNamespace(dense=_mlx_dense, quantized=_mlx_quantized)


def _config_differences(ours: Path, reference: Path) -> list[dict[str, Any]]:
    a = json.loads((ours / "config.json").read_text())
    b = json.loads((reference / "config.json").read_text())
    differences = []
    for key in sorted(set(a) | set(b)):
        if key in ("text_config", "vision_config") and isinstance(a.get(key), dict) and isinstance(b.get(key), dict):
            pairs = [(f"{key}.{sub}", a[key].get(sub), b[key].get(sub)) for sub in sorted(set(a[key]) | set(b[key]))]
        else:
            pairs = [(key, a.get(key), b.get(key))]
        differences.extend({"key": k, "ours": x, "reference": y} for k, x, y in pairs if x != y)
    return differences


def compare_packs(ours: Path, reference: Path, numeric: Any = MLX_NUMERIC) -> dict[str, Any]:
    a, a_formats = pack_layout(ours)
    b, b_formats = pack_layout(reference)
    common = sorted(set(a) & set(b))
    shape_mismatch = [{"key": k, "ours": a[k]["shape"], "reference": b[k]["shape"]}
                      for k in common if a[k]["shape"] != b[k]["shape"]]
    dtype_mismatch = [{"key": k, "ours": a[k]["dtype"], "reference": b[k]["dtype"]}
                      for k in common if a[k]["dtype"] != b[k]["dtype"]]
    comparable = [k for k in common if a[k]["shape"] == b[k]["shape"] and a[k]["dtype"] == b[k]["dtype"]]
    differing: list[str] = []
    with contextlib.ExitStack() as stack:
        # One handle set per side: comparing a pack with itself must not share file positions.
        ours_handles, reference_handles = (
            {path: stack.enter_context(path.open("rb")) for path in {entry["path"] for entry in side.values()}}
            for side in (a, b)
        )
        for key in comparable:
            if not _bytes_equal(ours_handles[a[key]["path"]], reference_handles[b[key]["path"]], a[key], b[key]):
                differing.append(key)

    comparable_set = set(comparable)
    values: list[dict[str, Any]] = []
    grouped: set[str] = set()
    for key in differing:
        base = key.rsplit(".", 1)[0]
        triple = [f"{base}.{part}" for part in ("weight", "scales", "biases")]
        if f"{base}.scales" in a and all(name in comparable_set for name in triple):
            if base in grouped:
                continue
            grouped.add(base)
            sides = [{"base": base, **{part: side[f"{base}.{part}"] for part in ("weight", "scales", "biases")}}
                     for side in (a, b)]
            values.append({"tensor": base, "kind": "quantized", **numeric.quantized(*sides)})
        else:
            sides = [{"key": key, "tensor": side[key]} for side in (a, b)]
            values.append({"tensor": key, "kind": "dense", **numeric.dense(*sides)})
    layout_identical = set(a) == set(b) and not shape_mismatch and not dtype_mismatch
    return {
        "layout_identical": layout_identical,
        "ours": {"path": str(ours), "tensors": len(a), "shard_formats": a_formats},
        "reference": {"path": str(reference), "tensors": len(b), "shard_formats": b_formats},
        "missing_in_ours": sorted(set(b) - set(a)),
        "extra_in_ours": sorted(set(a) - set(b)),
        "shape_mismatch": shape_mismatch,
        "dtype_mismatch": dtype_mismatch,
        "tensors_compared": len(comparable),
        "bit_identical_tensors": len(comparable) - len(differing),
        "differing_tensors": differing,
        "value_differences": values,
        "max_abs_diff": max((item["max_abs_diff"] for item in values), default=0.0),
        "config_differences": _config_differences(ours, reference),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ours", type=Path, required=True)
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True, help="New JSON report path; never overwritten.")
    args = parser.parse_args(argv)
    if args.report.exists():
        parser.error(f"report must not exist: {args.report}")
    os.umask(0o077)
    report = compare_packs(args.ours.resolve(), args.reference.resolve())
    with args.report.open("x", encoding="utf-8") as handle:
        json.dump(report, handle, indent=2, sort_keys=True)
        handle.write("\n")
    print(json.dumps({key: report[key] for key in ("layout_identical", "tensors_compared",
                                                    "bit_identical_tensors", "max_abs_diff")}, sort_keys=True))
    return 0 if report["layout_identical"] else 5


if __name__ == "__main__":
    raise SystemExit(main())
