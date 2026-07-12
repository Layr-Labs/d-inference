from __future__ import annotations

import json
import os
import re
import shlex
import signal
import subprocess
import threading
import time
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import TextIO


LOCAL_HOSTS = {"localhost", "127.0.0.1", "::1"}
PILOT_DATABASE_NAME = re.compile(r"pilot_[a-z0-9_]+\Z")
POSTGRES_ENVIRONMENT = {
    "PGDATABASE",
    "PGHOST",
    "PGHOSTADDR",
    "PGOPTIONS",
    "PGPASSFILE",
    "PGPASSWORD",
    "PGPORT",
    "PGSERVICE",
    "PGSERVICEFILE",
    "PGUSER",
}
SENSITIVE_PREFIXES = (
    "EIGENINFERENCE_",
    "DARKBLOOM_",
    "DD_",
    "STRIPE_",
    "PRIVY_",
    "APNS_",
    "CLOUDFLARE_",
    "AWS_",
    "GOOGLE_",
    "GCP_",
    "R2_",
)


@dataclass
class ManagedProcess:
    name: str
    process: subprocess.Popen[str]
    log_handle: TextIO
    log_path: Path

    @property
    def pid(self) -> int:
        return self.process.pid

    def stop(self, timeout: float = 15) -> None:
        if self.process.poll() is not None:
            self.log_handle.close()
            return
        try:
            os.killpg(self.process.pid, signal.SIGINT)
        except ProcessLookupError:
            pass
        try:
            self.process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(self.process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            self.process.wait(timeout=5)
        self.log_handle.close()


class ResourceSampler:
    def __init__(
        self,
        processes: list[ManagedProcess],
        database_urls: dict[str, str],
        database_pool_max: dict[str, int],
        counter_urls: dict[str, str] | None = None,
        counter_bearer: str | None = None,
        interval_seconds: float = 1,
    ) -> None:
        self.processes = processes
        self.database_urls = database_urls
        self.database_pool_max = database_pool_max
        self.counter_urls = counter_urls or {}
        self.counter_bearer = counter_bearer
        self.interval_seconds = interval_seconds
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self.samples: list[dict] = []

    def start(self) -> None:
        self.sample()
        self._thread = threading.Thread(target=self._run, name="pilot-resource-sampler", daemon=True)
        self._thread.start()

    def stop(self) -> dict:
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=max(30, self.interval_seconds * 2 + 1))
            if self._thread.is_alive():
                raise RuntimeError("resource sampler did not stop after bounded probes")
        self.sample()
        return self.summary()

    def sample(self) -> None:
        process_values = {}
        for managed in self.processes:
            process_values[managed.name] = _process_snapshot(managed.pid)
        databases = {}
        for name, url in self.database_urls.items():
            active = _database_active_connections(url)
            maximum = self.database_pool_max.get(name, 0)
            databases[name] = {
                "active": active,
                "pool_max": maximum,
                "utilization": active / maximum if active is not None and maximum > 0 else None,
            }
        counters = {
            name: _counter_snapshot(url, self.counter_bearer)
            for name, url in self.counter_urls.items()
        }
        self.samples.append(
            {
                "elapsed_seconds": (
                    0 if not self.samples else time.monotonic() - self.samples[0]["monotonic"]
                ),
                "monotonic": time.monotonic(),
                "processes": process_values,
                "databases": databases,
                "counters": counters,
            }
        )

    def summary(self) -> dict:
        result: dict[str, dict] = {
            "processes": {},
            "databases": {},
            "mailboxes": {},
            "sessions": {},
            "samples": len(self.samples),
        }
        for managed in self.processes:
            raw_values = [sample["processes"].get(managed.name) for sample in self.samples]
            values = [value for value in raw_values if value]
            if not values:
                result["processes"][managed.name] = {"available": False}
                continue
            first, last = values[0], values[-1]
            result["processes"][managed.name] = {
                "available": True,
                "alive_end": managed.process.poll() is None and raw_values[-1] is not None,
                "rss_start_bytes": first["rss_bytes"],
                "rss_end_bytes": last["rss_bytes"],
                "rss_peak_bytes": max(value["rss_bytes"] for value in values),
                "rss_growth_bytes": last["rss_bytes"] - first["rss_bytes"],
                "tasks_start": first["tasks"],
                "tasks_end": last["tasks"],
                "tasks_peak": max(value["tasks"] for value in values),
                "tasks_growth": last["tasks"] - first["tasks"],
                "fd_start": first["fds"],
                "fd_end": last["fds"],
                "fd_peak": max(value["fds"] for value in values),
                "fd_growth": last["fds"] - first["fds"],
            }
        for name in sorted(set(self.database_urls) | set(self.counter_urls)):
            values = [
                sample["databases"].get(name)
                for sample in self.samples
                if sample["databases"].get(name)
            ]
            utilizations = [value["utilization"] for value in values if value["utilization"] is not None]
            counter_values = [
                sample["counters"].get(name)
                for sample in self.samples
                if sample["counters"].get(name)
            ]
            pool_utilizations = [
                value["database_pool_used"] / value["database_pool_capacity"]
                for value in counter_values
                if value.get("database_pool_capacity", 0) > 0
                and "database_pool_used" in value
            ]
            result["databases"][name] = {
                "pool_max": self.database_pool_max.get(name),
                "active_peak": max(
                    (value["active"] for value in values if value["active"] is not None),
                    default=None,
                ),
                "utilization_peak": max(pool_utilizations or utilizations, default=None),
                "source": "runtime_counter" if pool_utilizations else "postgres_connections",
            }
        for name in self.counter_urls:
            values = [
                sample["counters"].get(name)
                for sample in self.samples
                if sample["counters"].get(name)
            ]
            utilizations = [
                value["mailbox_used"] / value["mailbox_capacity"]
                for value in values
                if value.get("mailbox_capacity", 0) > 0
            ]
            result["mailboxes"][name] = {
                "available": bool(values),
                "used_peak": max((value.get("mailbox_used", 0) for value in values), default=None),
                "capacity": max(
                    (value.get("mailbox_capacity", 0) for value in values),
                    default=None,
                ),
                "utilization_peak": max(utilizations, default=None),
            }
            result["sessions"][name] = {
                "available": bool(values),
                "provider_sessions_end": (
                    values[-1].get("provider_sessions") if values else None
                ),
                "provider_sessions_min": min(
                    (value.get("provider_sessions", 0) for value in values),
                    default=None,
                ),
                "protocol_v1_sessions_end": (
                    values[-1].get("protocol_v1_sessions") if values else None
                ),
                "protocol_v2_sessions_end": (
                    values[-1].get("protocol_v2_sessions") if values else None
                ),
                "untrusted_sessions_end": (
                    values[-1].get("untrusted_sessions") if values else None
                ),
                "self_signed_sessions_end": (
                    values[-1].get("self_signed_sessions") if values else None
                ),
                "hardware_sessions_end": (
                    values[-1].get("hardware_sessions") if values else None
                ),
            }
        return result

    def _run(self) -> None:
        while not self._stop.wait(self.interval_seconds):
            self.sample()


def launch(
    name: str,
    command: str,
    log_directory: Path,
    environment: dict[str, str],
) -> ManagedProcess:
    arguments = shlex.split(command)
    if not arguments:
        raise ValueError(f"{name} launch command is empty")
    log_directory.mkdir(parents=True, exist_ok=True)
    log_path = log_directory / f"{name}.log"
    log_handle = log_path.open("w", encoding="utf-8")
    try:
        process = subprocess.Popen(
            arguments,
            stdout=log_handle,
            stderr=subprocess.STDOUT,
            text=True,
            env=isolated_environment(environment),
            start_new_session=True,
        )
    except Exception:
        log_handle.close()
        raise
    return ManagedProcess(name=name, process=process, log_handle=log_handle, log_path=log_path)


def wait_ready(process: ManagedProcess, url: str, timeout_seconds: float = 60) -> None:
    deadline = time.monotonic() + timeout_seconds
    health_url = url.rstrip("/") + "/health"
    while time.monotonic() < deadline:
        exit_code = process.process.poll()
        if exit_code is not None:
            raise RuntimeError(
                f"{process.name} exited with {exit_code}; inspect {process.log_path}"
            )
        try:
            with urllib.request.urlopen(health_url, timeout=2) as response:
                if response.status == 200:
                    response.read()
                    return
        except Exception:
            pass
        time.sleep(0.2)
    raise RuntimeError(f"{process.name} did not become healthy at {health_url}")


def wait_peer_ready(
    process: ManagedProcess,
    control_url: str,
    expected_sessions: int,
    timeout_seconds: float = 120,
) -> None:
    parsed = urllib.parse.urlparse(control_url)
    health_url = urllib.parse.urlunparse(
        (parsed.scheme, parsed.netloc, "/health", "", "", "")
    )
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        exit_code = process.process.poll()
        if exit_code is not None:
            raise RuntimeError(
                f"{process.name} exited with {exit_code}; inspect {process.log_path}"
            )
        try:
            with urllib.request.urlopen(health_url, timeout=2) as response:
                document = json.load(response)
            if (
                response.status == 200
                and isinstance(document, dict)
                and document.get("status") == "ok"
                and document.get("connected_sessions") == expected_sessions
            ):
                return
        except Exception:
            pass
        time.sleep(0.2)
    raise RuntimeError(
        f"{process.name} did not establish {expected_sessions} sessions; inspect {process.log_path}"
    )


def wait_provider_count(
    process: ManagedProcess,
    coordinator_url: str,
    expected_sessions: int,
    timeout_seconds: float = 300,
) -> None:
    health_url = coordinator_url.rstrip("/") + "/health"
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        exit_code = process.process.poll()
        if exit_code is not None:
            raise RuntimeError(
                f"{process.name} exited with {exit_code}; inspect {process.log_path}"
            )
        try:
            with urllib.request.urlopen(health_url, timeout=2) as response:
                document = json.load(response)
            if (
                response.status == 200
                and isinstance(document, dict)
                and document.get("providers") == expected_sessions
            ):
                return
        except Exception:
            pass
        time.sleep(0.5)
    raise RuntimeError(
        f"{process.name} did not establish {expected_sessions} provider sessions; "
        f"inspect {process.log_path}"
    )


def fetch_peer_counters(control_url: str, bearer: str) -> dict:
    parsed = urllib.parse.urlparse(control_url)
    counter_url = urllib.parse.urlunparse(
        (parsed.scheme, parsed.netloc, "/counters", "", "", "")
    )
    request = urllib.request.Request(
        counter_url,
        headers={"authorization": f"Bearer {bearer}"},
    )
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            document = json.load(response)
    except Exception as error:
        raise RuntimeError(f"peer counters unavailable at {counter_url}: {error}") from error
    if response.status != 200 or not isinstance(document, dict):
        raise RuntimeError(f"peer counters at {counter_url} returned an invalid artifact")
    required = {
        "connected_sessions",
        "expected_sessions",
        "served_requests",
        "emitted_chunks",
        "session_replacements",
        "hedges",
        "sent_unknown_disconnects",
    }
    if set(document) != required or any(
        isinstance(document[name], bool)
        or not isinstance(document[name], int)
        or document[name] < 0
        for name in required
    ):
        raise RuntimeError(f"peer counters at {counter_url} are incomplete")
    return document


def validate_isolated_targets(
    go_url: str,
    rust_url: str,
    go_database_url: str | None,
    rust_database_url: str | None,
    launching: bool,
    *,
    control_urls: tuple[str | None, ...] = (),
    counter_urls: tuple[str | None, ...] = (),
) -> None:
    require_loopback_url(go_url, "Go coordinator", schemes={"http"})
    require_loopback_url(rust_url, "Rust coordinator", schemes={"http"})
    if _url_origin(go_url) == _url_origin(rust_url):
        raise ValueError("Go and Rust coordinators must use distinct origins")
    for index, value in enumerate(control_urls):
        if value:
            require_loopback_url(value, f"peer control {index + 1}", schemes={"http"})
    for index, value in enumerate(counter_urls):
        if value:
            require_loopback_url(value, f"counter {index + 1}", schemes={"http"})
    _require_distinct_pair(control_urls, "peer controls")
    _require_distinct_pair(counter_urls, "counter endpoints")
    if not launching:
        for name, value in (("Go", go_database_url), ("Rust", rust_database_url)):
            if value:
                require_local_database(value, name)
        return
    if not go_database_url or not rust_database_url:
        raise ValueError("launch mode requires separate --go-database-url and --rust-database-url")
    require_local_database(go_database_url, "Go")
    require_local_database(rust_database_url, "Rust")
    if _database_identity(go_database_url) == _database_identity(rust_database_url):
        raise ValueError("Go and Rust launch databases must be distinct")


def isolated_environment(overrides: dict[str, str]) -> dict[str, str]:
    environment = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith(SENSITIVE_PREFIXES)
        and not key.startswith("PG")
        and key not in POSTGRES_ENVIRONMENT
        and key
        not in {
            "DATABASE_URL",
            "DARKBLOOM_TEST_DATABASE_URL",
            "EIGENINFERENCE_DATABASE_URL",
            "EIGENINFERENCE_ADMIN_KEY",
            "EIGENINFERENCE_RELEASE_KEY",
        }
    }
    environment.update({key: value for key, value in overrides.items() if value is not None})
    for key in POSTGRES_ENVIRONMENT:
        environment.pop(key, None)
    # Prevent libpq/pgx from falling back to a user's ~/.pgpass after all
    # PostgreSQL environment overrides have been removed. Pilot DSNs carry
    # their own disposable credentials.
    environment["PGPASSFILE"] = os.devnull
    environment["PGSERVICEFILE"] = os.devnull
    environment["DD_TRACE_ENABLED"] = "false"
    return environment


def require_loopback_url(value: str, label: str, *, schemes: set[str]) -> None:
    parsed = urllib.parse.urlparse(value)
    if parsed.scheme not in schemes:
        expected = "/".join(sorted(schemes))
        raise ValueError(f"{label} URL must use {expected}, got {value!r}")
    if not parsed.netloc or parsed.hostname not in LOCAL_HOSTS:
        raise ValueError(
            f"{label} URL requires an explicit localhost, 127.0.0.1, or ::1 host, got {value!r}"
        )
    if parsed.username is not None or parsed.password is not None:
        raise ValueError(f"{label} URL must not contain userinfo")
    try:
        port = parsed.port
    except ValueError as error:
        raise ValueError(f"{label} URL has an invalid port") from error
    if port is None:
        raise ValueError(f"{label} URL requires an explicit port")
    if port <= 0:
        raise ValueError(f"{label} URL requires a positive port")
    if parsed.fragment:
        raise ValueError(f"{label} URL must not contain a fragment")


def require_local_database(value: str, label: str) -> None:
    parsed = urllib.parse.urlparse(value)
    if parsed.scheme not in {"postgres", "postgresql"}:
        raise ValueError(f"{label} database must be PostgreSQL")
    query_names = {
        name.lower()
        for name, _ in urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)
    }
    if query_names & {"database", "dbname", "host", "hostaddr", "service"}:
        raise ValueError(
            f"{label} database and host must be explicit in the URI path/authority; "
            "database/host/service query overrides are forbidden"
        )
    if not parsed.netloc or parsed.hostname not in LOCAL_HOSTS:
        raise ValueError(
            f"{label} database requires an explicit localhost, 127.0.0.1, or ::1 authority"
        )
    try:
        port = parsed.port
    except ValueError as error:
        raise ValueError(f"{label} database has an invalid port") from error
    if port is None or port <= 0:
        raise ValueError(f"{label} database requires an explicit positive port")
    if parsed.fragment:
        raise ValueError(f"{label} database must not contain a fragment")
    if parsed.params:
        raise ValueError(f"{label} database must not contain path parameters")
    path_segments = [segment for segment in parsed.path.split("/") if segment]
    if len(path_segments) != 1 or path_segments[0] == "postgres":
        raise ValueError(f"{label} database must be a disposable named database, not postgres")
    database_name = urllib.parse.unquote(path_segments[0])
    if PILOT_DATABASE_NAME.fullmatch(database_name) is None:
        raise ValueError(
            f"{label} database name must match 'pilot_[a-z0-9_]+', got {database_name!r}"
        )


def _database_identity(value: str) -> tuple[str, int | None, str]:
    parsed = urllib.parse.urlparse(value)
    return (
        _normalized_loopback_host(parsed.hostname),
        parsed.port,
        urllib.parse.unquote(parsed.path.rstrip("/")),
    )


def _url_origin(value: str) -> tuple[str, str, int | None]:
    parsed = urllib.parse.urlparse(value)
    return parsed.scheme, _normalized_loopback_host(parsed.hostname), parsed.port


def _normalized_loopback_host(host: str | None) -> str:
    return "loopback" if host in LOCAL_HOSTS else (host or "")


def _require_distinct_pair(values: tuple[str | None, ...], label: str) -> None:
    configured = [value for value in values if value]
    if len(configured) == 2 and _url_origin(configured[0]) == _url_origin(configured[1]):
        raise ValueError(f"Go and Rust {label} must use distinct origins")


def _process_snapshot(pid: int) -> dict | None:
    status_path = Path(f"/proc/{pid}/status")
    fd_path = Path(f"/proc/{pid}/fd")
    if not status_path.exists():
        return _portable_process_snapshot(pid)
    try:
        fields = {}
        for line in status_path.read_text(encoding="utf-8").splitlines():
            name, _, value = line.partition(":")
            fields[name] = value.strip()
        rss_kib = int(fields.get("VmRSS", "0 kB").split()[0])
        tasks = int(fields.get("Threads", "0"))
        fds = len(list(fd_path.iterdir()))
        return {"rss_bytes": rss_kib * 1024, "tasks": tasks, "fds": fds}
    except (FileNotFoundError, PermissionError, ValueError):
        return None


def _portable_process_snapshot(pid: int) -> dict | None:
    try:
        process = subprocess.run(
            ["ps", "-o", "rss=,thcount=", "-p", str(pid)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=isolated_environment({}),
            timeout=3,
            check=True,
        )
        fields = process.stdout.split()
        if len(fields) != 2:
            return None
        descriptors = subprocess.run(
            ["lsof", "-n", "-P", "-p", str(pid), "-Fn"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=isolated_environment({}),
            timeout=3,
            check=True,
        )
        fds = sum(
            line.startswith("f") and line[1:].isdigit()
            for line in descriptors.stdout.splitlines()
        )
        return {
            "rss_bytes": int(fields[0]) * 1024,
            "tasks": int(fields[1]),
            "fds": fds,
        }
    except (FileNotFoundError, subprocess.SubprocessError, ValueError):
        return None


def _database_active_connections(url: str) -> int | None:
    try:
        completed = subprocess.run(
            [
                "psql",
                url,
                "--no-psqlrc",
                "--tuples-only",
                "--no-align",
                "--command",
                "SELECT count(*) FROM pg_stat_activity WHERE datname=current_database()",
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=isolated_environment({}),
            timeout=3,
            check=True,
        )
        return int(completed.stdout.strip())
    except (FileNotFoundError, subprocess.SubprocessError, ValueError):
        return None


def _counter_snapshot(url: str, bearer: str | None) -> dict | None:
    request = urllib.request.Request(url)
    if bearer:
        request.add_header("authorization", f"Bearer {bearer}")
    try:
        with urllib.request.urlopen(request, timeout=3) as response:
            document = json.load(response)
    except Exception:
        return None
    if not isinstance(document, dict):
        return None
    counters = document.get("pilot_counters", document)
    if not isinstance(counters, dict):
        return None
    result = {}
    for name in (
        "mailbox_used",
        "mailbox_capacity",
        "active_tasks",
        "file_descriptors",
        "database_pool_used",
        "database_pool_capacity",
        "provider_sessions",
        "protocol_v1_sessions",
        "protocol_v2_sessions",
        "untrusted_sessions",
        "self_signed_sessions",
        "hardware_sessions",
    ):
        value = counters.get(name)
        if (
            isinstance(value, (int, float))
            and not isinstance(value, bool)
            and value >= 0
        ):
            result[name] = float(value)
    required = {
        "mailbox_used",
        "mailbox_capacity",
        "database_pool_used",
        "database_pool_capacity",
        "provider_sessions",
        "protocol_v1_sessions",
        "protocol_v2_sessions",
        "untrusted_sessions",
        "self_signed_sessions",
        "hardware_sessions",
    }
    if not required.issubset(result):
        return None
    if result["mailbox_capacity"] <= 0 or result["database_pool_capacity"] <= 0:
        return None
    return result
