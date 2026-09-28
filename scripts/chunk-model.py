#!/usr/bin/env python3
"""Package an existing model manifest into cacheable R2 transport objects.

No network access or model/GPU libraries required. The input files and manifest
are never modified. Publish the output directory, with manifest.json last.
"""

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath

DEFAULT_CHUNK_BYTES = 480_000_000
MAX_CHUNK_BYTES = 499_999_999
BUFFER_BYTES = 1024 * 1024


def safe_path(value):
    if (not isinstance(value, str) or not value or "\\" in value
            or PurePosixPath(value).is_absolute()
            or any(part in ("", ".", "..") for part in value.split("/"))):
        raise ValueError(f"invalid model path: {value!r}")
    return value


def validate_manifest(manifest, chunk_bytes):
    if manifest.get("schema_version") != 1 or not manifest.get("files"):
        raise ValueError("expected a nonempty schema_version 1 manifest")
    files = manifest["files"]
    if manifest["file_count"] != len(files):
        raise ValueError("file_count does not match files")
    names = [safe_path(item["path"]).lower() for item in files]
    if len(set(names)) != len(names) or "manifest.json" in names:
        raise ValueError("duplicate or reserved model path")
    total_chunks = 0
    for item in files:
        size, digest = item["size_bytes"], item["sha256"]
        if type(size) is not int or size < 0:
            raise ValueError("invalid file size")
        if (not isinstance(digest, str) or len(digest) != 64
                or any(c not in "0123456789abcdef" for c in digest)):
            raise ValueError("invalid SHA-256")
        if size > chunk_bytes:
            total_chunks += (size + chunk_bytes - 1) // chunk_bytes
            for suffix in (".chunks", ".r2-transfer"):
                reserved = item["path"].lower() + suffix
                if any(n == reserved or n.startswith(reserved + "/") for n in names):
                    raise ValueError("model file overlaps chunk storage")
    if total_chunks > 4096:
        raise ValueError("manifest exceeds 4096 chunks; use a larger chunk size")
    if sum(item["size_bytes"] for item in files) != manifest["total_size_bytes"]:
        raise ValueError("total_size_bytes does not match files")
    aggregate = hashlib.sha256(b"".join(
        bytes.fromhex(item["sha256"]) for item in sorted(files, key=lambda x: x["path"])
    )).hexdigest()
    if aggregate != manifest["aggregate_sha256"]:
        raise ValueError("aggregate_sha256 does not match file hashes")


def package_model(manifest_path, model_dir, output_dir, chunk_bytes=DEFAULT_CHUNK_BYTES):
    if not 1 <= chunk_bytes <= MAX_CHUNK_BYTES:
        raise ValueError("chunk size must be between 1 and 499999999 bytes")
    manifest = json.loads(Path(manifest_path).read_text())
    validate_manifest(manifest, chunk_bytes)
    root, output = Path(model_dir).resolve(), Path(output_dir).resolve()
    if output == root or root in output.parents:
        raise ValueError("output directory must be outside the model directory")
    output.mkdir(parents=True, exist_ok=False)
    for item in manifest["files"]:
        source = (root / item["path"]).resolve()
        if root not in source.parents or not source.is_file():
            raise ValueError(f"source is outside model directory or missing: {item['path']}")
        if source.stat().st_size != item["size_bytes"]:
            raise ValueError(f"source size mismatch: {item['path']}")
        split = item["size_bytes"] > chunk_bytes
        item.pop("r2_chunks", None)
        chunks, whole_hash = [], hashlib.sha256()
        remaining = item["size_bytes"]
        with source.open("rb") as src:
            # Empty auxiliary files are still published as ordinary objects.
            for index in range(max(1, (remaining + chunk_bytes - 1) // chunk_bytes)):
                size = min(remaining, chunk_bytes)
                path = (f"{item['path']}.chunks/{index:06d}.bin" if split else item["path"])
                target = output / path
                target.parent.mkdir(parents=True, exist_ok=True)
                digest, left = hashlib.sha256(), size
                with target.open("xb") as dst:
                    while left:
                        data = src.read(min(left, BUFFER_BYTES))
                        if not data:
                            raise ValueError(f"source truncated: {item['path']}")
                        dst.write(data)
                        digest.update(data)
                        whole_hash.update(data)
                        left -= len(data)
                chunks.append({"size_bytes": size, "sha256": digest.hexdigest()})
                remaining -= size
            if src.read(1) or whole_hash.hexdigest() != item["sha256"]:
                raise ValueError(f"source checksum mismatch: {item['path']}")
        if split:
            item["r2_chunks"] = chunks
    # The unchanged file and aggregate hashes describe the reconstructed model.
    encoded = json.dumps(manifest, indent=2) + "\n"
    if len(encoded.encode()) > 1024 * 1024:
        raise ValueError("chunk manifest exceeds provider's 1 MiB limit")
    (output / "manifest.json").write_text(encoded)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--model-dir", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path,
                        help="new directory outside model-dir")
    parser.add_argument("--chunk-bytes", type=int, default=DEFAULT_CHUNK_BYTES)
    args = parser.parse_args()
    try:
        manifest = package_model(args.manifest, args.model_dir, args.output_dir, args.chunk_bytes)
    except (ValueError, OSError, KeyError) as exc:
        parser.exit(1, f"Packaging failed: {exc}\n")
    count = sum(len(f.get("r2_chunks", [])) for f in manifest["files"])
    print(f"Prepared {count} R2 chunks in {args.output_dir}; original hashes preserved.")


if __name__ == "__main__":
    main()
