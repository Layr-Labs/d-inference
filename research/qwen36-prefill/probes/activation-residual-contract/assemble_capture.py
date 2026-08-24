#!/usr/bin/env python3
"""Validate and assemble striped E50 MLX captures without loading them twice."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any

import numpy as np


ACTIVATION_PATTERN = "activation-[0-9][0-9][0-9][0-9]-m*-k*.npy"
WEIGHT_FILE = "weight-dequantized-k-by-n.npy"


def sha256_file(path: Path, chunk_bytes: int = 8 * 1024 * 1024) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(chunk_bytes):
            digest.update(chunk)
    return digest.hexdigest()


def file_record(path: Path, root: Path) -> dict[str, Any]:
    return {
        "path": str(path.relative_to(root)),
        "bytes": path.stat().st_size,
        "sha256": sha256_file(path),
    }


def load_sidecar(array_path: Path) -> dict[str, Any]:
    sidecar = array_path.with_suffix(".json")
    if not sidecar.is_file():
        raise ValueError(f"missing activation sidecar: {sidecar}")
    return json.loads(sidecar.read_text(encoding="utf-8"))


def assemble(
    capture_directory: Path,
    output: Path,
    manifest_path: Path,
    *,
    expected_rows: int | None,
    expected_input_width: int | None,
    expected_output_width: int | None,
    provenance: str | None,
) -> dict[str, Any]:
    capture_directory = capture_directory.resolve()
    output = output.resolve()
    manifest_path = manifest_path.resolve()
    activation_paths = sorted(capture_directory.glob(ACTIVATION_PATTERN))
    if not activation_paths:
        raise ValueError(f"no activation chunks under {capture_directory}")

    chunks: list[tuple[Path, dict[str, Any], np.ndarray]] = []
    sequences: list[int] = []
    input_width: int | None = None
    total_rows = 0
    for path in activation_paths:
        metadata = load_sidecar(path)
        array = np.load(path, mmap_mode="r", allow_pickle=False)
        if array.ndim != 2 or array.dtype != np.float32:
            raise ValueError(f"{path} must be a float32 matrix")
        if list(array.shape) != metadata.get("export_shape"):
            raise ValueError(f"{path} disagrees with its sidecar shape")
        if input_width is None:
            input_width = int(array.shape[1])
        elif array.shape[1] != input_width:
            raise ValueError("activation chunks have different input widths")
        sequences.append(int(metadata["sequence"]))
        total_rows += int(array.shape[0])
        chunks.append((path, metadata, array))

    if sequences != list(range(len(sequences))):
        raise ValueError(f"capture sequences are not contiguous: {sequences}")
    if expected_rows is not None and total_rows != expected_rows:
        raise ValueError(f"captured {total_rows} rows, expected {expected_rows}")
    if expected_input_width is not None and input_width != expected_input_width:
        raise ValueError(
            f"captured input width {input_width}, expected {expected_input_width}")

    weight_path = capture_directory / WEIGHT_FILE
    weight_manifest_path = capture_directory / "weight-manifest.json"
    if not weight_path.is_file() or not weight_manifest_path.is_file():
        raise ValueError("missing dequantized weight or weight manifest")
    weight = np.load(weight_path, mmap_mode="r", allow_pickle=False)
    if weight.ndim != 2 or weight.dtype != np.float32:
        raise ValueError("dequantized weight must be a float32 matrix")
    if weight.shape[0] != input_width:
        raise ValueError(
            f"weight input width {weight.shape[0]} != activation width {input_width}")
    if expected_output_width is not None and weight.shape[1] != expected_output_width:
        raise ValueError(
            f"weight output width {weight.shape[1]}, expected {expected_output_width}")

    output.parent.mkdir(parents=True, exist_ok=True)
    assembled = np.lib.format.open_memmap(
        output,
        mode="w+",
        dtype=np.float32,
        shape=(total_rows, int(input_width)),
    )
    start = 0
    for _, _, array in chunks:
        end = start + array.shape[0]
        assembled[start:end] = array
        start = end
    assembled.flush()
    del assembled

    captured_files = [
        path
        for path in sorted(capture_directory.iterdir())
        if path.is_file()
        and path not in {output, manifest_path}
        and path.name != "sha256.txt"
    ]
    result: dict[str, Any] = {
        "schema_version": 1,
        "mechanism": "e50-activation-subspace-capture",
        "projection": "model.layers.12.linear_attn.out_proj",
        "provenance": provenance,
        "activation": {
            "shape": [total_rows, int(input_width)],
            "dtype": "float32",
            "chunk_count": len(chunks),
            "chunks": [
                {
                    "sequence": metadata["sequence"],
                    "source_shape": metadata["source_shape"],
                    **file_record(path, capture_directory),
                }
                for path, metadata, _ in chunks
            ],
            "assembled": file_record(output, capture_directory),
        },
        "weight": {
            "shape": list(weight.shape),
            "dtype": str(weight.dtype),
            "orientation": "input_width_by_output_width",
            "dequantized": file_record(weight_path, capture_directory),
            "manifest": json.loads(weight_manifest_path.read_text(encoding="utf-8")),
        },
        "captured_files": [
            file_record(path, capture_directory) for path in captured_files
        ],
    }
    manifest_path.write_text(
        json.dumps(result, indent=2, sort_keys=True, allow_nan=False) + "\n",
        encoding="utf-8",
    )
    return result


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--capture-directory", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--expected-rows", type=int)
    parser.add_argument("--expected-input-width", type=int)
    parser.add_argument("--expected-output-width", type=int)
    parser.add_argument("--provenance")
    return parser.parse_args()


def main() -> None:
    arguments = parse_args()
    result = assemble(
        arguments.capture_directory,
        arguments.output,
        arguments.manifest,
        expected_rows=arguments.expected_rows,
        expected_input_width=arguments.expected_input_width,
        expected_output_width=arguments.expected_output_width,
        provenance=arguments.provenance,
    )
    print(json.dumps(result, indent=2, sort_keys=True, allow_nan=False))


if __name__ == "__main__":
    main()
