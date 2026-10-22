#!/usr/bin/env python3
"""Recompute a cluster stage content inventory from an artifact's safetensors files.

An independent cross-check of `darkbloom-cluster-stage-check content-inventory`:
standard library only, no Swift, no MLX. It reads the safetensors files the
artifact's manifest lists, keeps the tensors a dense Qwen layer stage can own
(the language model's; vision and MTP tensors belong to no stage), hashes each
one's stored bytes, and writes the canonical document. That document, and so
its SHA-256, must equal the Swift tool's byte for byte.

It does not verify the artifact against the manifest's file hashes; the Swift
tool does. The model directory is only read.

    python3 scripts/cluster-stage-content-inventory.py --model-dir /ABS/MODEL \\
        --compare /ABS/inventory.txt --expect-layout-sha256 HEX
"""

import argparse
import fcntl
import hashlib
import json
from pathlib import Path
import struct
import sys

SCHEMA = "layer-stage-tensor-content-inventory-v1"
ELEMENT_BYTES = {"U32": 4, "F32": 4, "F16": 2, "BF16": 2}
EXCLUDED_PREFIXES = ("vision_tower.", "model.visual.", "mtp.", "language_model.mtp.")
MAXIMUM_HEADER_BYTES = 16 * 1024 * 1024
BLOCK_BYTES = 8 * 1024 * 1024


def stored_tensors(path):
    """Yield (name, dtype, shape, byte count, absolute offset) for one file."""
    size = path.stat().st_size
    with path.open("rb") as file:
        (length,) = struct.unpack("<Q", file.read(8))
        if length > MAXIMUM_HEADER_BYTES or length > size - 8:
            raise ValueError(f"{path.name}: invalid safetensors header length")
        header = json.loads(file.read(length))
    for name, entry in header.items():
        if name == "__metadata__":
            continue
        dtype, shape = entry["dtype"], entry["shape"]
        begin, end = entry["data_offsets"]
        if dtype not in ELEMENT_BYTES:
            raise ValueError(f"{path.name}: unsupported dtype {dtype} for {name}")
        count = ELEMENT_BYTES[dtype]
        for dimension in shape:
            count *= dimension
        if not shape or count <= 0 or end - begin != count or begin < 0 or end > size - 8 - length:
            raise ValueError(f"{path.name}: shape, dtype and data offsets disagree for {name}")
        yield name, dtype, shape, count, 8 + length + begin


def content_sha256(path, offset, count):
    digest = hashlib.sha256()
    with path.open("rb", buffering=0) as file:
        # Do not leave gigabytes of file cache behind: a stage load counts only free memory.
        if hasattr(fcntl, "F_NOCACHE"):
            fcntl.fcntl(file.fileno(), fcntl.F_NOCACHE, 1)
        file.seek(offset)
        while count:
            block = file.read(min(BLOCK_BYTES, count))
            if not block:
                raise ValueError(f"{path.name}: short read")
            digest.update(block)
            count -= len(block)
    return digest.hexdigest()


def inventory(model_dir):
    manifest = json.loads((model_dir / "manifest.json").read_text())
    files = sorted(entry["path"] for entry in manifest["files"] if entry["path"].endswith(".safetensors"))
    records, names = [], set()
    for file in files:
        if "/" in file:
            raise ValueError(f"{file}: a stage source file is not in a subdirectory")
        end = 0
        for name, dtype, shape, count, offset in sorted(stored_tensors(model_dir / file), key=lambda row: row[4]):
            if offset < end:
                raise ValueError(f"{file}: overlapping tensors")
            end = offset + count
            if name.startswith(EXCLUDED_PREFIXES):
                continue
            if name in names:
                raise ValueError(f"duplicate tensor name {name}")
            names.add(name)
            layout = f"{name}|{dtype}|{','.join(str(d) for d in shape)}|{count}"
            records.append((layout, file, offset, content_sha256(model_dir / file, offset, count), name, count))
    if not records:
        raise ValueError("no stage tensors found")
    lines = [SCHEMA, str(len(records))] + [f"{r[0]}|{r[1]}|{r[2]}|{r[3]}" for r in records]
    document = ("\n".join(lines) + "\n").encode("ascii")
    # Without file, offset and content: the layout inventory a registered profile pins.
    layout = "\n".join(r[0] for r in sorted(records, key=lambda r: r[4])).encode("ascii")
    return document, {
        "contentInventorySHA256": hashlib.sha256(document).hexdigest(),
        "layoutInventorySHA256": hashlib.sha256(layout).hexdigest(),
        "tensorCount": len(records),
        "payloadBytes": sum(r[5] for r in records),
        "encodedBytes": len(document),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--model-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, help="write the document here; never overwrites")
    parser.add_argument("--compare", type=Path, help="a document that must equal this one byte for byte")
    parser.add_argument("--expect-sha256", help="the pinned content inventory SHA-256")
    parser.add_argument("--expect-layout-sha256", help="the pinned layout inventory SHA-256")
    args = parser.parse_args()
    document, summary = inventory(args.model_dir.resolve())
    failures = []
    if args.compare is not None:
        summary["equalsCompared"] = args.compare.read_bytes() == document
        if not summary["equalsCompared"]:
            failures.append("document differs from --compare")
    if args.expect_sha256 is not None and args.expect_sha256 != summary["contentInventorySHA256"]:
        failures.append("content inventory SHA-256 differs from --expect-sha256")
    if args.expect_layout_sha256 is not None and args.expect_layout_sha256 != summary["layoutInventorySHA256"]:
        failures.append("layout inventory SHA-256 differs from --expect-layout-sha256")
    if args.output is not None:
        with args.output.open("xb") as file:
            file.write(document)
    summary["passed"] = not failures
    print(json.dumps(summary, sort_keys=True))
    for failure in failures:
        print("FAIL: " + failure, file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
