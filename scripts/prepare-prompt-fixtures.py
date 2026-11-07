#!/usr/bin/env python3
"""Provision only hash-pinned public prompt assets from committed manifests.

This prepares inputs for Swift golden tests. It neither generates expected
vectors nor replaces the private platform's cross-implementation proof.
"""

import argparse
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import shutil
import stat
import struct
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

from verified_download_cache import restore_file, store_file

MAX_MANIFEST_BYTES = 1 << 20
MAX_ARTIFACT_BYTES = 128 << 20
MAX_CONTRACT_BYTES = 512 << 20
MAX_MODELS = 128
VERSIONS = {
    "normalization": "darkbloom-request-normalization-v9",
    "renderer": "swift-jinja-request-date-compatible-v4",
    "tokenizer": "huggingface-tokenizer-json-v1",
    "block_hash": "darkbloom-block-chain-v1",
    "block_size": 256,
}
PROMPT_ROLES = {"tokenizer", "template", "config"}
DOWNLOAD_ATTEMPTS = 3
RETRY_BACKOFF_SECONDS = (1, 3)
# A contract's downloads must finish within 120 s (the former flat limit) plus
# the time its missing bytes take at 128 KiB/s, at most 900 s. Run 42330647893
# moved the 17 MB Nemotron contract at under 142 KB/s and hit the flat 120 s.
BASE_DOWNLOAD_SECONDS = 120
MIN_DOWNLOAD_BYTES_PER_SECOND = 128 << 10
MAX_DOWNLOAD_SECONDS = 900


class TransientTransfer(ValueError):
    """A transfer that the network cut or the server failed; another attempt may succeed."""


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


def retryable(error):
    # Retry only a failed or cut transfer: a TLS, socket or connection error,
    # a timeout, an incomplete body, a short body or an HTTP 5xx. Integrity,
    # size, origin, client-status and deadline failures stay final.
    # HTTPError and FileExistsError are OSError subclasses: test them first.
    if isinstance(error, urllib.error.HTTPError):
        return error.code >= 500
    if isinstance(error, FileExistsError):
        return False  # An output this download did not create; never delete it.
    return isinstance(error, (OSError, http.client.IncompleteRead, TransientTransfer))


def download_once(opener, url, output, artifact, deadline):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise ValueError("contract download timed out")
    with opener.open(url, timeout=remaining) as response:
        if 500 <= response.status < 600:
            raise TransientTransfer("artifact request returned an HTTP server error")
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
        if count < artifact["size_bytes"]:
            raise TransientTransfer("artifact body ended before its declared size")
        if hasher.hexdigest() != artifact["sha256"]:
            raise ValueError("artifact SHA-256 mismatch")
    output.chmod(0o400)


def download_seconds(size_bytes):
    return min(MAX_DOWNLOAD_SECONDS, BASE_DOWNLOAD_SECONDS + size_bytes / MIN_DOWNLOAD_BYTES_PER_SECOND)


def download(opener, url, output, artifact, deadline):
    for attempt in range(DOWNLOAD_ATTEMPTS):
        try:
            return download_once(opener, url, output, artifact, deadline)
        except Exception as error:
            if not retryable(error) or attempt + 1 == DOWNLOAD_ATTEMPTS:
                raise
            delay = RETRY_BACKOFF_SECONDS[attempt]
            if time.monotonic() + delay >= deadline:
                raise ValueError("contract download timed out") from error
            # The next attempt opens the output with "xb", so drop the partial file.
            output.unlink(missing_ok=True)
            time.sleep(delay)


def provision(source, root, destination, cdn_url, download_cache=None):
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
    opener.addheaders = [("User-Agent", "darkbloom-prompt-fixtures/1")]
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
                started, missing = time.monotonic(), []
                # A download cache entry is used only if its bytes still have
                # the pinned size and digest; any other entry is downloaded.
                for artifact in artifacts:
                    output = temporary / artifact["path"]
                    output.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                    if download_cache is not None and restore_file(
                            download_cache, artifact["sha256"], artifact["size_bytes"], output):
                        output.chmod(0o400)
                    else:
                        missing.append((artifact, output))
                missing_bytes = sum(artifact["size_bytes"] for artifact, _ in missing)
                deadline = time.monotonic() + download_seconds(missing_bytes)
                for artifact, output in missing:
                    path = "/".join((cdn.path.rstrip("/"), manifest["r2_prefix"], artifact["path"]))
                    url = urllib.parse.urlunsplit((cdn.scheme, cdn.netloc, urllib.parse.quote(path, safe="/"), "", ""))
                    download(opener, url, output, artifact, deadline)
                    if download_cache is not None:
                        store_file(download_cache, artifact["sha256"], output)
                print(f"{manifest['model_id']}: {len(artifacts) - len(missing)} of {len(artifacts)} artifacts "
                      f"from the download cache, {len(missing)} downloaded ({missing_bytes} bytes) "
                      f"in {time.monotonic() - started:.1f} s", flush=True)
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
    parser.add_argument("--download-cache", type=Path,
                        help="content-addressed directory of verified downloads (scripts/verified_download_cache.py)")
    args = parser.parse_args()
    try:
        count = provision(args.manifest_source_directory, args.artifact_root,
                          args.manifest_directory, args.cdn_url, args.download_cache)
    except (OSError, ValueError, KeyError, TypeError, http.client.HTTPException) as error:
        parser.exit(1, f"prompt fixture provisioning failed: {error}\n")
    print(f"provisioned {count} pinned public prompt manifests (no weights)")


if __name__ == "__main__":
    main()
