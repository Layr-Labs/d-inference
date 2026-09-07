#!/usr/bin/env python3
"""Verify a local benchmark artifact against the public registry manifest."""

import argparse
import hashlib
import json
from pathlib import Path
import re


def integrity_paths(directory):
    # Read the serving scanner's allowlist instead of maintaining a second
    # list that can silently drift when a new tokenizer/config file is added.
    source = Path(__file__).resolve().parents[2] / "provider-swift/Sources/ProviderCoreFoundation/ModelScanner.swift"
    text = source.read_text()
    names_block = text.split("public static let integrityFileNames:", 1)[1].split("]", 1)[0]
    extensions_block = text.split("public static let weightExtensions:", 1)[1].split("]", 1)[0]
    names = set(re.findall(r'"([^"\n]+)"', names_block))
    extensions = set(re.findall(r'"([^"\n]+)"', extensions_block))
    if not names or not extensions:
        raise ValueError("Could not read the serving scanner's integrity contract")
    return sorted(path for path in directory.rglob("*") if path.is_file()
                  and not any(part.startswith(".") for part in path.relative_to(directory).parts)
                  and (path.name in names or path.suffix in extensions))


def digest_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(8 << 20), b""):
            digest.update(block)
    return digest.digest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--model-directory", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    combined = hashlib.sha256()
    records = []
    digests = {}
    for item in sorted(manifest["files"], key=lambda item: item["path"]):
        relative = Path(item["path"])
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError("Manifest paths must be relative without parent traversal")
        path = args.model_directory / relative
        digest = digest_file(path)
        digests[path] = digest
        combined.update(digest)
        records.append({"path": str(relative), "sha256": digest.hex(),
                        "size_bytes": path.stat().st_size,
                        "matched": digest.hex() == item["sha256"]
                        and path.stat().st_size == item["size_bytes"]})
    actual = hashlib.sha256()
    actual_paths = integrity_paths(args.model_directory)
    for path in actual_paths:
        actual.update(digests[path] if path in digests else digest_file(path))
    expected_paths = {item["path"] for item in manifest["files"]}
    extras = [str(path.relative_to(args.model_directory)) for path in actual_paths
              if str(path.relative_to(args.model_directory)) not in expected_paths]
    result = {"model_id": manifest["model_id"],
              "model_directory": str(args.model_directory.resolve()),
              "expected_aggregate": manifest["aggregate_sha256"],
              "manifest_member_aggregate": combined.hexdigest(),
              "actual_aggregate": actual.hexdigest(), "extra_integrity_files": extras,
              "scope": "complete serving integrity set, including unexpected recognized files",
              "files": records}
    result["passed"] = all(item["matched"] for item in records) and (
        not extras and result["actual_aggregate"] == result["expected_aggregate"])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({key: value for key, value in result.items() if key != "files"}))
    raise SystemExit(0 if result["passed"] else 1)


if __name__ == "__main__":
    main()
