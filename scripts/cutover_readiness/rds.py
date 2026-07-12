from __future__ import annotations

import json
import os
import subprocess
import urllib.parse
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .clients import ReadOnlyClientError, load_secret
from .environment import (
    active_environment,
    read_only_dsn_fingerprint,
    writer_endpoint_fingerprint,
)
from .integrity import sha256_file

ROOT = Path(__file__).resolve().parents[2]
READ_ONLY_SQL_PATH = ROOT / "deploy/cutover/rds-readonly.sql"
PSQL_CLIENT = Path("/usr/bin/psql")
READ_ONLY_ROLE = "darkbloom_cutover_readonly"

FORBIDDEN_RUNTIME_CREDENTIALS = (
    "DATABASE_URL",
    "EIGENINFERENCE_DATABASE_URL",
    "PGSERVICE",
)

READ_ONLY_SQL = READ_ONLY_SQL_PATH.read_text(encoding="utf-8")


def validate_read_only_dsn(dsn: str, *, fixture: bool = False) -> dict[str, Any]:
    parsed = urllib.parse.urlsplit(dsn)
    if parsed.scheme not in {"postgres", "postgresql"}:
        raise ReadOnlyClientError("RDS DSN must use postgres or postgresql")
    if not parsed.hostname or not parsed.username or not parsed.path.strip("/"):
        raise ReadOnlyClientError("RDS DSN must include host, user, and database")
    if parsed.fragment:
        raise ReadOnlyClientError("RDS DSN cannot include a fragment")
    username = urllib.parse.unquote(parsed.username)
    if username != READ_ONLY_ROLE:
        raise ReadOnlyClientError(f"RDS role must be exactly {READ_ONLY_ROLE}")
    parameters = urllib.parse.parse_qs(parsed.query, strict_parsing=True)
    if fixture:
        if not _loopback(parsed.hostname):
            raise ReadOnlyClientError("fixture database must use a loopback host")
    else:
        if parameters.get("sslmode") != ["verify-full"]:
            raise ReadOnlyClientError("RDS DSN must set sslmode=verify-full")
        if parameters.get("target_session_attrs") != ["read-only"]:
            raise ReadOnlyClientError("RDS DSN must set target_session_attrs=read-only")
        options = parameters.get("options")
        if not options or "default_transaction_read_only=on" not in options[0]:
            raise ReadOnlyClientError(
                "RDS DSN must force default_transaction_read_only=on"
            )
    return {
        "host": parsed.hostname,
        "port": parsed.port or 5432,
        "user": username,
        "password": urllib.parse.unquote(parsed.password or ""),
        "database": parsed.path.strip("/"),
        "parameters": parameters,
    }


def reject_runtime_write_credentials(environment: dict[str, str] | None = None) -> None:
    values = environment if environment is not None else os.environ
    present = sorted(name for name in FORBIDDEN_RUNTIME_CREDENTIALS if values.get(name))
    if present:
        raise ReadOnlyClientError(
            "runtime database credential variables are forbidden: " + ", ".join(present)
        )


def collect_rds(
    dsn_file: Path,
    *,
    environment_binding: dict[str, Any] | None = None,
    environment: str | None = None,
    writer_endpoint: str | None = None,
    window_start: datetime | None = None,
    window_end: datetime | None = None,
    fixture: bool = False,
    require_replica: bool = True,
) -> dict[str, Any]:
    reject_runtime_write_credentials()
    if (
        window_start is None
        or window_end is None
        or window_start.tzinfo is None
        or window_end.tzinfo is None
        or window_end <= window_start
    ):
        raise ReadOnlyClientError("RDS collection requires an explicit fixed window")
    window_start_text = (
        window_start.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")
    )
    window_end_text = (
        window_end.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")
    )
    dsn = load_secret(dsn_file, allow_fixture_permissions=fixture)
    connection = validate_read_only_dsn(dsn, fixture=fixture)
    active = None
    if environment_binding is not None:
        selected_environment = (
            "production" if fixture and environment == "development" else environment
        )
        if selected_environment not in {"canary", "production"}:
            raise ReadOnlyClientError("bound RDS collection requires an environment")
        active = active_environment(environment_binding, selected_environment)
        if read_only_dsn_fingerprint(dsn) != active["read_only_dsn_sha256"]:
            raise ReadOnlyClientError(
                "read-only DSN fingerprint does not match signed environment"
            )
        if writer_endpoint is None:
            raise ReadOnlyClientError(
                "bound RDS collection requires the configured writer endpoint"
            )
        if (
            writer_endpoint_fingerprint(writer_endpoint)
            != active["writer_endpoint_sha256"]
        ):
            raise ReadOnlyClientError(
                "writer endpoint fingerprint does not match signed environment"
            )
    child_environment = {
        key: os.environ[key]
        for key in (
            "HOME",
            "LANG",
            "LC_ALL",
            "PATH",
            "SSL_CERT_DIR",
            "SSL_CERT_FILE",
            "TMPDIR",
        )
        if key in os.environ
    }
    child_environment.update(
        {
            "PGHOST": connection["host"],
            "PGPORT": str(connection["port"]),
            "PGUSER": connection["user"],
            "PGDATABASE": connection["database"],
            "PGPASSWORD": connection["password"],
            "PGAPPNAME": "darkbloom-cutover-readonly",
            "PGOPTIONS": "-c default_transaction_read_only=on",
            "PGTARGETSESSIONATTRS": "read-only",
        }
    )
    sslmode = connection["parameters"].get("sslmode")
    if sslmode:
        child_environment["PGSSLMODE"] = sslmode[0]
    try:
        completed = subprocess.run(
            [
                str(PSQL_CLIENT),
                "--no-psqlrc",
                "--quiet",
                "--tuples-only",
                "--no-align",
                "--no-password",
                "--set",
                "ON_ERROR_STOP=1",
                "--set",
                f"window_start={window_start_text}",
                "--set",
                f"window_end={window_end_text}",
            ],
            input=READ_ONLY_SQL.encode(),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=child_environment,
            timeout=30,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ReadOnlyClientError(f"RDS read-only query failed: {error}") from error
    if completed.returncode != 0:
        raise ReadOnlyClientError("RDS read-only query failed; inspect the operator-side log")
    lines = [line for line in completed.stdout.decode().splitlines() if line.strip()]
    if len(lines) != 1:
        raise ReadOnlyClientError("RDS read-only query returned an inconclusive response")
    try:
        result = json.loads(lines[0])
    except json.JSONDecodeError as error:
        raise ReadOnlyClientError("RDS read-only query returned malformed JSON") from error
    if not isinstance(result, dict):
        raise ReadOnlyClientError("RDS read-only query result must be an object")
    if (
        result.get("window_started_at") != window_start_text
        or result.get("window_ended_at") != window_end_text
    ):
        raise ReadOnlyClientError("RDS result does not bind the requested fixed window")
    if result.get("transaction_read_only") is not True:
        raise ReadOnlyClientError("RDS session did not prove transaction_read_only=on")
    if result.get("read_only_role") is not True:
        raise ReadOnlyClientError("RDS session did not use the pinned read-only role")
    if result.get("role_elevated") is not False:
        raise ReadOnlyClientError("RDS role has elevated attributes")
    if result.get("role_has_write_privileges") is not False:
        raise ReadOnlyClientError("RDS role has write privileges")
    for field in (
        "go_audit_coverage_complete",
        "go_audit_trigger_states_valid",
        "go_audit_definition_hashes_valid",
        "go_audit_owner_coverage_complete",
    ):
        if result.get(field) is not True:
            raise ReadOnlyClientError(
                f"RDS retirement audit integrity check failed: {field}"
            )
    if active is not None and result.get("database_instance_id") != active[
        "database_instance_id"
    ]:
        raise ReadOnlyClientError(
            "database instance does not match signed environment"
        )
    if active is not None and result.get("database_system_identifier") != active[
        "database_system_identifier"
    ]:
        raise ReadOnlyClientError(
            "PostgreSQL system_identifier does not match signed environment"
        )
    if not fixture and require_replica and result.get("is_read_replica") is not True:
        raise ReadOnlyClientError("production RDS evidence did not come from a read replica")
    result["source"] = (
        "rds_read_replica"
        if result.get("is_read_replica")
        else "local_fixture"
        if fixture
        else "read_only_primary"
    )
    result["query_definition_sha256"] = sha256_file(READ_ONLY_SQL_PATH)
    if active is not None:
        result["environment_id"] = active["environment_id"]
        result["read_only_dsn_sha256"] = active["read_only_dsn_sha256"]
        result["writer_endpoint_sha256"] = active["writer_endpoint_sha256"]
    return result


def _loopback(hostname: str) -> bool:
    import ipaddress

    if hostname.lower() == "localhost":
        return True
    try:
        return ipaddress.ip_address(hostname).is_loopback
    except ValueError:
        return False

