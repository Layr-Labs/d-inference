from __future__ import annotations

import urllib.parse
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Mapping

from .integrity import canonical_bytes, sha256_bytes

DESCRIPTOR_FIELDS = frozenset(
    {
        "schema_version",
        "canonical_environment",
        "https_origin",
        "listener_identity",
        "database_instance_id",
        "database_system_identifier",
        "read_only_dsn_sha256",
        "writer_endpoint_sha256",
        "coordinator_ownership_id",
        "coordinator_app_id",
        "datadog_site",
        "datadog_organization_id",
        "canary_https_origin",
        "canary_listener_identity",
        "canary_database_instance_id",
        "canary_database_system_identifier",
        "canary_read_only_dsn_sha256",
        "canary_writer_endpoint_sha256",
        "canary_coordinator_ownership_id",
        "canary_coordinator_app_id",
        "canary_datadog_site",
        "canary_datadog_organization_id",
        "candidate_image",
        "fallback_image",
    }
)

PRODUCTION_ORIGIN = "https://api.darkbloom.dev"
CANARY_ORIGIN = "https://canary.darkbloom.dev"
DATADOG_SITES = frozenset({"us1", "us3", "us5", "eu", "ap1", "ap2"})


class EnvironmentBindingError(ValueError):
    """A signed environment target is malformed or does not match observation."""


def validate_descriptor(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != DESCRIPTOR_FIELDS:
        raise EnvironmentBindingError("environment descriptor fields do not match schema 2")
    if value.get("schema_version") != 2:
        raise EnvironmentBindingError("environment descriptor schema_version must be 2")
    if value.get("canonical_environment") != "production":
        raise EnvironmentBindingError("canonical environment must be production")
    if value.get("https_origin") != PRODUCTION_ORIGIN:
        raise EnvironmentBindingError(f"production HTTPS origin must be {PRODUCTION_ORIGIN}")
    if value.get("canary_https_origin") != CANARY_ORIGIN:
        raise EnvironmentBindingError(f"canary HTTPS origin must be {CANARY_ORIGIN}")
    for name in (
        "listener_identity",
        "database_instance_id",
        "coordinator_ownership_id",
        "coordinator_app_id",
        "datadog_organization_id",
        "canary_listener_identity",
        "canary_database_instance_id",
        "canary_coordinator_ownership_id",
        "canary_coordinator_app_id",
        "canary_datadog_organization_id",
    ):
        _nonempty_token(value.get(name), name)
    if value["listener_identity"] == value["canary_listener_identity"]:
        raise EnvironmentBindingError("production and canary listener identities must differ")
    if value["database_instance_id"] == value["canary_database_instance_id"]:
        raise EnvironmentBindingError("production and canary database identities must differ")
    for name in ("database_system_identifier", "canary_database_system_identifier"):
        _system_identifier(value.get(name), name)
    if (
        value["database_system_identifier"]
        == value["canary_database_system_identifier"]
    ):
        raise EnvironmentBindingError(
            "production and canary PostgreSQL system identifiers must differ"
        )
    for name in (
        "read_only_dsn_sha256",
        "writer_endpoint_sha256",
        "canary_read_only_dsn_sha256",
        "canary_writer_endpoint_sha256",
    ):
        _sha256(value.get(name), name)
    if value["writer_endpoint_sha256"] == value["canary_writer_endpoint_sha256"]:
        raise EnvironmentBindingError(
            "production and canary writer endpoint fingerprints must differ"
        )
    for name in ("datadog_site", "canary_datadog_site"):
        if value.get(name) not in DATADOG_SITES:
            raise EnvironmentBindingError(
                f"{name} must be us1, us3, us5, eu, ap1, or ap2"
            )
    candidate = value.get("candidate_image")
    fallback = value.get("fallback_image")
    if not _repository_digest(candidate) or not _repository_digest(fallback):
        raise EnvironmentBindingError(
            "environment images must be immutable repository digest references"
        )
    if candidate == fallback:
        raise EnvironmentBindingError("candidate and fallback image digests must differ")
    return dict(value)


def environment_id(descriptor: Mapping[str, Any]) -> str:
    validated = validate_descriptor(dict(descriptor))
    return sha256_bytes(canonical_bytes(validated))


def payload_binding(descriptor: Mapping[str, Any]) -> dict[str, Any]:
    validated = validate_descriptor(dict(descriptor))
    return {
        "environment_id": environment_id(validated),
        "descriptor": validated,
    }


def validate_payload_binding(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != {"environment_id", "descriptor"}:
        raise EnvironmentBindingError("evidence has no exact environment binding")
    descriptor = validate_descriptor(value.get("descriptor"))
    expected = environment_id(descriptor)
    if value.get("environment_id") != expected:
        raise EnvironmentBindingError("environment_id does not match canonical descriptor")
    return {"environment_id": expected, "descriptor": descriptor}


def validate_manifest(
    manifest: Mapping[str, Any],
    *,
    trusted_keys: Mapping[str, Path],
    now: datetime | None = None,
) -> dict[str, Any]:
    from .reports import validate_report

    validate_report(
        manifest,
        expected_type="environment_manifest",
        trusted_keys=trusted_keys,
        require_signature=True,
        now=now,
        maximum_age=timedelta(days=1),
    )
    if manifest.get("verdict") != "pass" or manifest.get("environment") != "production":
        raise EnvironmentBindingError("environment manifest is not an approved production target")
    payload = manifest.get("payload")
    if not isinstance(payload, dict):
        raise EnvironmentBindingError("environment manifest payload is malformed")
    binding = validate_payload_binding(payload.get("environment_binding"))
    if set(payload) != {"environment_binding", "provenance"}:
        raise EnvironmentBindingError("environment manifest payload contains unexpected fields")
    return binding


def active_environment(
    binding: Mapping[str, Any],
    environment: str,
) -> dict[str, str]:
    validated = validate_payload_binding(dict(binding))
    descriptor = validated["descriptor"]
    if environment == "production":
        prefix = ""
    elif environment == "canary":
        prefix = "canary_"
    else:
        raise EnvironmentBindingError(
            "only canary or production evidence has an active network environment"
        )
    return {
        "environment_id": validated["environment_id"],
        "https_origin": descriptor[f"{prefix}https_origin"],
        "listener_identity": descriptor[f"{prefix}listener_identity"],
        "database_instance_id": descriptor[f"{prefix}database_instance_id"],
        "database_system_identifier": descriptor[
            f"{prefix}database_system_identifier"
        ],
        "read_only_dsn_sha256": descriptor[f"{prefix}read_only_dsn_sha256"],
        "writer_endpoint_sha256": descriptor[f"{prefix}writer_endpoint_sha256"],
        "coordinator_ownership_id": descriptor[f"{prefix}coordinator_ownership_id"],
        "coordinator_app_id": descriptor[f"{prefix}coordinator_app_id"],
        "datadog_site": descriptor[f"{prefix}datadog_site"],
        "datadog_organization_id": descriptor[
            f"{prefix}datadog_organization_id"
        ],
        "candidate_image": descriptor["candidate_image"],
        "fallback_image": descriptor["fallback_image"],
    }


def read_only_dsn_fingerprint(dsn: str) -> str:
    parsed = urllib.parse.urlsplit(dsn)
    if (
        parsed.scheme not in {"postgres", "postgresql"}
        or not parsed.hostname
        or not parsed.username
        or not parsed.path.strip("/")
        or parsed.fragment
    ):
        raise EnvironmentBindingError("cannot fingerprint malformed read-only DSN")
    parameters = urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)
    safe_parameters = sorted(
        (name, value)
        for name, value in parameters
        if name not in {"password", "passfile"}
    )
    canonical = {
        "scheme": "postgresql",
        "host": parsed.hostname.lower().rstrip("."),
        "port": parsed.port or 5432,
        "user": urllib.parse.unquote(parsed.username),
        "database": parsed.path.strip("/"),
        "parameters": safe_parameters,
    }
    return sha256_bytes(canonical_bytes(canonical))


def writer_endpoint_fingerprint(endpoint: str) -> str:
    if not isinstance(endpoint, str) or not endpoint or endpoint != endpoint.strip():
        raise EnvironmentBindingError("writer endpoint must be a non-empty host[:port]")
    parsed = urllib.parse.urlsplit(f"//{endpoint}")
    if (
        not parsed.hostname
        or parsed.username
        or parsed.password
        or parsed.path
        or parsed.query
        or parsed.fragment
    ):
        raise EnvironmentBindingError(
            "writer endpoint must contain only a hostname and optional port"
        )
    try:
        port = parsed.port or 5432
    except ValueError as error:
        raise EnvironmentBindingError("writer endpoint port is invalid") from error
    canonical = {"host": parsed.hostname.lower().rstrip("."), "port": port}
    return sha256_bytes(canonical_bytes(canonical))


def _repository_digest(value: Any) -> bool:
    if not isinstance(value, str) or value.count("@sha256:") != 1:
        return False
    repository, digest = value.split("@sha256:", 1)
    return (
        bool(repository)
        and all(character.isalnum() or character in "._/:-" for character in repository)
        and len(digest) == 64
        and all(character in "0123456789abcdef" for character in digest)
    )


def _sha256(value: Any, name: str) -> None:
    if (
        not isinstance(value, str)
        or len(value) != 64
        or any(character not in "0123456789abcdef" for character in value)
    ):
        raise EnvironmentBindingError(f"{name} must be a lowercase SHA-256")


def _nonempty_token(value: Any, name: str) -> None:
    if (
        not isinstance(value, str)
        or not value
        or value != value.strip()
        or any(character.isspace() for character in value)
    ):
        raise EnvironmentBindingError(f"{name} must be a non-empty token")


def _system_identifier(value: Any, name: str) -> None:
    if (
        not isinstance(value, str)
        or not value.isdigit()
        or value.startswith("0")
        or len(value) > 20
    ):
        raise EnvironmentBindingError(
            f"{name} must be a positive PostgreSQL system_identifier string"
        )
