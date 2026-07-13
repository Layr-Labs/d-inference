from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import stat
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Mapping

COSIGN_CLIENT = Path("/usr/local/bin/cosign")
GITHUB_CLIENT = Path("/usr/bin/gh")
GITHUB_OIDC_ISSUER = "https://token.actions.githubusercontent.com"
GITHUB_REPOSITORY = "Layr-Labs/d-inference"


class IntegrityError(ValueError):
    """Evidence integrity or signature validation failed."""


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def format_timestamp(value: datetime) -> str:
    if value.tzinfo is None:
        raise IntegrityError("timestamp must be timezone-aware")
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def parse_timestamp(value: Any, field: str) -> datetime:
    if not isinstance(value, str) or not value:
        raise IntegrityError(f"{field} must be a non-empty RFC3339 timestamp")
    normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError as error:
        raise IntegrityError(f"{field} must be a valid RFC3339 timestamp") from error
    if parsed.tzinfo is None:
        raise IntegrityError(f"{field} must include an explicit timezone")
    return parsed.astimezone(timezone.utc)


def payload_without_integrity(document: Mapping[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in document.items() if key != "integrity"}


def seal_document(
    document: Mapping[str, Any],
    *,
    signing_key: Path | None = None,
) -> dict[str, Any]:
    if "integrity" in document:
        raise IntegrityError("document is already sealed")
    payload = dict(document)
    encoded = canonical_bytes(payload)
    integrity: dict[str, Any] = {
        "algorithm": "sha256",
        "canonical_sha256": sha256_bytes(encoded),
    }
    if signing_key is not None:
        signature, key_id = _sign(encoded, signing_key)
        integrity["signature"] = {
            "algorithm": "openssl-dgst-sha256",
            "key_id": key_id,
            "value": base64.b64encode(signature).decode("ascii"),
        }
    payload["integrity"] = integrity
    return payload


def attach_external_signature(
    document: Mapping[str, Any],
    *,
    signature: bytes,
    key_id: str,
    trusted_key: Path,
) -> dict[str, Any]:
    verify_document(document)
    if public_key_id(trusted_key) != key_id:
        raise IntegrityError("external signature key id does not match trusted public key")
    encoded = canonical_bytes(payload_without_integrity(document))
    _verify_signature(encoded, signature, trusted_key)
    payload = payload_without_integrity(document)
    sealed = seal_document(payload)
    sealed["integrity"]["signature"] = {
        "algorithm": "openssl-dgst-sha256",
        "key_id": key_id,
        "value": base64.b64encode(signature).decode("ascii"),
    }
    return sealed


def verify_document(
    document: Mapping[str, Any],
    *,
    trusted_keys: Mapping[str, Path] | None = None,
    require_signature: bool = False,
) -> str:
    integrity = document.get("integrity")
    if not isinstance(integrity, dict):
        raise IntegrityError("evidence has no integrity envelope")
    expected_integrity_fields = {"algorithm", "canonical_sha256"}
    if "signature" in integrity:
        expected_integrity_fields.add("signature")
    if set(integrity) != expected_integrity_fields:
        raise IntegrityError("evidence integrity envelope does not match schema version 1")
    if integrity.get("algorithm") != "sha256":
        raise IntegrityError("evidence uses an unsupported checksum algorithm")
    encoded = canonical_bytes(payload_without_integrity(document))
    expected = sha256_bytes(encoded)
    if not _constant_time_hex_equal(integrity.get("canonical_sha256"), expected):
        raise IntegrityError("evidence checksum does not match its canonical payload")

    signature = integrity.get("signature")
    if signature is None:
        if require_signature:
            raise IntegrityError("evidence is not signed")
        return expected
    if not isinstance(signature, dict):
        raise IntegrityError("evidence signature envelope is malformed")
    if set(signature) != {"algorithm", "key_id", "value"}:
        raise IntegrityError("evidence signature envelope does not match schema version 1")
    if signature.get("algorithm") != "openssl-dgst-sha256":
        raise IntegrityError("evidence uses an unsupported signature algorithm")
    key_id = signature.get("key_id")
    if not isinstance(key_id, str) or not key_id:
        raise IntegrityError("evidence signature has no key id")
    if not trusted_keys or key_id not in trusted_keys:
        raise IntegrityError(f"evidence signer {key_id} is not trusted")
    try:
        raw_signature = base64.b64decode(signature.get("value", ""), validate=True)
    except (ValueError, TypeError) as error:
        raise IntegrityError("evidence signature is not valid base64") from error
    _verify_signature(encoded, raw_signature, trusted_keys[key_id])
    return expected


def verify_keyless_evidence(
    report_path: Path,
    document: Mapping[str, Any],
    *,
    signer_workflow: str,
    sigstore_bundle: Path | None = None,
    github_attestation_bundle: Path | None = None,
) -> str:
    digest = verify_document(document)
    integrity = document.get("integrity")
    if isinstance(integrity, dict) and "signature" in integrity:
        raise IntegrityError(
            "keyless evidence must keep its canonical report unsigned"
        )
    provenance = document.get("payload", {}).get("provenance", {})
    commit = provenance.get("commit") if isinstance(provenance, dict) else None
    if (
        not isinstance(commit, str)
        or len(commit) != 40
        or any(character not in "0123456789abcdef" for character in commit)
    ):
        raise IntegrityError("keyless evidence has no full source commit")
    if (
        not isinstance(signer_workflow, str)
        or not signer_workflow.startswith(".github/workflows/")
        or not signer_workflow.endswith(".yml")
        or ".." in signer_workflow
    ):
        raise IntegrityError("keyless evidence signer workflow is invalid")
    sigstore_path = sigstore_bundle or report_path.with_suffix(
        report_path.suffix + ".sigstore.json"
    )
    github_path = github_attestation_bundle or report_path.with_suffix(
        report_path.suffix + ".github-attestation.jsonl"
    )
    for path, name in (
        (report_path, "report"),
        (sigstore_path, "Sigstore bundle"),
        (github_path, "GitHub attestation bundle"),
    ):
        if not path.is_file() or path.is_symlink():
            raise IntegrityError(f"keyless evidence {name} is missing or unsafe")
    identity = (
        f"https://github.com/{GITHUB_REPOSITORY}/{signer_workflow}"
        "@refs/heads/master"
    )
    _run_verifier(
        [
            str(COSIGN_CLIENT),
            "verify-blob",
            "--bundle",
            str(sigstore_path),
            "--certificate-identity",
            identity,
            "--certificate-oidc-issuer",
            GITHUB_OIDC_ISSUER,
            "--certificate-github-workflow-sha",
            commit,
            "--certificate-github-workflow-ref",
            "refs/heads/master",
            "--certificate-github-workflow-repository",
            GITHUB_REPOSITORY,
            str(report_path),
        ],
        "verify Sigstore keyless evidence",
    )
    _run_verifier(
        [
            str(GITHUB_CLIENT),
            "attestation",
            "verify",
            str(report_path),
            "--bundle",
            str(github_path),
            "--repo",
            GITHUB_REPOSITORY,
            "--signer-workflow",
            signer_workflow,
        ],
        "verify GitHub artifact attestation",
    )
    return digest


def public_key_id(path: Path) -> str:
    completed = _run_openssl(
        ["pkey", "-pubin", "-in", str(path), "-outform", "DER"],
        "read public signing key",
    )
    return sha256_bytes(completed.stdout)


def private_key_id(path: Path) -> str:
    _validate_private_key(path)
    completed = _run_openssl(
        ["pkey", "-in", str(path), "-pubout", "-outform", "DER"],
        "derive signing key id",
    )
    return sha256_bytes(completed.stdout)


def load_json(path: Path) -> dict[str, Any]:
    try:
        with path.open(encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        raise IntegrityError(f"cannot read JSON evidence {path}: {error}") from error
    if not isinstance(value, dict):
        raise IntegrityError(f"JSON evidence {path} must be an object")
    return value


def write_json(path: Path, value: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(
        prefix=f"{path.name}.",
        dir=path.parent,
        text=True,
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, indent=2, sort_keys=True, allow_nan=False)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def _constant_time_hex_equal(actual: Any, expected: str) -> bool:
    if not isinstance(actual, str) or len(actual) != len(expected):
        return False
    try:
        int(actual, 16)
    except ValueError:
        return False
    return hmac.compare_digest(actual, expected)


def _sign(payload: bytes, private_key: Path) -> tuple[bytes, str]:
    _validate_private_key(private_key)
    completed = _run_openssl(
        ["dgst", "-sha256", "-sign", str(private_key)],
        "sign evidence",
        input_bytes=payload,
    )
    return completed.stdout, private_key_id(private_key)


def _validate_private_key(path: Path) -> None:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise IntegrityError(f"cannot inspect private signing key: {error}") from error
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise IntegrityError("private signing key must be a regular non-symlink file")
    if metadata.st_mode & 0o077:
        raise IntegrityError("private signing key permissions must be 0600 or stricter")


def _verify_signature(payload: bytes, signature: bytes, public_key: Path) -> None:
    with tempfile.NamedTemporaryFile() as signature_file:
        signature_file.write(signature)
        signature_file.flush()
        completed = subprocess.run(
            [
                "openssl",
                "dgst",
                "-sha256",
                "-verify",
                str(public_key),
                "-signature",
                signature_file.name,
            ],
            input=payload,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    if completed.returncode != 0:
        raise IntegrityError("evidence signature verification failed")


def _run_openssl(
    arguments: list[str],
    operation: str,
    *,
    input_bytes: bytes | None = None,
) -> subprocess.CompletedProcess[bytes]:
    try:
        completed = subprocess.run(
            ["openssl", *arguments],
            input=input_bytes,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    except OSError as error:
        raise IntegrityError(f"cannot {operation}: {error}") from error
    if completed.returncode != 0:
        detail = completed.stderr.decode("utf-8", errors="replace").strip()
        raise IntegrityError(f"cannot {operation}: {detail or 'openssl failed'}")
    return completed


def _run_verifier(arguments: list[str], operation: str) -> None:
    try:
        completed = subprocess.run(
            arguments,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise IntegrityError(f"cannot {operation}: {error}") from error
    if completed.returncode != 0:
        detail = completed.stderr.decode("utf-8", errors="replace").strip()
        raise IntegrityError(f"cannot {operation}: {detail or 'verification failed'}")

