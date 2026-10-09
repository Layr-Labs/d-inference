#!/usr/bin/env python3
"""Provision only hash-pinned public prompt assets from committed manifests.

This prepares inputs for Swift golden tests. It neither generates expected
vectors nor replaces the private platform's cross-implementation proof.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import struct
import tempfile
import time
import urllib.parse
import urllib.request

MAX_MANIFEST_BYTES = 1 << 20
MAX_ARTIFACT_BYTES = 128 << 20
MAX_CONTRACT_BYTES = 512 << 20
MAX_MODELS = 128
VERSIONS = {
    "normalization": "darkbloom-request-normalization-v8",
    "renderer": "swift-jinja-request-date-compatible-v4",
    "tokenizer": "huggingface-tokenizer-json-v1",
    "block_hash": "darkbloom-block-chain-v1",
    "block_size": 256,
}
PROMPT_ROLES = {"tokenizer", "template", "config"}


def relative_path(value):
    if (not isinstance(value, str) or not value or "\\" in value
            or any(ord(c) < 32 for c in value)
            or any(part in {"", ".", ".."} for part in value.split("/"))):
        raise ValueError("unsafe relative artifact path")
    return value


def digest(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
        raise ValueError("invalid SHA-256")
    return bytes.fromhex(value)


def safe_directory(path, create=False):
    path = Path(path)
    if not path.is_absolute() or str(path) != os.path.normpath(str(path)):
        raise ValueError("directory must be absolute and clean")
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        if create and not current.exists() and not current.is_symlink():
            current.mkdir(mode=0o700)
        if not stat.S_ISDIR(current.lstat().st_mode):
            raise ValueError("directory path contains a symlink or non-directory")
    return path


def read_regular(path, limit):
    # Reject links and special files before opening; O_NOFOLLOW closes the
    # final-component replacement race on supported qualification platforms.
    if not stat.S_ISREG(path.lstat().st_mode):
        raise ValueError("expected regular fixture file")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as source:
        if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
            raise ValueError("expected regular fixture file")
        data = source.read(limit + 1)
    if len(data) > limit:
        raise ValueError("fixture exceeds byte bound")
    return data


def contract_id(artifacts):
    encoded = bytearray()

    def field(value):
        encoded.extend(struct.pack(">I", len(value)))
        encoded.extend(value)

    field(b"darkbloom.prompt-contract.v1")
    encoded.extend(struct.pack(">I", len(artifacts)))
    for item in sorted(artifacts, key=lambda a: (a["role"], a["path"], a["sha256"])):
        field(item["role"].encode())
        field(item["path"].encode())
        field(digest(item["sha256"]))
    for key, value in VERSIONS.items():
        field(key.encode())
        if key == "block_size":
            encoded.extend(struct.pack(">I", value))
        else:
            field(value.encode())
    return hashlib.sha256(encoded).hexdigest()


def validate_manifest(manifest):
    model = manifest.get("model_id")
    if manifest.get("schema_version") != 1 or not isinstance(model, str) or not model or "\0" in model:
        raise ValueError("invalid manifest identity")
    relative_path(manifest["r2_prefix"])
    files = manifest["files"]
    if not isinstance(files, list) or not files:
        raise ValueError("empty manifest")
    paths = set()
    artifacts = []
    for item in files:
        path = relative_path(item["path"])
        if path in paths or path == "prompt-contract.json":
            raise ValueError("duplicate or reserved artifact path")
        paths.add(path)
        digest(item["sha256"])
        if type(item["size_bytes"]) is not int or item["size_bytes"] < 0:
            raise ValueError("invalid artifact size")
        if item["role"] in PROMPT_ROLES:
            artifacts.append({key: item[key] for key in ("path", "role", "size_bytes", "sha256")})
    aggregate = hashlib.sha256(b"".join(
        digest(item["sha256"]) for item in sorted(files, key=lambda a: (a["path"], a["sha256"]))
    )).digest()
    if aggregate != digest(manifest["aggregate_sha256"]):
        raise ValueError("manifest aggregate hash mismatch")
    if (not artifacts or any(a["size_bytes"] > MAX_ARTIFACT_BYTES for a in artifacts)
            or sum(a["size_bytes"] for a in artifacts) > MAX_CONTRACT_BYTES):
        raise ValueError("prompt artifact byte budget exceeded")
    return sorted(artifacts, key=lambda a: a["path"])


def https_url(value):
    parsed = urllib.parse.urlsplit(value)
    if (parsed.scheme != "https" or not parsed.netloc or parsed.username is not None
            or parsed.password is not None or parsed.query or parsed.fragment):
        raise ValueError("CDN URL must be an uncredentialed HTTPS origin/path")
    return parsed


class SameOriginRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        old, new = urllib.parse.urlsplit(req.full_url), https_url(newurl)
        if (old.scheme, old.netloc) != (new.scheme, new.netloc):
            raise ValueError("cross-origin artifact redirect")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def download(opener, url, output, artifact, deadline):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise ValueError("contract download timed out")
    with opener.open(url, timeout=remaining) as response:
        if response.status != 200:
            raise ValueError("artifact request did not return HTTP 200")
        original, final = https_url(url), https_url(response.url)
        if (original.scheme, original.netloc) != (final.scheme, final.netloc):
            raise ValueError("cross-origin artifact response")
        length = response.headers.get("Content-Length")
        if length is not None and int(length) != artifact["size_bytes"]:
            raise ValueError("artifact Content-Length mismatch")
        hasher, count = hashlib.sha256(), 0
        with output.open("xb") as target:
            while True:
                if time.monotonic() > deadline:
                    raise ValueError("contract download timed out")
                chunk = response.read(min(65536, artifact["size_bytes"] + 1 - count))
                if not chunk:
                    break
                count += len(chunk)
                if count > artifact["size_bytes"]:
                    raise ValueError("artifact exceeds declared size")
                hasher.update(chunk)
                target.write(chunk)
        if count != artifact["size_bytes"] or hasher.hexdigest() != artifact["sha256"]:
            raise ValueError("artifact size or SHA-256 mismatch")
    output.chmod(0o400)


def provision(source, root, destination, cdn_url):
    source = safe_directory(source)
    root = safe_directory(root, create=True)
    destination = safe_directory(destination, create=True)
    if any(destination.iterdir()):
        raise ValueError("manifest directory must be empty")
    cdn = https_url(cdn_url)
    entries = sorted(source.iterdir())
    if not 0 < len(entries) <= MAX_MODELS:
        raise ValueError("manifest count exceeds bounds or is empty")
    # Validate every pinned manifest before any network access.
    manifests, seen = [], set()
    for entry in entries:
        if entry.suffix != ".json":
            raise ValueError("invalid manifest entry")
        raw = read_regular(entry, MAX_MANIFEST_BYTES)
        manifest = json.loads(raw)
        artifacts = validate_manifest(manifest)
        if manifest["model_id"] in seen:
            raise ValueError("duplicate model identity")
        seen.add(manifest["model_id"])
        manifests.append((raw, manifest, artifacts))
    opener = urllib.request.build_opener(SameOriginRedirect())
    for raw, manifest, artifacts in manifests:
        identity = contract_id(artifacts)
        metadata = {
            "schema_version": 1, "prompt_contract_id": identity,
            "model_id": manifest["model_id"],
            "model_aggregate_sha256": manifest["aggregate_sha256"],
            "artifacts": artifacts, "versions": VERSIONS,
        }
        encoded = json.dumps(metadata, separators=(",", ":")).encode()
        if len(encoded) > MAX_MANIFEST_BYTES:
            raise ValueError("metadata exceeds byte bound")
        contract = root / identity
        if contract.exists() or contract.is_symlink():
            safe_directory(contract)
            existing = json.loads(read_regular(contract / "prompt-contract.json", MAX_MANIFEST_BYTES))
            # Shared prompt bytes can belong to different models/weight revisions.
            if any(existing.get(key) != metadata[key] for key in
                   ("schema_version", "prompt_contract_id", "artifacts", "versions")):
                raise ValueError("cached contract metadata mismatch")
            for artifact in artifacts:
                path = contract / artifact["path"]
                safe_directory(path.parent)
                data = read_regular(path, artifact["size_bytes"])
                if len(data) != artifact["size_bytes"] or hashlib.sha256(data).hexdigest() != artifact["sha256"]:
                    raise ValueError("cached artifact integrity failure")
        else:
            temporary = Path(tempfile.mkdtemp(prefix=".tmp-", dir=root))
            try:
                deadline = time.monotonic() + 120
                for artifact in artifacts:
                    output = temporary / artifact["path"]
                    output.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                    path = "/".join((cdn.path.rstrip("/"), manifest["r2_prefix"], artifact["path"]))
                    url = urllib.parse.urlunsplit((cdn.scheme, cdn.netloc, urllib.parse.quote(path, safe="/"), "", ""))
                    download(opener, url, output, artifact, deadline)
                (temporary / "prompt-contract.json").write_bytes(encoded)
                (temporary / "prompt-contract.json").chmod(0o400)
                for directory, _, _ in os.walk(temporary, topdown=False):
                    Path(directory).chmod(0o500)
                temporary.rename(contract)
            finally:
                if temporary.exists():
                    for directory, _, _ in os.walk(temporary):
                        Path(directory).chmod(0o700)
                    shutil.rmtree(temporary)
        name = hashlib.sha256(manifest["model_id"].encode()).hexdigest() + ".json"
        output = destination / name
        with output.open("xb") as target:
            target.write(raw)
        output.chmod(0o600)
    return len(manifests)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest-source-directory", required=True)
    parser.add_argument("--artifact-root", required=True)
    parser.add_argument("--manifest-directory", required=True)
    parser.add_argument("--cdn-url", default="https://models.darkbloom.ai")
    args = parser.parse_args()
    try:
        count = provision(args.manifest_source_directory, args.artifact_root,
                          args.manifest_directory, args.cdn_url)
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, f"prompt fixture provisioning failed: {error}\n")
    print(f"provisioned {count} pinned public prompt manifests (no weights)")


if __name__ == "__main__":
    main()
