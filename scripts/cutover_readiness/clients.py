from __future__ import annotations

import json
import stat
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path
from typing import Any, Mapping, Sequence

from .environment import DATADOG_SITES, active_environment

DATADOG_API_BASES = {
    "us1": "https://api.datadoghq.com",
    "us3": "https://api.us3.datadoghq.com",
    "us5": "https://api.us5.datadoghq.com",
    "eu": "https://api.datadoghq.eu",
    "ap1": "https://api.ap1.datadoghq.com",
    "ap2": "https://api.ap2.datadoghq.com",
}
COORDINATOR_GET_PATHS = (
    ("health", "/health", "none"),
    ("ready", "/readyz", "none"),
    ("quiescence", "/v1/admin/quiescence", "ops_read"),
    ("attestation", "/v1/providers/attestation", "public"),
    ("utilization", "/v1/admin/utilization", "ops_read"),
    ("metrics", "/v1/admin/metrics", "ops_read"),
)


class ReadOnlyClientError(RuntimeError):
    """A read-only source could not produce conclusive evidence."""


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file_pointer, code, message, headers, new_url):
        raise ReadOnlyClientError("redirects are forbidden for credential-bearing evidence reads")


def load_secret(path: Path, *, allow_fixture_permissions: bool = False) -> str:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise ReadOnlyClientError(f"cannot inspect credential file: {error}") from error
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise ReadOnlyClientError("credential path must be a regular non-symlink file")
    if not allow_fixture_permissions and metadata.st_mode & 0o077:
        raise ReadOnlyClientError("credential file permissions must be 0600 or stricter")
    try:
        value = path.read_text(encoding="utf-8").strip()
    except OSError as error:
        raise ReadOnlyClientError(f"cannot read credential file: {error}") from error
    if not value or "\n" in value or "\r" in value:
        raise ReadOnlyClientError("credential file must contain one non-empty line")
    return value


def validate_read_url(
    url: str,
    *,
    fixture: bool,
    production_acknowledgement: str | None = None,
) -> urllib.parse.SplitResult:
    parsed = urllib.parse.urlsplit(url)
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ReadOnlyClientError("read endpoint cannot contain credentials, query, or fragment")
    if parsed.path not in {"", "/"}:
        raise ReadOnlyClientError("read endpoint must be an origin without a path")
    if not parsed.hostname:
        raise ReadOnlyClientError("read endpoint must include a hostname")
    loopback = _is_loopback(parsed.hostname)
    if fixture:
        if not loopback or parsed.scheme != "http":
            raise ReadOnlyClientError("fixture endpoints must use HTTP loopback")
    elif parsed.scheme != "https":
        raise ReadOnlyClientError("non-fixture endpoints must use HTTPS")
    if _looks_production(parsed.hostname):
        expected = "READ-ONLY PRODUCTION EVIDENCE"
        if production_acknowledgement != expected:
            raise ReadOnlyClientError(
                f"production reads require the exact acknowledgement {expected!r}"
            )
    return parsed


def collect_coordinator(
    base_url: str,
    *,
    ops_read_key: str,
    public_key: str,
    minimum_provider_version: str,
    environment_binding: Mapping[str, Any] | None = None,
    environment: str | None = None,
    fixture: bool = False,
    production_acknowledgement: str | None = None,
    timeout_seconds: float = 10,
) -> dict[str, Any]:
    validate_read_url(
        base_url,
        fixture=fixture,
        production_acknowledgement=production_acknowledgement,
    )
    if not ops_read_key or not public_key:
        raise ReadOnlyClientError("ops-read and public credentials are required")
    active = None
    if environment_binding is not None:
        selected_environment = (
            "production" if fixture and environment == "development" else environment
        )
        if selected_environment not in {"canary", "production"}:
            raise ReadOnlyClientError("bound coordinator collection requires an environment")
        active = active_environment(environment_binding, selected_environment)
        if not fixture and base_url.rstrip("/") != active["https_origin"]:
            raise ReadOnlyClientError("coordinator origin does not match signed environment")
    captured: dict[str, Any] = {}
    for name, path, authentication in COORDINATOR_GET_PATHS:
        headers = {"Accept": "application/json"}
        if authentication == "ops_read":
            headers["Authorization"] = f"Bearer {ops_read_key}"
        elif authentication == "public":
            headers["Authorization"] = f"Bearer {public_key}"
        body, response_date = _get_json(
            urllib.parse.urljoin(base_url.rstrip("/") + "/", path.lstrip("/")),
            headers,
            timeout_seconds,
        )
        captured[name] = body
        captured[f"{name}_response_date"] = response_date
    health = _health_summary(captured["health"])
    result = {
        "health": health,
        "ready": _ready_summary(captured["ready"]),
        "quiescence": _quiescence_summary(captured["quiescence"]),
        "provider_coverage": _provider_coverage(
            captured["attestation"],
            captured["utilization"],
            minimum_provider_version,
        ),
        "durable_counts": _durable_counts(captured["metrics"]),
        "response_dates": {
            name: captured[f"{name}_response_date"]
            for name, _, _ in COORDINATOR_GET_PATHS
        },
    }
    if active is not None:
        observed = {
            "environment_id": health.get("environment_id"),
            "listener_identity": health.get("listener_identity"),
            "coordinator_ownership_id": health.get("coordinator_ownership_id"),
            "coordinator_app_id": health.get("coordinator_app_id"),
        }
        expected = {
            name: active[name]
            for name in (
                "listener_identity",
                "coordinator_ownership_id",
                "coordinator_app_id",
            )
        }
        expected["environment_id"] = active["environment_id"]
        if observed != expected:
            raise ReadOnlyClientError(
                "coordinator identity does not match signed environment"
            )
        result["environment_id"] = active["environment_id"]
        result["observed_environment"] = observed
    return result


def collect_datadog(
    site: str,
    queries: Sequence[Mapping[str, Any]],
    *,
    api_key: str,
    application_key: str,
    environment_binding: Mapping[str, Any] | None = None,
    environment: str | None = None,
    window_start: datetime | None = None,
    window_end: datetime | None = None,
    api_base_override: str | None = None,
    fixture: bool = False,
    now: datetime | None = None,
    timeout_seconds: float = 10,
) -> dict[str, Any]:
    if site not in DATADOG_SITES or site not in DATADOG_API_BASES:
        raise ReadOnlyClientError(
            "Datadog site must be explicit: us1, us3, us5, eu, ap1, or ap2"
        )
    if not api_key or not application_key:
        raise ReadOnlyClientError("Datadog read-only API and application keys are required")
    api_base = api_base_override or DATADOG_API_BASES[site]
    validate_read_url(api_base, fixture=fixture)
    if api_base_override and not fixture:
        raise ReadOnlyClientError("Datadog API base overrides are fixture-only")
    observed_now = now or datetime.now(timezone.utc)
    binding_id = None
    expected_tag = None
    expected_organization_id = None
    if environment_binding is not None:
        selected_environment = (
            "production" if fixture and environment == "development" else environment
        )
        if selected_environment not in {"canary", "production"}:
            raise ReadOnlyClientError("bound Datadog collection requires an environment")
        active = active_environment(environment_binding, selected_environment)
        binding_id = active["environment_id"]
        if site != active["datadog_site"]:
            raise ReadOnlyClientError("Datadog site does not match signed environment")
        expected_organization_id = active["datadog_organization_id"]
        expected_tag = f"env:{selected_environment}"
        if window_start is None or window_end is None:
            raise ReadOnlyClientError(
                "bound Datadog collection requires an explicit fixed window"
            )
    if (window_start is None) != (window_end is None):
        raise ReadOnlyClientError("Datadog window start and end must be supplied together")
    if window_start is not None and (
        window_start.tzinfo is None
        or window_end is None
        or window_end.tzinfo is None
        or window_end <= window_start
        or window_end > observed_now + timedelta(minutes=5)
    ):
        raise ReadOnlyClientError("Datadog fixed window is invalid")
    authentication_headers = {
        "Accept": "application/json",
        "DD-API-KEY": api_key,
        "DD-APPLICATION-KEY": application_key,
    }
    organization, organization_response_date = _get_json(
        f"{api_base.rstrip('/')}/api/v2/current_user",
        authentication_headers,
        timeout_seconds,
    )
    organization_id = _datadog_organization_id(organization)
    if (
        expected_organization_id is not None
        and organization_id != expected_organization_id
    ):
        raise ReadOnlyClientError(
            "authenticated Datadog organization does not match signed environment"
        )
    results: dict[str, Any] = {}
    response_dates: list[str] = []
    for spec in queries:
        name = spec.get("name")
        query = spec.get("query")
        window_seconds = spec.get("window_seconds")
        bucket_seconds = spec.get("bucket_seconds")
        rollup_aggregator = spec.get("rollup_aggregator")
        rollup_occurrences = spec.get("rollup_occurrences", 1)
        reducer = spec.get("reducer")
        if (
            not isinstance(name, str)
            or not name
            or not isinstance(query, str)
            or not query
            or not isinstance(window_seconds, int)
            or window_seconds <= 0
            or not isinstance(bucket_seconds, int)
            or bucket_seconds <= 0
            or rollup_aggregator not in {"min", "max", "sum"}
            or not isinstance(rollup_occurrences, int)
            or isinstance(rollup_occurrences, bool)
            or rollup_occurrences <= 0
            or reducer not in {"min", "max", "sum", "last"}
        ):
            raise ReadOnlyClientError("Datadog query specification is malformed")
        rollup_marker = f".rollup({rollup_aggregator},{bucket_seconds})"
        if (
            query.count(rollup_marker) != rollup_occurrences
            or query.count(".rollup(") != rollup_occurrences
        ):
            raise ReadOnlyClientError(
                f"Datadog query {name} does not use its exact pinned rollup"
            )
        if expected_tag is not None and expected_tag not in query:
            raise ReadOnlyClientError(
                f"Datadog query {name} is not pinned to {expected_tag}"
            )
        query_start = (
            window_start
            if window_start is not None
            else observed_now - timedelta(seconds=window_seconds)
        )
        query_end = window_end if window_end is not None else observed_now
        interval_seconds = int((query_end - query_start).total_seconds())
        if (
            window_start is not None
            and (
                interval_seconds != window_seconds
                or interval_seconds % bucket_seconds != 0
                or int(query_start.timestamp()) % bucket_seconds != 0
                or int(query_end.timestamp()) % bucket_seconds != 0
            )
        ):
            raise ReadOnlyClientError(
                f"Datadog query {name} window is not aligned to pinned buckets"
            )
        parameters = urllib.parse.urlencode(
            {
                "from": int(query_start.timestamp()),
                "to": int(query_end.timestamp()),
                "query": query,
            }
        )
        body, response_date = _get_json(
            f"{api_base.rstrip('/')}/api/v1/query?{parameters}",
            authentication_headers,
            timeout_seconds,
        )
        points = _datadog_points(body)
        if not points:
            raise ReadOnlyClientError(f"Datadog query {name} returned no numeric samples")
        if window_start is not None:
            expected_buckets = list(
                range(
                    int(query_start.timestamp()) * 1000,
                    int(query_end.timestamp()) * 1000,
                    bucket_seconds * 1000,
                )
            )
            observed_buckets = [timestamp for timestamp, _ in points]
            if observed_buckets != expected_buckets:
                raise ReadOnlyClientError(
                    f"Datadog query {name} did not return the exact fixed buckets"
                )
        values = [value for _, value in points]
        reduced = {
            "min": min,
            "max": max,
            "sum": sum,
            "last": lambda items: items[-1],
        }[reducer](values)
        results[name] = {
            "reducer": reducer,
            "value": reduced,
            "samples": len(values),
            "window_seconds": window_seconds,
            "bucket_seconds": bucket_seconds,
            "rollup_aggregator": rollup_aggregator,
            "bucket_started_at": [
                datetime.fromtimestamp(timestamp / 1000, timezone.utc)
                .isoformat()
                .replace("+00:00", "Z")
                for timestamp, _ in points
            ],
            "window_started_at": query_start.astimezone(timezone.utc)
            .isoformat()
            .replace("+00:00", "Z"),
            "window_ended_at": query_end.astimezone(timezone.utc)
            .isoformat()
            .replace("+00:00", "Z"),
        }
        response_dates.append(response_date)
    result = {
        "site": site,
        "organization_id": organization_id,
        "organization_response_date": organization_response_date,
        "queries": results,
        "response_dates": response_dates,
    }
    if binding_id is not None:
        result["environment_id"] = binding_id
        result["query_environment"] = expected_tag.removeprefix("env:")
    return result


def _get_json(
    url: str,
    headers: Mapping[str, str],
    timeout_seconds: float,
) -> tuple[dict[str, Any], str]:
    if timeout_seconds <= 0 or timeout_seconds > 30:
        raise ReadOnlyClientError("HTTP timeout must be between 0 and 30 seconds")
    request = urllib.request.Request(url, headers=dict(headers), method="GET")
    opener = urllib.request.build_opener(_NoRedirect)
    try:
        with opener.open(request, timeout=timeout_seconds) as response:
            if response.status != 200:
                raise ReadOnlyClientError(f"GET {request.full_url} returned {response.status}")
            content_type = response.headers.get_content_type()
            if content_type != "application/json":
                raise ReadOnlyClientError(
                    f"GET {request.full_url} returned non-JSON content type {content_type}"
                )
            raw = response.read(2 * 1024 * 1024 + 1)
            if len(raw) > 2 * 1024 * 1024:
                raise ReadOnlyClientError(f"GET {request.full_url} exceeded the 2 MiB limit")
            response_date = response.headers.get("Date")
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        raise ReadOnlyClientError(f"GET {request.full_url} failed: {error}") from error
    try:
        body = json.loads(raw)
    except json.JSONDecodeError as error:
        raise ReadOnlyClientError(f"GET {request.full_url} returned invalid JSON") from error
    if not isinstance(body, dict):
        raise ReadOnlyClientError(f"GET {request.full_url} JSON must be an object")
    if not response_date:
        raise ReadOnlyClientError(f"GET {request.full_url} omitted the HTTP Date header")
    try:
        server_time = parsedate_to_datetime(response_date).astimezone(timezone.utc)
    except (TypeError, ValueError) as error:
        raise ReadOnlyClientError(f"GET {request.full_url} returned an invalid Date header") from error
    age = datetime.now(timezone.utc) - server_time
    if age > timedelta(minutes=5) or age < -timedelta(minutes=5):
        raise ReadOnlyClientError(f"GET {request.full_url} returned a stale Date header")
    return body, response_date


def _health_summary(value: Mapping[str, Any]) -> dict[str, Any]:
    build = value.get("build") if isinstance(value.get("build"), dict) else {}
    schema = value.get("schema") if isinstance(value.get("schema"), dict) else {}
    return {
        "healthy": value.get("status") in {"ok", "healthy"} or value.get("healthy") is True,
        "ownership_healthy": value.get("ownership_healthy") is True,
        "binary": value.get("binary") or build.get("binary"),
        "commit": value.get("build_commit") or build.get("commit"),
        "image_digest": value.get("image_digest") or build.get("image_digest"),
        "public_schema_version": schema.get("public_version"),
        "rust_schema_version": schema.get("rust_version"),
        "migration_checksum_valid": schema.get("migration_checksum_valid"),
        "listener_identity": value.get("listener_identity"),
        "coordinator_ownership_id": value.get("coordinator_ownership_id"),
        "coordinator_app_id": value.get("coordinator_app_id"),
        "environment_id": value.get("environment_id"),
    }


def _ready_summary(value: Mapping[str, Any]) -> dict[str, Any]:
    return {
        "ready": value.get("ready") is True or value.get("status") == "ready",
        "ownership_healthy": value.get("ownership_healthy"),
    }


def _quiescence_summary(value: Mapping[str, Any]) -> dict[str, Any]:
    supervisor = value.get("supervisor") if isinstance(value.get("supervisor"), dict) else {}
    return {
        "observed": True,
        "quiescent": value.get("quiescent") is True,
        "draining": value.get("draining") is True,
        "ownership_healthy": value.get("ownership_healthy") is True,
        "supervisor_ready": supervisor.get("ready") is True,
        "supervisor_failed": supervisor.get("failed") is True,
    }


def _provider_coverage(
    attestation: Mapping[str, Any],
    utilization: Mapping[str, Any],
    minimum_provider_version: str,
) -> dict[str, Any]:
    minimum = _parse_semantic_version(minimum_provider_version)
    if minimum is None:
        raise ReadOnlyClientError("minimum provider version must be a semantic version")
    raw = attestation.get("providers")
    providers = raw if isinstance(raw, list) else []
    total = len(providers)
    hardware = 0
    at_or_above_floor = 0
    versions_known = 0
    for provider in providers:
        if not isinstance(provider, dict):
            continue
        if provider.get("trust_level") == "hardware":
            hardware += 1
        version = provider.get("version")
        parsed_version = _parse_semantic_version(version)
        if parsed_version is not None:
            versions_known += 1
            if parsed_version >= minimum:
                at_or_above_floor += 1
    protocol = utilization.get("protocol")
    protocol = protocol if isinstance(protocol, dict) else {}
    return {
        "total": total,
        "hardware": hardware,
        "versions_known": versions_known,
        "at_or_above_floor": at_or_above_floor,
        "protocol_v1": _nonnegative_int(protocol.get("v1")),
        "protocol_v2": _nonnegative_int(protocol.get("v2")),
        "protocol_v2_inference_eligible": _nonnegative_int(
            protocol.get("v2_inference_eligible")
        ),
    }


def _durable_counts(metrics: Mapping[str, Any]) -> dict[str, int | bool | None]:
    states = metrics.get("durable_states")
    states = states if isinstance(states, list) else []
    rollback_guard = metrics.get("rollback_guard")
    rollback_guard = rollback_guard if isinstance(rollback_guard, dict) else {}

    def count(relation: str, accepted_states: set[str]) -> int | None:
        found = [
            item.get("count")
            for item in states
            if isinstance(item, dict)
            and item.get("relation") == relation
            and item.get("state") in accepted_states
        ]
        if not found or not all(isinstance(item, int) and item >= 0 for item in found):
            return None
        return sum(found)

    return {
        "review_pending": count("inference_jobs", {"review_pending"}),
        "sent_unknown": count("inference_attempts", {"sent_unknown"}),
        "pending_terminals": count("provider_terminals", {"pending", "conflict"}),
        "pending_external": count("external_events", {"pending", "processing"}),
        "pending_outbox": count("outbox", {"pending", "processing"}),
        "pending_fees": count("fee_allocations", {"pending", "processing", "failed"}),
        "fee_projection": count("fee_projection_checkpoints", {"running", "failed"}),
        "rollback_unresolved": _nonnegative_int(rollback_guard.get("unresolved")),
        "go_fallback_safe": rollback_guard.get("go_fallback_safe")
        if isinstance(rollback_guard.get("go_fallback_safe"), bool)
        else None,
    }


def _datadog_points(body: Mapping[str, Any]) -> list[tuple[int, float]]:
    series = body.get("series")
    if not isinstance(series, list):
        return []
    values: list[tuple[int, float]] = []
    for item in series:
        if not isinstance(item, dict) or not isinstance(item.get("pointlist"), list):
            continue
        for point in item["pointlist"]:
            if (
                isinstance(point, list)
                and len(point) == 2
                and isinstance(point[0], (int, float))
                and isinstance(point[1], (int, float))
                and not isinstance(point[0], bool)
                and not isinstance(point[1], bool)
                and float(point[0]).is_integer()
            ):
                values.append((int(point[0]), float(point[1])))
    return sorted(values)


def _datadog_organization_id(body: Mapping[str, Any]) -> str:
    data = body.get("data")
    relationships = data.get("relationships") if isinstance(data, dict) else None
    organization = (
        relationships.get("org") if isinstance(relationships, dict) else None
    )
    organization_data = (
        organization.get("data") if isinstance(organization, dict) else None
    )
    organization_id = (
        organization_data.get("id") if isinstance(organization_data, dict) else None
    )
    if not isinstance(organization_id, str) or not organization_id:
        raise ReadOnlyClientError(
            "Datadog current-user response has no authenticated organization identity"
        )
    return organization_id


def _nonnegative_int(value: Any) -> int | None:
    return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else None


def _parse_semantic_version(value: Any) -> tuple[int, int, int, int] | None:
    if not isinstance(value, str) or not value:
        return None
    without_build = value.removeprefix("v").split("+", 1)[0]
    core, separator, _prerelease = without_build.partition("-")
    parts = core.split(".")
    if len(parts) != 3 or not all(part.isdigit() for part in parts):
        return None
    major, minor, patch = (int(part) for part in parts)
    return major, minor, patch, 0 if separator else 1


def _is_loopback(hostname: str) -> bool:
    import ipaddress

    if hostname.lower() == "localhost":
        return True
    try:
        return ipaddress.ip_address(hostname).is_loopback
    except ValueError:
        return False


def _looks_production(hostname: str) -> bool:
    normalized = hostname.lower().rstrip(".")
    return normalized in {"api.darkbloom.dev", "darkbloom-mainnet"} or normalized.endswith(
        ".darkbloom.dev"
    )

