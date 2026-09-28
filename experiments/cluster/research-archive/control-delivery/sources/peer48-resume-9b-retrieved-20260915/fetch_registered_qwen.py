#!/usr/bin/env python3
"""Fetch an isolated, hash-verified copy of the registered 9B benchmark model."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import datetime
import hashlib
import json
from pathlib import Path, PurePosixPath
import subprocess
from urllib.parse import quote

PREFIX = "v2/Qwen3.5-9B--3e3c04992a0d/2026-09-03-r1"
BASE = "https://models.darkbloom.ai/" + PREFIX + "/"
EXPECTED = "127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b"


def log(message):
    print(datetime.datetime.now(datetime.timezone.utc).isoformat(), message, flush=True)


def hash_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while True:
            chunk = source.read(8 * 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.digest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, default=Path.home() / "DarkbloomDev/models/Qwen3.5-9B")
    parser.add_argument("--limit-rate", default="20M", help="Per-file curl bandwidth limit")
    args = parser.parse_args()
    destination = args.directory.resolve()
    destination.mkdir(parents=True, exist_ok=True)
    (destination / "verification.json").unlink(missing_ok=True)
    manifest_path = destination / "manifest.json"
    manifest_part = destination / "manifest.json.part"
    subprocess.run(["curl", "--fail", "--location", "--silent", "--show-error", "--retry", "5", "--max-time", "60", BASE + "manifest.json", "--output", str(manifest_part)], check=True)
    manifest = json.loads(manifest_part.read_text())
    assert manifest["model_id"] == "Qwen3.5-9B"
    assert manifest["r2_prefix"] == PREFIX
    assert manifest["aggregate_sha256"] == EXPECTED
    entries = manifest["files"]
    assert len(entries) == manifest["file_count"] == 12
    assert sum(entry["size_bytes"] for entry in entries) == manifest["total_size_bytes"] == 6113952230
    assert len({entry["path"] for entry in entries}) == len(entries)
    for entry in entries:
        relative = PurePosixPath(entry["path"])
        assert not relative.is_absolute() and ".." not in relative.parts
        assert (destination / relative).resolve().is_relative_to(destination)
    declared = hashlib.sha256(b"".join(bytes.fromhex(entry["sha256"]) for entry in sorted(entries, key=lambda entry: entry["path"]))).hexdigest()
    assert declared == EXPECTED
    manifest_part.replace(manifest_path)

    def fetch(entry):
        path = destination / entry["path"]
        expected = bytes.fromhex(entry["sha256"])
        if path.exists() and path.stat().st_size == entry["size_bytes"] and hash_file(path) == expected:
            log("Verified existing " + entry["path"])
            return entry["path"], expected
        part = path.with_name(path.name + ".part")
        path.parent.mkdir(parents=True, exist_ok=True)
        if part.exists() and part.stat().st_size >= entry["size_bytes"]:
            if part.stat().st_size == entry["size_bytes"] and hash_file(part) == expected:
                part.replace(path)
                log("Verified completed partial " + entry["path"])
                return entry["path"], expected
            part.unlink()
        log("Downloading " + entry["path"])
        subprocess.run(["curl", "--fail", "--location", "--silent", "--show-error", "--retry", "5", "--retry-delay", "2", "--connect-timeout", "30", "--speed-limit", "1024", "--speed-time", "90", "--limit-rate", args.limit_rate, "--continue-at", "-", BASE + quote(entry["path"], safe="/"), "--output", str(part)], check=True)
        assert part.stat().st_size == entry["size_bytes"], "Size mismatch: " + entry["path"]
        digest = hash_file(part)
        assert digest == expected, "SHA256 mismatch: " + entry["path"]
        part.replace(path)
        log("Verified " + entry["path"])
        return entry["path"], digest

    # Download small metadata before the main weights so the fixture is inspectable early.
    with ThreadPoolExecutor(max_workers=2) as executor:
        verified = list(executor.map(fetch, sorted(entries, key=lambda entry: entry["size_bytes"])))
    aggregate = hashlib.sha256(b"".join(digest for _, digest in sorted(verified))).hexdigest()
    assert aggregate == EXPECTED
    result = {"model_id": manifest["model_id"], "version": manifest["version"], "aggregate_sha256": aggregate, "total_size_bytes": manifest["total_size_bytes"], "file_count": len(verified), "verified_at": datetime.datetime.now(datetime.timezone.utc).isoformat(), "source": BASE, "directory": str(destination), "algorithm": "SHA256(concatenated raw per-file SHA256 digests sorted by relative POSIX path), matching WeightHasher.hashFilesWithRelativeKey"}
    (destination / "verification.json").write_text(json.dumps(result, indent=2) + "\n")
    log("COMPLETE " + json.dumps(result))


if __name__ == "__main__":
    main()
