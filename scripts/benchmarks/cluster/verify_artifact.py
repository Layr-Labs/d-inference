#!/usr/bin/env python3
"""Check a model directory against a catalog manifest, file by file.

Identity comes from the manifest, not from the directory's name: every file
the manifest lists must exist with the listed size and SHA-256. Reads only;
nothing in the directory is changed. Standard library only (runs on Python
3.9 and later).

    verify_artifact.py --manifest gpt-oss-20b.manifest.json --dir /abs/model [--receipt out.json]

Exit status 0 only when every listed file matches. The receipt records the
model id, version and aggregate from the manifest, the per-file result, extra
files found in the directory that the manifest does not list, and how long
hashing took. It contains no path outside the model directory.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import time


def sha256_of(path, chunk=8 << 20):
    digest = hashlib.sha256()
    with open(path, "rb", buffering=0) as handle:
        while True:
            block = handle.read(chunk)
            if not block:
                break
            digest.update(block)
    return digest.hexdigest()


def verify(manifest, directory, sizes_only=False):
    started = time.perf_counter()
    files, matched, hashed_bytes = [], 0, 0
    for entry in manifest.get("files", []):
        path = os.path.join(directory, entry["path"])
        result = {"path": entry["path"], "size_bytes": entry["size_bytes"], "role": entry.get("role")}
        if not os.path.isfile(path):
            result["result"] = "missing"
        elif os.path.getsize(path) != entry["size_bytes"]:
            result["result"] = "size differs"
            result["found_size_bytes"] = os.path.getsize(path)
        elif sizes_only:
            result["result"] = "size equal (not hashed)"
        else:
            found = sha256_of(path)
            hashed_bytes += entry["size_bytes"]
            result["result"] = "match" if found == entry["sha256"] else "sha256 differs"
            if found != entry["sha256"]:
                result["found_sha256"] = found
        matched += result["result"] == "match"
        files.append(result)
    listed = {entry["path"] for entry in manifest.get("files", [])}
    extra = []
    for root, _dirs, names in os.walk(directory):
        for name in names:
            relative = os.path.relpath(os.path.join(root, name), directory)
            if relative not in listed:
                extra.append(relative)
    return {
        "model_id": manifest.get("model_id"), "version": manifest.get("version"),
        "aggregate_sha256": manifest.get("aggregate_sha256"),
        "manifest_file_count": len(files), "manifest_total_bytes": manifest.get("total_size_bytes"),
        "matched_files": matched, "identical": (not sizes_only) and matched == len(files) and bool(files),
        "sizes_only": sizes_only, "files": files, "extra_files": sorted(extra)[:50],
        "hashed_bytes": hashed_bytes, "seconds": round(time.perf_counter() - started, 1),
        "checked_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--dir", required=True)
    parser.add_argument("--receipt")
    parser.add_argument("--sizes-only", action="store_true", help="compare names and sizes without hashing")
    arguments = parser.parse_args()
    with open(arguments.manifest, encoding="utf-8") as handle:
        manifest = json.load(handle)
    receipt = verify(manifest, arguments.dir, arguments.sizes_only)
    text = json.dumps(receipt, indent=1, sort_keys=True)
    if arguments.receipt:
        with open(arguments.receipt, "x", encoding="utf-8") as handle:
            handle.write(text + "\n")
    bad = [item for item in receipt["files"] if item["result"] not in ("match", "size equal (not hashed)")]
    print(f"{receipt['model_id']} {receipt['version']}: {receipt['matched_files']}/{receipt['manifest_file_count']} "
          f"files match; identical={receipt['identical']}; extra files {len(receipt['extra_files'])}; "
          f"{receipt['seconds']}s" + ("; problems: " + ", ".join(f"{item['path']} ({item['result']})" for item in bad)
                                      if bad else ""))
    return 0 if receipt["identical"] else 1


if __name__ == "__main__":
    sys.exit(main())
